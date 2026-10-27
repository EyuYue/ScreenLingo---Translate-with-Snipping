'use strict';
(() => {
  const root = document.getElementById('translations');
  const maxBlocks = 128;
  const maskBleed = 2; // Screen points, independent of Retina screenshot pixels.
  let lastPayload = null;
  const finite = n => typeof n === 'number' && Number.isFinite(n);
  const report = state => {
    window.ScreenLingoOverlayReport = state;
    window.webkit?.messageHandlers?.overlayReport?.postMessage(state);
  };
  function clipBox(b) {
    if (!b || ![b.x,b.y,b.width,b.height].every(finite) || b.width <= 0 || b.height <= 0) return null;
    const x = Math.max(0,b.x), y = Math.max(0,b.y);
    const right = Math.min(1000,b.x+b.width), bottom = Math.min(1000,b.y+b.height);
    return right > x && bottom > y ? {x,y,width:right-x,height:bottom-y} : null;
  }
  function overlaps(a,b) {
    return a.x < b.x+b.width && b.x < a.x+a.width && a.y < b.y+b.height && b.y < a.y+a.height;
  }
  function overlapArea(a,b) {
    const left = Math.max(a.x,b.x), top = Math.max(a.y,b.y);
    const right = Math.min(a.x+a.width,b.x+b.width), bottom = Math.min(a.y+a.height,b.y+b.height);
    return Math.max(0,right-left) * Math.max(0,bottom-top);
  }
  function area(box) { return box.width * box.height; }
  function shouldMerge(a,b) {
    if (!overlaps(a.box,b.box) || a.direction !== b.direction) return false;
    const overlap = overlapArea(a.box,b.box);
    const smaller = Math.max(1,Math.min(area(a.box),area(b.box)));
    // Merge only near-duplicate placements, never merely adjacent speech bubbles.
    return overlap / smaller >= 0.72;
  }
  function dedupeNearDuplicates(blocks) {
    const merged = [];
    for (const block of blocks) {
      const last = merged[merged.length-1];
      if (last && shouldMerge(last,block)) {
        if (last.translation !== block.translation) last.translation += '\n\n' + block.translation;
      } else {
        merged.push({...block});
      }
    }
    return merged;
  }
  function isMostlyCJK(text) {
    if (typeof text !== 'string' || !text.trim()) return false;
    const chars = [...text].filter(ch => !/\s/.test(ch));
    if (!chars.length) return false;
    let cjk = 0;
    for (const ch of chars) {
      if (/[぀-ヿ㐀-䶿一-鿿豈-﫿＀-￯]/.test(ch)) cjk++;
    }
    return cjk / chars.length >= 0.45;
  }
  function chooseDirection(block,payloadDirection) {
    if (payloadDirection && payloadDirection !== 'auto') return payloadDirection;
    if (block.direction === 'vertical-rtl' || block.direction === 'vertical-ltr') return block.direction;
    const tall = block.box.height >= block.box.width * 1.45;
    const compact = (block.translation || '').length <= 80 && (block.sourceText || '').length <= 80;
    const cjk = isMostlyCJK((block.sourceText || '') + (block.translation || ''));
    return tall && compact && cjk ? 'vertical-rtl' : 'horizontal';
  }
  function cssColor(value,fallback='') {
    if (typeof value !== 'string') return fallback;
    const text = value.trim();
    if (!text || text.length > 32) return fallback;
    if (/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(text)) return text;
    if (/^rgba?\(\s*(?:\d{1,3}\s*,\s*){2}\d{1,3}(?:\s*,\s*(?:0|1|0?\.\d+))?\s*\)$/i.test(text)) return text;
    if (/^hsla?\(.*\)$/i.test(text)) return text;
    if (/^(transparent|black|white|gray|grey|red|green|blue|yellow|orange|purple|brown)$/i.test(text)) return text;
    return fallback;
  }
  function angleDegrees(value) {
    if (typeof value !== 'number' || !Number.isFinite(value) || Math.abs(value) > 180) return 0;
    return value;
  }
  function setRect(node,box,bleed=0) {
    // Round masks outward so fractional coordinates cannot leave a source-text edge visible.
    const x = box.x*window.innerWidth/1000, y = box.y*window.innerHeight/1000;
    const right = (box.x+box.width)*window.innerWidth/1000;
    const bottom = (box.y+box.height)*window.innerHeight/1000;
    const left = Math.max(0,Math.floor(x-bleed)), top = Math.max(0,Math.floor(y-bleed));
    node.style.left = left+'px'; node.style.top = top+'px';
    node.style.width = (Math.min(window.innerWidth,Math.ceil(right+bleed))-left)+'px';
    node.style.height = (Math.min(window.innerHeight,Math.ceil(bottom+bleed))-top)+'px';
  }
  function fits(el) { return el.scrollHeight <= el.clientHeight + 1 && el.scrollWidth <= el.clientWidth + 1; }
  function fitText(el,maxSize) {
    let low = 10, high = Math.max(low,Math.min(48,maxSize));
    el.style.fontSize = low+'px';
    if (!fits(el)) return true;
    for (let i=0; i<10; i++) {
      const middle = (low+high)/2;
      el.style.fontSize = middle+'px';
      if (fits(el)) low = middle; else high = middle;
    }
    el.style.fontSize = Math.floor(low*10)/10+'px';
    return !fits(el);
  }
  window.renderOverlay = payload => {
    lastPayload = payload;
    root.replaceChildren();
    const result = payload?.result || {};
    const input = Array.isArray(result.blocks) ? result.blocks : [];
    const valid = input.slice(0,maxBlocks).flatMap(block => {
      const box = clipBox(block?.box);
      return box && typeof block.translation === 'string' && block.translation.trim() ? [{...block,box}] : [];
    });
    // A missing/malformed bbox is not permission to cover the screenshot.
    // Full-region masking is used ONLY after the user explicitly clicks 整块.
    const fallback = payload?.wholeSelection === true;
    const fullText = typeof result.translation === 'string' ? result.translation : '';
    const sourceBlocks = fallback
      ? (fullText.trim() ? [{box:{x:0,y:0,width:1000,height:1000},translation:fullText,direction:'horizontal'}] : [])
      : valid;
    const blocks = fallback ? sourceBlocks : dedupeNearDuplicates(sourceBlocks);
    // Paint every original-text mask below every translation. A later source mask
    // must never cover an earlier translation, and gaps remain fully transparent.
    for (const block of sourceBlocks) {
      const mask = document.createElement('div');
      mask.className = 'translation-mask'; mask.setAttribute('aria-hidden','true');
      setRect(mask,block.box,maskBleed);
      const angle = angleDegrees(block.angleDegrees);
      if (angle) {
        mask.style.transform = `rotate(${angle}deg)`;
        mask.style.transformOrigin = 'center center';
      }
      mask.style.background = cssColor(block.backgroundColor,'var(--text-background)');
      root.append(mask);
    }
    let overflow = false;
    for (const block of blocks) {
      const node = document.createElement('section'); node.className = 'translation-block';
      setRect(node,block.box);
      const shortest = Math.min(block.box.width*window.innerWidth/1000,block.box.height*window.innerHeight/1000);
      node.style.padding = Math.max(1,Math.min(6,shortest*0.07))+'px';
      const angle = angleDegrees(block.angleDegrees);
      if (angle) {
        node.style.transform = `rotate(${angle}deg)`;
        node.style.transformOrigin = 'center center';
        node.style.overflow = 'visible';
      }
      const text = document.createElement('div'); text.className = 'translation-text';
      const direction = chooseDirection(block,payload?.direction);
      if (direction === 'vertical-rtl' || direction === 'vertical-ltr') text.classList.add(direction);
      else text.dir = 'auto';
      const ink = document.createElement('span'); ink.className = 'translation-ink';
      ink.style.color = cssColor(block.textColor,'var(--text-color)');
      ink.style.background = cssColor(block.backgroundColor,'var(--text-background)');
      // Never interpret translated text as HTML, CSS, URLs or JavaScript.
      ink.textContent = block.translation;
      text.append(ink); node.append(text); root.append(node);
      if (fitText(text,finite(payload?.fontSize) ? payload.fontSize : 21)) {
        overflow = true;
        const marker = document.createElement('span'); marker.className = 'overflow-marker';
        marker.textContent = '…'; node.append(marker);
      }
    }
    report({overflow,blocks:blocks.length,fallback,
      merged:sourceBlocks.length-blocks.length,
      missingPositions:!fallback && !valid.length && Boolean(fullText.trim()),
      incomplete:!fallback && (result.positioningIncomplete === true || valid.length !== input.length)});
  };
  window.addEventListener('resize',() => { if (lastPayload) window.renderOverlay(lastPayload); });
})();
