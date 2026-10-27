'use strict';
// Local-only UI. Native code owns screenshots, networking, permissions and Keychain.
const $ = id => document.getElementById(id);
const pending = new Map();
let sequence = 0;
let state = null;
let draft = null;
let draftProvider = 'openai';
let busy = false;
let hasImage = false;
let deleteArmed = false;
let previousFocus = null;
let keyBaseline = '';
let settingsSaving = false;
let uninstalling = false;
let permissionRefreshPending = false;
const CUSTOM_MODEL = '__screenlingo_custom__';

const MODEL_CHOICES = {
  openai: ['gpt-4.1-mini', 'gpt-4.1', 'gpt-5.4-mini', 'gpt-5.4'],
  gemini: ['gemini-3.8-flash', 'gemini-3.5-flash-lite', 'gemini-3.1-pro-preview'],
  compatible: []
};

function call(action, payload = {}) {
  if (!window.webkit?.messageHandlers?.screenlingo) {
    return Promise.reject(new Error('请用 ScreenLingo.app 打开；浏览器用不了QAQ。'));
  }
  return new Promise((resolve, reject) => {
    const id = String(++sequence);
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('等待超时，检查权限或钥匙串。')); }, 180000);
    pending.set(id, { resolve, reject, timer });
    window.webkit.messageHandlers.screenlingo.postMessage({ id, action, payload });
  });
}

window.ScreenLingoNative = event => {
  if (event.type === 'refreshState') { call('getState').then(value => applyState(value)).catch(reportError); return; }
  if (event.type === 'reply') {
    const item = pending.get(event.id);
    if (!item) return;
    clearTimeout(item.timer); pending.delete(event.id);
    event.error ? item.reject(new Error(event.error)) : item.resolve(event.value);
    return;
  }
  switch (event.type) {
    case 'status': setStatus(event.text, event.kind); break;
    case 'busy': setBusy(event.value, event.capturing); break;
    case 'settings': showSettings().catch(reportError); break;
    case 'image': showImage(event.url, event.size); break;
    case 'result': showResult(event.value); break;
    case 'clear': clearView(Boolean(event.quiet)); break;
    case 'screenPermission': updatePermission(event.value); break;
    case 'uninstalling': setUninstalling(event.value); break;
  }
};

function setStatus(text, kind = 'info') {
  $('status').textContent = text;
  $('status').className = kind;
  $('status-dot').className = 'dot ' + (busy ? 'busy' : kind);
  if (!$('settings-overlay').hidden) {
    $('settings-error').textContent = text;
    $('settings-error').hidden = false;
    $('settings-error').classList.toggle('danger-text', kind === 'error');
  }
}
const reportError = error => setStatus(error.message || String(error), 'error');
function setBusy(value, capturing = false) {
  busy = Boolean(value);
  for (const id of ['capture', 'capture-fullscreen', 'open-image', 'clear', 'translate-text', 'source-language', 'target-language', 'reading-order', 'settings-save', 'delete-key', 'provider', 'base-url', 'model', 'custom-model', 'api-key', 'hotkey', 'fullscreen-hotkey', 'auto-translate', 'consent', 'glossary']) {
    $(id).disabled = busy || settingsSaving || uninstalling;
  }
  $('recognize').disabled = busy || settingsSaving || uninstalling || !hasImage;
  $('settings-close').disabled = settingsSaving || uninstalling;
  $('uninstall').disabled = busy || settingsSaving || uninstalling;
  $('uninstall').textContent = uninstalling ? '确认卸载' : '卸载 ScreenLingo…';
  for (const id of ['settings-open', 'back-to-bubble', 'get-key', 'pin']) $(id).disabled = uninstalling;
  $('permission').disabled = settingsSaving || busy || uninstalling;
  updateCustomModelField();
  $('source-text').readOnly = busy || uninstalling;
  $('cancel').hidden = !busy || Boolean(capturing);
  $('status-dot').className = 'dot ' + (busy ? 'busy' : '');
}
function setUninstalling(value) {
  uninstalling = Boolean(value);
  setBusy(busy);
}
async function requestUninstall() {
  if (busy || settingsSaving || uninstalling) return;
  setUninstalling(true);
  try {
    // Native code presents the confirmation and optional data-removal checkbox.
    // This reply only acknowledges the request; cancel/failure unlocks via an event.
    await call('uninstall');
  } catch (error) {
    setUninstalling(false);
    reportError(error);
  }
}
function selectValue(select, value) {
  if (![...select.options].some(option => option.value === value)) {
    const option = document.createElement('option'); option.value = value; option.textContent = value;
    select.append(option);
  }
  select.value = value;
}
function applyState(next, restoreContent = false) {
  state = next;
  const settings = next.settings;
  const profile = settings.profiles[settings.provider];
  selectValue($('source-language'), settings.sourceLanguage);
  selectValue($('target-language'), settings.targetLanguage);
  $('reading-order').value = settings.readingOrder;
  $('target-tag').textContent = settings.targetLanguage;
  $('shortcut').textContent = next.shortcutLabel || '⌥⇧T';
  $('fullscreen-shortcut').textContent = next.fullScreenShortcutLabel || '';
  $('fullscreen-shortcut').hidden = !next.fullScreenShortcutLabel;
  const names = { openai: 'OpenAI', gemini: 'Gemini', compatible: '兼容接口' };
  $('provider-label').textContent = `${names[settings.provider]} · ${profile.model || '未设置模型'}`;
  let host = '';
  try { host = new URL(profile.baseURL).host; } catch (_) { /* Incomplete custom profile. */ }
  $('privacy-label').textContent = host ? `发送至 ${host} · 无本机历史记录` : '主动截图后发送 · 无本机历史记录';
  $('pin').setAttribute('aria-pressed', String(Boolean(next.pinned)));
  $('pin').textContent = next.pinned ? '已置顶' : '置顶';
  updatePermission(next.screenPermission);
  if (restoreContent) {
    if (next.image) showImage(next.image, next.imageSize);
    if (next.result) showResult(next.result);
  }
  uninstalling = Boolean(next.uninstalling);
  setBusy(Boolean(next.busy));
  if (next.shortcutActive === false) setStatus('框选快捷键被其他软件占用；可在设置里更换。', 'warning');
  else if (fullScreenShortcutFailed(next)) setStatus('整屏快捷键未能注册；请更换快捷键，或点击整屏翻译按钮。', 'warning');
}
function updatePermission(granted) {
  const enabled = granted === true;
  if (state) state.screenPermission = enabled;
  $('permission').textContent = enabled ? '已打开' : '打开权限设置';
  $('permission').dataset.granted = String(enabled);
  $('permission').title = enabled ? '屏幕录制已允许；点击管理权限' : '允许 ScreenLingo 录制所选屏幕区域';
  $('permission').setAttribute('aria-label', enabled ? '屏幕录制权限已打开，点击管理' : '屏幕录制权限未打开，点击设置');
  if (state) {
    const configured = Boolean(state.keys[state.settings.provider] && state.settings.consent);
    $('setup-hint').textContent = configured
      ? (enabled ? '接口已配置 · 屏幕录制已打开。' : '接口已配置；请允许屏幕录制。')
      : (enabled ? '屏幕录制已打开；请在右上角设置 AI 接口。' : '首次使用：设置 AI 接口，然后允许屏幕录制。');
  }
}
async function refreshPermission() {
  if (permissionRefreshPending || uninstalling || $('settings-overlay').hidden) return;
  permissionRefreshPending = true;
  try { updatePermission(await call('getScreenPermission')); }
  catch (error) { reportError(error); }
  finally { permissionRefreshPending = false; }
}
function selectedModel() {
  return $('model').value === CUSTOM_MODEL ? $('custom-model').value.trim() : $('model').value;
}
function updateCustomModelField() {
  const custom = $('model').value === CUSTOM_MODEL;
  $('custom-model-field').hidden = !custom;
  $('custom-model').disabled = !custom || busy || settingsSaving || uninstalling;
}
function loadModelChoices(provider, current) {
  const select = $('model');
  select.replaceChildren();
  const choices = MODEL_CHOICES[provider] || [];
  for (const name of choices) select.add(new Option(name, name));
  if (current && !choices.includes(current)) select.add(new Option(current + ' · 已保存', current));
  select.add(new Option('自定义…', CUSTOM_MODEL));
  select.value = current || CUSTOM_MODEL;
  $('custom-model').value = current || '';
  $('model-help').textContent = provider === 'compatible'
    ? '第三方接口使用其提供的模型 ID；已保存的名称会保留在下拉列表中。'
    : '预设不代表账户已开通；未列出的模型请选择自定义。';
  updateCustomModelField();
}
function showImage(url, size) {
  if (typeof url !== 'string' || !url.startsWith('data:image/png;base64,')) return;
  hasImage = true;
  $('thumbnail').src = url; $('full-preview').src = url;
  $('image-size').textContent = size || '';
  $('image-strip').hidden = false; $('welcome').hidden = true;
  $('source-text').value = ''; $('translated-text').value = '';
  $('detected-language').textContent = ''; $('notes').hidden = true;
  $('recognize').disabled = busy;
  $('result-meta').textContent = '等待本次识别结果';
}
function showResult(value) {
  $('source-text').value = value.sourceText || '';
  $('translated-text').value = value.translation || '';
  $('detected-language').textContent = value.detectedLanguage || '';
  $('notes').textContent = value.notes || '';
  $('notes').hidden = !value.notes;
  $('result-meta').textContent = value.structured ? '请核对小字与不清晰字符' : '模型原始回复 · 需核对';
  $('source-text').scrollTop = 0; $('translated-text').scrollTop = 0;
}
function clearView(quiet = false) {
  hasImage = false;
  $('source-text').value = ''; $('translated-text').value = '';
  $('thumbnail').removeAttribute('src'); $('full-preview').removeAttribute('src');
  $('image-strip').hidden = true; $('welcome').hidden = false;
  $('notes').hidden = true; $('detected-language').textContent = '';
  $('recognize').disabled = true;
  $('result-meta').textContent = '保留段落、公式与数值';
  if (!quiet) setStatus('已清空本次截图与文字；不会清除你已复制的剪贴板内容。');
}

async function showSettings() {
  if (settingsSaving || uninstalling) return;
  const next = await call('getState'); applyState(next);
  draft = JSON.parse(JSON.stringify(next.settings));
  previousFocus = document.activeElement;
  $('settings-overlay').hidden = false; document.querySelector('.app').inert = true;
  $('provider').value = draft.provider;
  $('hotkey').value = draft.hotkey;
  $('fullscreen-hotkey').value = draft.fullScreenHotkey || 'option-t';
  updateFullScreenHotkeyHelp();
  $('auto-translate').checked = draft.autoTranslate;
  $('consent').checked = draft.consent;
  $('glossary').value = draft.glossary;
  $('settings-error').hidden = true;
  loadDraftProvider(draft.provider);
  $('provider').focus();
}
function hideSettings() {
  if (settingsSaving || uninstalling) return;
  $('settings-overlay').hidden = true; document.querySelector('.app').inert = false;
  $('api-key').value = ''; draft = null;
  previousFocus?.focus();
}
function snapshotProvider() {
  if (!draft) return;
  draft.profiles[draftProvider] = { baseURL: $('base-url').value.trim(), model: selectedModel() };
}
function loadDraftProvider(provider) {
  draftProvider = provider;
  const profile = draft.profiles[provider];
  $('base-url').value = profile.baseURL;
  loadModelChoices(provider, profile.model);
  $('base-url').readOnly = provider !== 'compatible';
  $('api-key').value = ''; deleteArmed = false;
  keyBaseline = state.settings.profiles[provider]?.baseURL || '';
  $('get-key').hidden = provider === 'compatible';
  $('endpoint-help').textContent = provider === 'compatible'
    ? '填写 Base URL（通常以 /v1 结尾），不是网页聊天地址。仅本机 localhost 允许 HTTP。'
    : provider === 'gemini' ? 'Gemini Interactions 接口。请选择账户可访问的图片模型。' : 'OpenAI Responses 接口。请选择账户可访问的图片模型。';
  updateKeyHint(); updateDestination();
}
function updateKeyHint() {
  const unchanged = $('base-url').value.trim().replace(/\/+$/, '') === keyBaseline.replace(/\/+$/, '');
  const saved = Boolean(state?.keys[draftProvider]) && unchanged;
  $('api-key').placeholder = saved ? '已保存在钥匙串 · 留空表示不修改' : '在本机填写，不要发到聊天中';
  $('key-hint').textContent = saved ? '已存 Key 不会回传。' : '仅保存在 macOS 钥匙串。';
  $('delete-key').hidden = !saved;
  $('delete-key').textContent = '删除已存 Key'; deleteArmed = false;
}
function updateDestination() {
  const raw = $('base-url').value.trim();
  $('destination').textContent = raw || '请先填写服务地址';
}
async function saveSettings({ close = true, deleteKey = false } = {}) {
  if (!draft || settingsSaving || busy || uninstalling) return;
  snapshotProvider();
  if (!draft.profiles[draftProvider].model && !deleteKey) throw new Error('请选择模型；使用自定义模型时请输入名称。');
  draft.provider = $('provider').value;
  draft.hotkey = $('hotkey').value;
  draft.fullScreenHotkey = $('fullscreen-hotkey').value;
  draft.autoTranslate = $('auto-translate').checked;
  draft.consent = $('consent').checked;
  draft.glossary = $('glossary').value;
  $('settings-error').hidden = true;
  // Snapshot once and lock immediately, before waiting for the native reply.
  const payload = { settings: JSON.parse(JSON.stringify(draft)), apiKey: $('api-key').value, deleteKey };
  settingsSaving = true;
  setBusy(busy);
  let next;
  try {
    next = await call('saveSettings', payload);
    $('api-key').value = '';
    applyState(next);
    draft = JSON.parse(JSON.stringify(next.settings));
    loadDraftProvider(draft.provider);
  } finally {
    settingsSaving = false;
    setBusy(busy);
  }
  if (close) hideSettings();
  const conflict = next.shortcutActive === false || fullScreenShortcutFailed(next);
  setStatus(deleteKey ? '已从钥匙串删除当前地址对应的 Key。' : conflict ? '设置已保存，但有快捷键未能注册；请更换。' : next.settings.fullScreenHotkey === 't' ? '已保存。返回悬浮球后 T 单键生效；右键球可暂停，恢复正常打字。' : '设置已保存。API Key 仅保存在本机钥匙串。', conflict ? 'warning' : 'success');
}

function fullScreenShortcutFailed(next) {
  return next.settings.fullScreenHotkey !== 'disabled' && !next.fullScreenShortcutPaused && next.fullScreenShortcutActive === false;
}
function updateFullScreenHotkeyHelp() {
  const single = $('fullscreen-hotkey').value === 't';
  $('fullscreen-hotkey-help').textContent = single
    ? '返回悬浮球后生效，会占用其他软件的普通 T 输入。球上 T 标记表示已开启；右键可暂停。详情窗口打开时自动暂停。'
    : $('fullscreen-hotkey').value === 'disabled' ? '仍可点击整屏翻译按钮或使用悬浮球右键菜单。' : '截取鼠标所在的整块屏幕，不需要拖选。';
}

const command = (id, action, payload = () => ({})) => $(id).addEventListener('click', () => call(action, payload()).catch(reportError));
command('capture', 'capture'); command('capture-fullscreen', 'captureFullScreen'); command('open-image', 'openImage'); command('clear', 'clear');
command('recognize', 'translateImage'); command('cancel', 'cancel');
$('permission').addEventListener('click', () => call('permission').then(updatePermission).catch(reportError));
command('translate-text', 'translateText', () => ({ text: $('source-text').value }));
for (const [id, field] of [['copy-source', 'source-text'], ['copy-translation', 'translated-text']]) {
  $(id).addEventListener('click', async () => {
    const text = $(field).value;
    if (!text) { setStatus('还没有可复制的文字。', 'warning'); return; }
    try { await call('copy', { text }); setStatus('已复制。', 'success'); } catch (error) { reportError(error); }
  });
}
$('pin').addEventListener('click', async () => {
  try { const pinned = await call('pin'); $('pin').setAttribute('aria-pressed', String(pinned)); $('pin').textContent = pinned ? '已置顶' : '置顶'; } catch (error) { reportError(error); }
});
$('settings-open').addEventListener('click', () => showSettings().catch(reportError));
$('settings-close').addEventListener('click', hideSettings);
$('uninstall').addEventListener('click', requestUninstall);
$('settings-save').addEventListener('click', () => saveSettings().catch(reportError));
$('provider').addEventListener('change', () => {
  if ($('api-key').value.trim()) {
    $('provider').value = draftProvider;
    setStatus('请先保存或清空刚输入的 API Key，再切换服务商。', 'warning');
    return;
  }
  snapshotProvider(); loadDraftProvider($('provider').value);
});
$('fullscreen-hotkey').addEventListener('change', updateFullScreenHotkeyHelp);
$('model').addEventListener('change', () => {
  updateCustomModelField();
  if ($('model').value === CUSTOM_MODEL) $('custom-model').focus();
});
$('base-url').addEventListener('input', () => { updateKeyHint(); updateDestination(); });
$('get-key').addEventListener('click', () => call('external', { name: draftProvider === 'gemini' ? 'geminiKeys' : 'openaiKeys' }).catch(reportError));
$('delete-key').addEventListener('click', () => {
  if (!deleteArmed) { deleteArmed = true; $('delete-key').textContent = '再次点击确认删除'; return; }
  saveSettings({ close: false, deleteKey: true }).catch(reportError);
});
for (const id of ['source-language', 'target-language', 'reading-order']) {
  $(id).addEventListener('change', async () => {
    try {
      const next = await call('quickOptions', { sourceLanguage: $('source-language').value, targetLanguage: $('target-language').value, readingOrder: $('reading-order').value });
      applyState(next);
      if ($('translated-text').value) setStatus('选项已更改；现有译文未更新，请重新识别或翻译。');
    } catch (error) { reportError(error); }
  });
}
$('image-preview').addEventListener('click', () => {
  $('preview-overlay').hidden = false; document.querySelector('.app').inert = true; $('preview-close').focus();
});
function hidePreview() { $('preview-overlay').hidden = true; document.querySelector('.app').inert = false; $('image-preview').focus(); }
$('preview-close').addEventListener('click', hidePreview);
document.addEventListener('keydown', event => {
  const overlay = !$('preview-overlay').hidden ? $('preview-overlay') : !$('settings-overlay').hidden ? $('settings-overlay') : null;
  if (event.key === 'Escape' && overlay) {
    event.preventDefault(); overlay.id === 'preview-overlay' ? hidePreview() : hideSettings();
  }
  if (event.key === 'Tab' && overlay) {
    const items = [...overlay.querySelectorAll('button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled)')].filter(el => el.offsetParent !== null);
    if (!items.length) return;
    if (event.shiftKey && document.activeElement === items[0]) { event.preventDefault(); items.at(-1).focus(); }
    else if (!event.shiftKey && document.activeElement === items.at(-1)) { event.preventDefault(); items[0].focus(); }
  }
});
$('source-text').placeholder = $('source-text').placeholder.replaceAll('\\n', '\n');
window.addEventListener('focus', refreshPermission);
document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshPermission(); });
call('getState').then(value => applyState(value, true)).catch(reportError);

$('back-to-bubble').addEventListener('click', () => call('returnToBubble').catch(reportError));
