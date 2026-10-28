# ScreenLingo

一个非常小的软件，用AI API翻译，我做来用来看漫画的小工具


**点击悬浮球或快捷键翻译屏幕上的文字框选翻译，译文原位显示。**

**Select, translate on-screen text with a floating button or keyboard shortcut，and read in place.** 

[简体中文](#简体中文) · [English](#english)

---

## 中文

### 功能

- **区域翻译**：点击悬浮球或按快捷键，框选需要翻译的区域。
- **整屏翻译**：一键翻译鼠标所在显示器的整个画面。
- **原位显示**：译文覆盖原文所在的文字区域，其余区域保持透明。
- **阅读调整**：设置原文阅读方向、译文横排或竖排，并调整字号。
- **服务配置**：选择服务商和模型，使用自己的 API Key；支持自定义模型和第三方接口。

### 安装

**系统要求：macOS 13 或更新版本。**

1. 解压安装包，双击 `screenlingo.command`。
2. 如提示安装 Apple Command Line Tools，完成安装后再次运行脚本。
3. 脚本会在本机编译并打开 `~/Applications/ScreenLingo.app`。

安装完成后，直接打开 `ScreenLingo.app` 即可。

> 首次安装无需旧版本。更新前，请先退出正在运行的 ScreenLingo。

### 首次设置

1. 点击窗口右上角的**设置**。
2. 选择服务商和下拉列表中的模型，填写 **API Key** 并保存。
3. 如需使用未列出的模型，选择**自定义**；使用第三方接口时，还需填写 **API 地址**。
4. 根据系统提示允许**屏幕录制**。应用会根据系统状态更新权限显示；如系统要求重新打开应用，请退出后再次启动。

### 使用

#### 快捷键与悬浮球

| 操作 | 方式 |
| --- | --- |
| 开始框选翻译 | 点击「译」悬浮球，或按 `⌥⇧T`（Option + Shift + T） |
| 翻译所选区域 | 松开鼠标 |
| 取消框选 | 按 `Esc` 或点击鼠标右键 |
| 整屏翻译 | 按 `⌥T`（Option + T） |
| 移动悬浮球 | 拖动悬浮球 |
| 调整阅读方向、译文排版或进入设置 | 右键点击悬浮球 |
| 取消等待中的翻译 | 等待翻译时点击悬浮球 |

#### 整屏翻译

按 `⌥T`，或在详情页、悬浮球右键菜单中选择**整屏翻译**，即可截取并翻译**鼠标所在显示器的整个画面**。

截图前，ScreenLingo 会隐藏自身窗口、悬浮球和旧译文。每次启动后首次使用整屏翻译时，会确认截图范围和服务地址。

#### 可选：使用 T 单键

在**设置 → 整屏翻译快捷键 → T** 中启用。返回悬浮球后生效，球上会出现 **T** 标记。

> **T 单键模式会占用其他软件中的普通 T 输入。** 右键点击悬浮球并选择**暂停**，即可恢复打字；打开详情窗口时也会自动暂停。默认的 `⌥T` 不占用普通 T 输入。

#### 译文显示与操作

译文层的空白区域完全透明。应用只在原文所在的文字区域铺设不透明的浅色底，并在其上显示译文；即使译文较短，也会遮住完整的原文区域。

- 遮罩边缘向外延伸 **2 个屏幕点**，避免原文字边缘露出。
- 重叠文字框只在局部合并，不会自动铺满选区。只有手动点击**整块**，才会覆盖整个选区。
- 通过译文旁的控件，可以切换查看原文、调整字号、复制或关闭译文。
- 无法定位的文字仍会保留在详情和复制结果中，并在工具条提示；这些文字不会触发整张不透明背景。
- 如文字显示不全，点击**详情**查看。

#### 手动发送截图

关闭**自动发送**后，截图不会立即上传。需要再次点击「发」悬浮球，才会将截图发送至所选服务。

### 数据与限制

#### 截图与数据处理

| 项目 | 说明 |
| --- | --- |
| 区域翻译 | 发送框选区域的截图 |
| 整屏翻译 | 发送鼠标所在显示器的完整截图 |
| 发送时机与目的地 | 仅在主动触发后，发送至所选 AI 服务；关闭自动发送时需手动确认发送 |
| API Key | 保存在 macOS 钥匙串中 |
| 翻译历史 | 应用不保存翻译历史 |
| 临时截图 | 短暂写入系统临时目录，读取后删除 |

> **整屏截图可能包含聊天、通知等私人信息。** 使用前请留意屏幕内容及所选服务地址。

#### 显示限制

- 译文以屏幕覆盖层显示，不修改原页面。
- 文字位置由 AI 估算，覆盖层不会跟随原页面移动。
- 鼠标操作或切换应用会清除覆盖层。
- 键盘翻页、动画或自动刷新后，也应重新框选或再次执行整屏翻译。

### 安装失败

查看 `screenlingo.command` 所在文件夹中的 `install.log`。

- 编译失败不会替换已安装的应用。
- 仅在实际更新时保留旧应用备份。
- 若 macOS 阻止打开，请按系统安全提示处理。

---

## English

### Features

- **Region translation**: Select an area using the floating button or keyboard shortcut.
- **Full-screen translation**: Translate the entire display containing the mouse pointer.
- **In-place overlays**: Show translations over the original text while keeping the surrounding area transparent.
- **Reading controls**: Set the source text reading direction, choose horizontal or vertical translation layout, and adjust the font size.
- **Provider configuration**: Choose a provider and model, and use your own API key. Custom models and third-party endpoints are supported.

### Installation

**Requires macOS 13 or later.**

1. Extract the installation package and double-click `screenlingo.command`.
2. If prompted to install Apple Command Line Tools, complete the installation and run the script again.
3. The script builds the app locally and opens `~/Applications/ScreenLingo.app`.

After installation, launch `ScreenLingo.app` directly.

> A fresh installation does not require an earlier version. Quit any running instance of ScreenLingo before updating.

### First-time setup

1. Open **Settings** in the upper-right corner of the window.
2. Select a provider and a model from the dropdown, enter your **API key**, and save.
3. To use an unlisted model, choose **Custom**. For a third-party service, also enter its **API endpoint URL**.
4. Grant **Screen Recording** permission when prompted. The app updates its permission status based on macOS. If macOS asks you to reopen the app, quit and launch it again.

### Usage

#### Shortcuts and floating button

| Action | Control |
| --- | --- |
| Start selecting a region | Click the floating 「译」 (Translate) button, or press `⌥⇧T` (Option + Shift + T) |
| Translate the selected region | Release the mouse button |
| Cancel region selection | Press `Esc` or right-click |
| Translate the full screen | Press `⌥T` (Option + T) |
| Move the floating button | Drag it |
| Change reading direction or translation layout, or open settings | Right-click the floating button |
| Cancel a pending translation | Click the floating button while waiting |

#### Full-screen translation

Press `⌥T`, or choose the full-screen translation option in the details view or the floating button's context menu, to capture and translate **the entire display containing the mouse pointer**.

Before capturing, ScreenLingo hides its windows, floating button, and previous translation overlays. The first full-screen translation in each app session asks you to confirm the capture area and service URL.

#### Optional: use T as a single-key shortcut

Choose **Settings → Full-screen translation shortcut → T**. The shortcut becomes active when you return to the floating button, which then displays a **T** indicator.

> **Single-key mode intercepts normal T input in other apps.** Right-click the floating button and choose **Pause** to resume typing. Opening the details window also pauses this mode automatically. The default `⌥T` shortcut leaves normal T input available.

#### Translation display and controls

Empty areas of the translation overlay are fully transparent. An opaque, light-colored background covers each original text region, with the translation displayed on top. The full original text region remains covered even when the translation is shorter.

- Each mask extends **2 screen points** beyond the text region to prevent the edges of the original text from showing.
- Overlapping text boxes are merged locally; they do not automatically fill the selection. Only manually clicking **「整块」** (cover the entire selection) fills the whole selected area.
- Controls beside the translation let you view the original text, adjust the font size, copy, or close the translation.
- Text that cannot be positioned remains available in the details view and copied output, with a notice in the toolbar. It does not cause an opaque background to cover the entire capture.
- If any text is cut off, open **Details** to read it.

#### Send screenshots manually

When **Auto-send** is disabled, screenshots are not uploaded immediately. Click the floating **「发」** (Send) button to send the screenshot to your selected service.

### Data and limitations

#### Screenshots and data handling

| Item | Behavior |
| --- | --- |
| Region translation | Sends a screenshot of the selected area |
| Full-screen translation | Sends a screenshot of the entire display containing the mouse pointer |
| When and where screenshots are sent | Only after you trigger the action, and only to the selected AI service; when Auto-send is disabled, sending requires an additional manual action |
| API key | Stored in macOS Keychain |
| Translation history | The app does not save translation history |
| Temporary screenshots | Briefly written to the system temporary directory and deleted after being read |

> **Full-screen screenshots may include private information, such as chats and notifications.** Check the screen contents and selected service URL before use.

#### Models and costs

The model dropdown contains preset options. Access and pricing are determined by the service provider. **A ChatGPT subscription does not include API credits.**

#### Display limitations

- Translations are screen overlays and do not modify the underlying page.
- Text positions are estimated by AI. Overlays do not move with the underlying content.
- Mouse interactions or switching apps clear the overlay.
- After keyboard-based page navigation, animations, or automatic refreshes, select the region again or run full-screen translation again.

### Installation troubleshooting

Usually Mac will disable installation. Go to System Setting, Privacy&Security, scroll down to find security section and allow applications from Screenlingo. 
For other issues, check `install.log` in the same folder as `screenlingo.command`.

- A failed build does not replace an existing installation.
- A backup of the previous app is kept only when an update actually takes place.
