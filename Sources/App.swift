import Cocoa
import WebKit
import Security
import LocalAuthentication
import UniformTypeIdentifiers
import Carbon.HIToolbox
import CoreGraphics

// Keychain credentials are bound to both provider and exact normalized API base URL.
// Changing a custom endpoint cannot silently reuse a key belonging to another endpoint.
final class CredentialStore {
    private let service = "local.screenlingo.app.api-keys"
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func exists(_ account: String) -> Bool {
        var q = query(account)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
    func read(_ account: String) throws -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else {
            throw AppError.message("无法读取钥匙串中的 API Key（\(status)）。请允许钥匙串访问，或重新保存 Key。")
        }
        return text
    }
    func save(_ key: String, account: String) throws {
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query(account) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = Data(key.utf8)
            q[kSecAttrLabel as String] = "ScreenLingo AI API Key"
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppError.message("API Key 无法保存到钥匙串（\(status)）。") }
    }
    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.message("删除 API Key 失败（\(status)）。")
        }
    }
    func deleteAll() throws {
        // Only this app's generic-password service, including formerly used endpoints.
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service]
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.message("删除 已存 API Key 失败（\(status)）。")
        }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate,
    WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var statusItem: NSStatusItem!
    var settings = AppSettings()
    let credentials = CredentialStore()
    let client = APIClient()
    var currentImage: Data?
    var currentImageSize = ""
    var lastResult: TranslationResult?
    var task: URLSessionDataTask?
    var requestID: UUID?
    var captureProcess: Process?
    var captureDirectory: URL?
    var isCapturing = false
    var isUninstalling = false
    var captureToken: UUID?
    var placementToken: UUID?
    var currentSelection: ScreenSelection?
    var pendingManual = false
    var bubble: FloatingBubbleController!
    let selector = SelectionController()
    let overlay = TranslationOverlayController()
    var mouseMonitor: Any?
    var isPinned = false
    var shortcutActive = false
    var hotkeyRef: EventHotKeyRef?
    var fullScreenHotkeyRef: EventHotKeyRef?
    var registeredFullScreenHotkey: String?
    var fullScreenShortcutActive = false
    var singleKeyManuallyPaused = false
    var pressedHotkeys = Set<UInt32>()
    var confirmingFullScreenCapture = false
    var confirmedFullScreenDestination: String?
    var eventHandlerRef: EventHandlerRef?
    var queuedEvents: [[String: Any]] = []
    var pageReady = false
    var openSettingsOnReady = false
    var startupWarning: String?
    let fm = FileManager.default

    var supportDirectory: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenLingo", isDirectory: true)
    }
    var settingsURL: URL { supportDirectory.appendingPathComponent("settings.json") }
    var indexURL: URL { Bundle.main.resourceURL!.appendingPathComponent("index.html") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bring the already-running copy forward rather than creating duplicate hotkeys.
        let same = NSRunningApplication.runningApplications(withBundleIdentifier: "local.screenlingo.app")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other = same.first {
            other.activate(options: [.activateIgnoringOtherApps]); NSApp.terminate(nil); return
        }
        loadSettings()
        cleanOrphanedCaptures()
        createMenu()
        createWindow()
        createFloatingUI()
        createStatusItem()
        bubble.show()
        registerHotkey()
        if !settings.consent { openSettings() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshScreenPermission()
    }
    func windowDidBecomeKey(_ notification: Notification) {
        refreshScreenPermission()
    }
    func refreshScreenPermission() {
        guard webView != nil else { return }
        // Refresh only permission state, never replace an unsaved settings draft.
        emit(["type": "screenPermission", "value": CGPreflightScreenCaptureAccess()])
    }

    func loadSettings() {
        guard fm.fileExists(atPath: settingsURL.path) else { return }
        do {
            settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsURL)).validated()
        } catch {
            startupWarning = "旧设置文件无法读取，已使用默认设置；钥匙串中的 Key 没有删除。"
        }
    }
    func persist(_ value: AppSettings) throws {
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: settingsURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
        settings = value
    }
    func cleanOrphanedCaptures() {
        let temp = fm.temporaryDirectory
        guard let files = try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for file in files where file.lastPathComponent.hasPrefix("ScreenLingo-capture-") {
            let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink != true { try? fm.removeItem(at: file) }
        }
    }

    func createMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 ScreenLingo", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: "隐藏 ScreenLingo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 ScreenLingo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let wm = NSMenu(title: "窗口"); windowItem.submenu = wm
        wm.addItem(withTitle: "查看原文与译文", action: #selector(showWindow), keyEquivalent: "0")
        wm.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        wm.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = main
        for item in appMenu.items where item.action == #selector(showAbout) || item.action == #selector(openSettings) { item.target = self }
        wm.items.first?.target = self
    }

    func createWindow() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(self, name: "screenlingo")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 790),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ScreenLingo · 框译"
        window.minSize = NSSize(width: 790, height: 650)
        window.backgroundColor = NSColor(calibratedRed: 0.965, green: 0.961, blue: 0.945, alpha: 1)
        window.contentView = webView
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setFrameAutosaveName("ScreenLingoMain")
        window.center()
        webView.loadFileURL(indexURL, allowingReadAccessTo: Bundle.main.resourceURL!)
    }

    func createFloatingUI() {
        bubble = FloatingBubbleController()
        bubble.view.onClick = { [weak self] in self?.bubbleClicked() }
        bubble.view.onClear = { [weak self] in self?.clearOverlay() }
        bubble.view.onMenu = { [weak self] event, view in
            guard let self = self else { return }
            NSMenu.popUpContextMenu(self.utilityMenu(), with: event, for: view)
        }
        overlay.onClose = { [weak self] in self?.clearOverlay() }
        overlay.onCopy = { [weak self] in self?.copyTranslation() }
        overlay.onDetails = { [weak self] in self?.showWindow() }
        overlay.onSend = { [weak self] in self?.translateImage() }
        // Mouse-only observation needs no keystroke interception. Never install an
        // event tap or log input. Clear fixed-position overlays when content moves.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self = self, self.currentSelection != nil else { return }
            self.cancelCurrentWork()
            self.setStatus("已清除原译文；需要时重新框选。")
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeAppChanged(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    func bubbleClicked() {
        guard !isUninstalling else { return }
        if isCapturing || task != nil { clearOverlay() }
        else if pendingManual && currentSelection != nil { translateImage() }
        else { captureScreen() }
    }
    @objc func showFloatingBubble() {
        NSApp.unhide(nil); bubble.show(); registerFullScreenHotkey(); refreshStatusMenu()
    }
    @objc func hideFloatingBubble() {
        bubble.hide(); registerFullScreenHotkey(); refreshStatusMenu()
    }
    @objc func returnToBubble() {
        guard !isUninstalling else { return }
        window.orderOut(nil); showFloatingBubble()
    }
    @objc func copyTranslation() {
        guard let text = lastResult?.translation, !text.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    func forgetPlacement() {
        overlay.dismiss(); currentSelection = nil; placementToken = nil; pendingManual = false
        if task == nil && !isCapturing { bubble?.setMode("idle") }
    }
    func cancelCurrentWork() {
        captureToken = nil; requestID = nil
        selector.cancel(notify: false)
        if captureProcess?.isRunning == true { captureProcess?.terminate() }
        captureProcess = nil
        if let dir = captureDirectory { try? fm.removeItem(at: dir) }; captureDirectory = nil
        task?.cancel(); task = nil; isCapturing = false
        forgetPlacement(); bubble?.setMode("idle"); bubble?.show()
        registerFullScreenHotkey()
        emit(["type": "busy", "value": false])
    }
    @objc func clearOverlay() {
        let wasBusy = task != nil
        cancelCurrentWork()
        setStatus(wasBusy ? "已清除并取消等待；服务端已处理的请求仍可能计费。" : "译文覆盖层已清除；点击悬浮球可重新框选。")
    }
    @objc func activeAppChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              currentSelection != nil else { return }
        cancelCurrentWork()
    }
    @objc func spaceChanged(_ notification: Notification) {
        if currentSelection != nil || isCapturing { cancelCurrentWork() }
    }
    @objc func screensChanged(_ notification: Notification) {
        if currentSelection != nil || isCapturing { cancelCurrentWork() }
        bubble?.keepOnScreen()
    }
    @objc func changeReadingOrder(_ sender: NSMenuItem) {
        guard !isUninstalling && task == nil && !isCapturing, let value = sender.representedObject as? String else { return }
        var candidate = settings; candidate.readingOrder = value
        do { try persist(candidate.validated()); refreshStatusMenu(); emit(["type": "refreshState"]) }
        catch { setStatus(error.localizedDescription, kind: "error") }
    }
    @objc func changeOverlayDirection(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String { overlay.setDirection(value); refreshStatusMenu() }
    }
    func utilityMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self
        }
        add("框选翻译  " + shortcutLabel, #selector(captureScreen))
        add("整屏翻译  " + fullScreenShortcutLabel, #selector(captureFullScreen))
        if settings.fullScreenHotkey == "t" {
            add(singleKeyManuallyPaused ? "恢复 T 单键翻译" : "暂停 T 单键（恢复打字）", #selector(toggleSingleKeyHotkey))
        }
        add("清除译文 / 取消请求", #selector(clearOverlay))
        add("复制完整译文", #selector(copyTranslation))
        menu.addItem(.separator())
        let reading = NSMenu(); let readingItem = NSMenuItem(title: "原文阅读方向", action: nil, keyEquivalent: "")
        readingItem.submenu = reading; menu.addItem(readingItem)
        for (value, title) in [("auto", "自动判断"), ("horizontal", "横排"), ("vertical-rtl", "竖排 · 列从右到左"), ("vertical-ltr", "竖排 · 列从左到右")] {
            let item = reading.addItem(withTitle: title, action: #selector(changeReadingOrder(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value; item.state = settings.readingOrder == value ? .on : .off
        }
        let writing = NSMenu(); let writingItem = NSMenuItem(title: "译文排版", action: nil, keyEquivalent: "")
        writingItem.submenu = writing; menu.addItem(writingItem)
        for (value, title) in [("auto", "跟随识别布局"), ("horizontal", "译文横排"), ("vertical-rtl", "译文竖排 · 列从右到左"), ("vertical-ltr", "译文竖排 · 列从左到右")] {
            let item = writing.addItem(withTitle: title, action: #selector(changeOverlayDirection(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value; item.state = overlay.direction == value ? .on : .off
        }
        menu.addItem(.separator())
        add("查看原文与完整译文", #selector(showWindow))
        add("设置…", #selector(openSettings))
        add("显示悬浮球", #selector(showFloatingBubble))
        add("隐藏悬浮球", #selector(hideFloatingBubble))
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 ScreenLingo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "ScreenLingo") {
            image.isTemplate = true; statusItem.button?.image = image
        } else { statusItem.button?.title = "译" }
        statusItem.button?.toolTip = "ScreenLingo · 框选翻译"
        refreshStatusMenu()
    }
    var shortcutLabel: String {
        switch settings.hotkey {
        case "control-option-t": return "⌃⌥T"
        case "command-shift-y": return "⇧⌘Y"
        default: return "⌥⇧T"
        }
    }
    var fullScreenShortcutLabel: String {
        switch settings.fullScreenHotkey {
        case "t": return "T"
        case "control-option-f": return "⌃⌥F"
        case "disabled": return ""
        default: return "⌥T"
        }
    }
    var singleKeySuspended: Bool {
        settings.fullScreenHotkey == "t" &&
            (singleKeyManuallyPaused || window?.isVisible == true || bubble?.panel.isVisible != true || confirmingFullScreenCapture)
    }
    @objc func toggleSingleKeyHotkey() {
        singleKeyManuallyPaused.toggle()
        registerFullScreenHotkey(); refreshStatusMenu(); emit(["type": "refreshState"])
    }
    func refreshStatusMenu() {
        guard statusItem != nil else { return }
        statusItem.menu = utilityMenu()
    }
    func registerHotkey() {
        if let ref = hotkeyRef { UnregisterEventHotKey(ref); hotkeyRef = nil }
        pressedHotkeys.removeAll()
        if eventHandlerRef == nil {
            let specs = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            ]
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            // Infer Carbon count/size integer types from the installed SDK.
            specs.withUnsafeBufferPointer { buffer in
                _ = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
                    guard let data = data, let event = event else { return OSStatus(eventNotHandledErr) }
                    var identifier = EventHotKeyID(signature: 0, id: 0)
                    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID), nil, numericCast(MemoryLayout<EventHotKeyID>.size), nil, &identifier)
                    guard status == noErr, identifier.signature == OSType(0x534C4E47),
                          identifier.id == 1 || identifier.id == 2 else { return OSStatus(eventNotHandledErr) }
                    let controller = Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue()
                    let id = identifier.id
                    let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                    DispatchQueue.main.async { controller.handleHotkey(id, pressed: down) }
                    return noErr
                }, numericCast(buffer.count), buffer.baseAddress, pointer, &eventHandlerRef)
            }
        }
        let modifiers: UInt32
        let key: UInt32
        switch settings.hotkey {
        case "control-option-t": modifiers = UInt32(controlKey | optionKey); key = UInt32(kVK_ANSI_T)
        case "command-shift-y": modifiers = UInt32(cmdKey | shiftKey); key = UInt32(kVK_ANSI_Y)
        default: modifiers = UInt32(optionKey | shiftKey); key = UInt32(kVK_ANSI_T)
        }
        let identifier = EventHotKeyID(signature: OSType(0x534C4E47), id: 1)
        let status = RegisterEventHotKey(key, modifiers, identifier, GetApplicationEventTarget(), 0, &hotkeyRef)
        shortcutActive = status == noErr && eventHandlerRef != nil
        registerFullScreenHotkey()
        refreshStatusMenu()
    }
    func registerFullScreenHotkey() {
        let desired: String? = !isUninstalling && eventHandlerRef != nil && settings.fullScreenHotkey != "disabled" && !singleKeySuspended
            ? settings.fullScreenHotkey : nil
        // Do not unregister a held hotkey on routine UI/capture transitions.
        if desired == registeredFullScreenHotkey && (desired == nil || fullScreenHotkeyRef != nil) { return }
        registeredFullScreenHotkey = nil
        if let ref = fullScreenHotkeyRef { UnregisterEventHotKey(ref); fullScreenHotkeyRef = nil }
        fullScreenShortcutActive = false
        pressedHotkeys.remove(2)
        bubble?.setSingleKeyActive(false)
        guard !isUninstalling, eventHandlerRef != nil, settings.fullScreenHotkey != "disabled", !singleKeySuspended else { return }
        let modifiers: UInt32
        let key: UInt32
        switch settings.fullScreenHotkey {
        case "t": modifiers = 0; key = UInt32(kVK_ANSI_T)
        case "control-option-f": modifiers = UInt32(controlKey | optionKey); key = UInt32(kVK_ANSI_F)
        default: modifiers = UInt32(optionKey); key = UInt32(kVK_ANSI_T)
        }
        let id = EventHotKeyID(signature: OSType(0x534C4E47), id: 2)
        let status = RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &fullScreenHotkeyRef)
        fullScreenShortcutActive = status == noErr
        if fullScreenShortcutActive { registeredFullScreenHotkey = settings.fullScreenHotkey }
        bubble?.setSingleKeyActive(settings.fullScreenHotkey == "t" && fullScreenShortcutActive)
    }
    func handleHotkey(_ id: UInt32, pressed: Bool) {
        if !pressed { pressedHotkeys.remove(id); return }
        // Holding a key must not issue several billable screenshot requests.
        guard pressedHotkeys.insert(id).inserted, !confirmingFullScreenCapture, !isUninstalling else { return }
        if id == 2 {
            guard settings.fullScreenHotkey != "t" || !singleKeySuspended else { return }
            captureFullScreen()
        } else { captureScreen() }
    }

    @objc func showWindow() {
        guard window != nil else { return }
        forgetPlacement()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        registerFullScreenHotkey(); refreshStatusMenu()
    }
    @objc func openSettings() {
        guard !isUninstalling else { return }
        showWindow()
        if pageReady { emit(["type": "settings"]) } else { openSettingsOnReady = true }
    }
    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "ScreenLingo · 框译", .applicationVersion: "0.3.1",
            .credits: NSAttributedString(string: "by hungryfish")])
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isUninstalling else { return false }
        sender.orderOut(nil); showFloatingBubble(); return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isUninstalling ? .terminateCancel : .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showFloatingBubble(); if !settings.consent { openSettings() }; return true }
    func applicationWillTerminate(_ notification: Notification) {
        captureToken = nil; requestID = nil
        selector.cancel(notify: false); overlay.dismiss(); bubble?.hide()
        if let mouseMonitor = mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        task?.cancel()
        if captureProcess?.isRunning == true { captureProcess?.terminate() }
        if let dir = captureDirectory { try? fm.removeItem(at: dir) }
        if let hotkeyRef = hotkeyRef { UnregisterEventHotKey(hotkeyRef) }
        if let ref = fullScreenHotkeyRef { UnregisterEventHotKey(ref) }
        if let eventHandlerRef = eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    // The WebView loads bundled files only. Source text and model output are never executable HTML.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        decisionHandler(url.isFileURL && url.standardizedFileURL.path == indexURL.standardizedFileURL.path ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        for event in queuedEvents { send(event) }; queuedEvents.removeAll()
        if let warning = startupWarning { emit(["type": "status", "kind": "warning", "text": warning]) }
        if openSettingsOnReady { emit(["type": "settings"]); openSettingsOnReady = false }
    }
    func emit(_ event: [String: Any]) {
        if pageReady { send(event) } else { queuedEvents.append(event) }
    }
    func send(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.ScreenLingoNative && window.ScreenLingoNative(\(json));", completionHandler: nil)
    }
    func reply(_ id: String, value: Any? = nil, error: String? = nil) {
        var object: [String: Any] = ["type": "reply", "id": id]
        if let error = error { object["error"] = error } else { object["value"] = value ?? NSNull() }
        // During document loading, request replies must not wait for didFinish:
        // the JavaScript bootstrap may already be waiting for this response.
        send(object)
    }
    func state() -> [String: Any] {
        let encoded = (try? JSONEncoder().encode(settings)) ?? Data("{}".utf8)
        let obj = (try? JSONSerialization.jsonObject(with: encoded)) ?? [:]
        var keyFlags: [String: Bool] = [:]
        for p in AIProvider.allCases {
            let profile = settings.profiles[p.rawValue] ?? ProviderProfile.defaults(p)
            if let account = try? APIClient.credentialAccount(provider: p, profile: profile) { keyFlags[p.rawValue] = credentials.exists(account) }
            else { keyFlags[p.rawValue] = false }
        }
        var result: [String: Any] = ["settings": obj, "keys": keyFlags,
            "screenPermission": CGPreflightScreenCaptureAccess(), "shortcutActive": shortcutActive,
            "shortcutLabel": shortcutLabel, "fullScreenShortcutLabel": fullScreenShortcutLabel,
            "fullScreenShortcutActive": fullScreenShortcutActive, "fullScreenShortcutPaused": singleKeySuspended,
            "pinned": isPinned, "uninstalling": isUninstalling, "busy": task != nil || isCapturing || confirmingFullScreenCapture]
        if let data = currentImage {
            result["image"] = "data:image/png;base64," + data.base64EncodedString()
            result["imageSize"] = currentImageSize
        }
        if let last = lastResult, let data = try? JSONEncoder().encode(last),
           let obj = try? JSONSerialization.jsonObject(with: data) { result["result"] = obj }
        return result
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL.path == indexURL.standardizedFileURL.path,
              let body = message.body as? [String: Any], let id = body["id"] as? String,
              id.count < 100, let action = body["action"] as? String else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        do {
            guard !isUninstalling || action == "getState" || action == "getScreenPermission" else {
                throw AppError.message("请先完成或取消卸载确认。")
            }
            switch action {
            case "uninstall": try beginUninstall(); reply(id, value: true)
            case "getState": reply(id, value: state())
            case "getScreenPermission": reply(id, value: CGPreflightScreenCaptureAccess())
            case "saveSettings":
                guard task == nil && !isCapturing else { throw AppError.message("请先等待或取消当前任务。") }
                guard let obj = payload["settings"] else { throw AppError.message("缺少设置内容。") }
                let data = try JSONSerialization.data(withJSONObject: obj)
                let candidate = try JSONDecoder().decode(AppSettings.self, from: data).validated()
                let account = try APIClient.credentialAccount(provider: candidate.provider, profile: candidate.activeProfile)
                let key = (payload["apiKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                try APIClient.validateAPIKey(key)
                if payload["deleteKey"] as? Bool == true { try credentials.delete(account) }
                else if !key.isEmpty { try credentials.save(key, account: account) }
                let changedFullScreenHotkey = settings.fullScreenHotkey != candidate.fullScreenHotkey
                try persist(candidate)
                if changedFullScreenHotkey { singleKeyManuallyPaused = false }
                registerHotkey()
                reply(id, value: state())
            case "quickOptions":
                guard task == nil && !isCapturing else { throw AppError.message("任务进行中，请稍后更改选项。") }
                var candidate = settings
                if let value = payload["sourceLanguage"] as? String { candidate.sourceLanguage = value }
                if let value = payload["targetLanguage"] as? String { candidate.targetLanguage = value }
                if let value = payload["readingOrder"] as? String { candidate.readingOrder = value }
                try persist(candidate.validated()); reply(id, value: state())
            case "capture": reply(id, value: true); captureScreen()
            case "captureFullScreen": reply(id, value: true); captureFullScreen()
            case "openImage": reply(id, value: true); openImage()
            case "translateImage": reply(id, value: true); translateImage()
            case "translateText":
                let source = payload["text"] as? String ?? ""
                guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("原文为空，请先识别或粘贴文字。") }
                reply(id, value: true); startRequest(image: nil, sourceText: source)
            case "cancel": clearOverlay(); reply(id, value: true)
            case "returnToBubble": returnToBubble(); reply(id, value: true)
            case "dismissOverlay": clearOverlay(); reply(id, value: true)
            case "clear":
                guard task == nil && !isCapturing else { throw AppError.message("请先取消当前任务。") }
                forgetPlacement()
                resetContent(); reply(id, value: true)
            case "copy":
                let text = payload["text"] as? String ?? ""
                guard text.count <= 200000 else { throw AppError.message("复制内容过长。") }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                reply(id, value: true)
            case "pin":
                isPinned.toggle(); window.level = isPinned ? .floating : .normal
                reply(id, value: isPinned)
            case "permission":
                let alreadyAllowed = CGPreflightScreenCaptureAccess()
                let granted = alreadyAllowed || CGRequestScreenCaptureAccess()
                if alreadyAllowed || !granted { openPrivacySettings(showInstructions: !granted) }
                emit(["type": "screenPermission", "value": granted])
                reply(id, value: granted)
            case "external":
                let links: [String: String] = [
                    "openaiKeys": "https://platform.openai.com/api-keys",
                    "geminiKeys": "https://aistudio.google.com/apikey",
                    "openaiBilling": "https://platform.openai.com/settings/organization/billing/overview"]
                if let name = payload["name"] as? String, let link = links[name], let url = URL(string: link) { NSWorkspace.shared.open(url) }
                reply(id, value: true)
            default: throw AppError.message("未知操作。")
            }
        } catch { reply(id, error: error.localizedDescription) }
    }

    func setStatus(_ text: String, kind: String = "info") { emit(["type": "status", "kind": kind, "text": text]) }
    func openPrivacySettings(showInstructions: Bool = true) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
        if showInstructions {
            setStatus("允许屏幕录制后，返回软件会刷新状态；如系统提示重新打开，请退出并重开 ScreenLingo。", kind: "warning")
        }
    }
    func ensureReady() throws -> String {
        guard settings.consent else { throw AppError.message("请在设置中确认：翻译时会把所选截图或原文发送给所选AI。") }
        let profile = settings.activeProfile
        let account = try APIClient.credentialAccount(provider: settings.provider, profile: profile)
        let key = try credentials.read(account)
        // Validate the profile and key without making a request.
        _ = try APIClient.makeRequest(settings: settings, key: key, sourceText: "")
        return key
    }

    @objc func captureScreen() {
        guard !isUninstalling && !isCapturing && task == nil && !confirmingFullScreenCapture else { return }
        if settings.autoTranslate {
            do { _ = try ensureReady() }
            catch { openSettings(); setStatus(error.localizedDescription, kind: "error"); return }
        }
        let screenAllowed = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        emit(["type": "screenPermission", "value": screenAllowed])
        guard screenAllowed else {
            showWindow(); openPrivacySettings(); return
        }
        beginCapture()
    }
    @objc func captureFullScreen() {
        guard !isUninstalling && !isCapturing && task == nil && !confirmingFullScreenCapture else { return }
        // Choose the display BEFORE showing any dialog or moving keyboard focus.
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
              let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            setStatus("没有找到可截取的屏幕。", kind: "error"); return
        }
        if settings.autoTranslate {
            do { _ = try ensureReady() }
            catch { openSettings(); setStatus(error.localizedDescription, kind: "error"); return }
        }
        let allowed = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        emit(["type": "screenPermission", "value": allowed])
        guard allowed else { showWindow(); openPrivacySettings(); return }
        guard confirmFullScreenCapture() else { return }
        // A display could have disconnected while the confirmation was open.
        guard let currentScreen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == displayNumber
        }), let selection = ScreenSelection.entireScreen(currentScreen) else {
            setStatus("原屏幕已断开，请重新截屏。", kind: "warning"); return
        }
        beginCapture(fullScreen: selection)
    }
    func confirmFullScreenCapture() -> Bool {
        let destination = settings.provider.label + " · " + settings.activeProfile.baseURL
        // A preview-only confirmation does not authorize later automatic uploads.
        let consentScope = destination + (settings.autoTranslate ? "|send" : "|preview")
        if confirmedFullScreenDestination == consentScope { return true }
        confirmingFullScreenCapture = true
        registerFullScreenHotkey()
        let previousApp = NSWorkspace.shared.frontmostApplication
        defer {
            confirmingFullScreenCapture = false
            registerFullScreenHotkey(); refreshStatusMenu()
        }
        let alert = NSAlert()
        alert.messageText = "整屏翻译会截取一整块屏幕"
        alert.informativeText = "范围是触发时鼠标所在的整个显示器。\n\n" +
            (settings.autoTranslate ? "截图将发送至：" : "截图先在本机预览；点击发送后才会上传至：") + destination +
            "。\n\n本次启动且服务地址、发送方式不变时，只确认一次。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: settings.autoTranslate ? "截屏并翻译" : "截屏预览")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        let accepted = alert.runModal() == .alertSecondButtonReturn
        if let previousApp = previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate(options: [.activateIgnoringOtherApps])
        }
        if accepted { confirmedFullScreenDestination = consentScope }
        return accepted
    }
    func beginCapture(fullScreen: ScreenSelection? = nil) {
        forgetPlacement()
        let token = UUID(); captureToken = token
        isCapturing = true
        emit(["type": "busy", "value": true, "capturing": true])
        window.orderOut(nil)
        registerFullScreenHotkey()
        bubble.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, self.captureToken == token else { return }
            if let selection = fullScreen {
                self.captureSelectedArea(selection, token: token)
                return
            }
            self.selector.start { [weak self] value in
                guard let self = self, self.captureToken == token else { return }
                guard let selection = value else {
                    self.captureToken = nil; self.isCapturing = false
                    self.bubble.show(); self.registerFullScreenHotkey(); self.emit(["type": "busy", "value": false])
                    self.setStatus("已取消框选；未上传截图。")
                    return
                }
                // Allow the window server to remove selection panels before capture.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                    guard let self = self, self.captureToken == token else { return }
                    self.captureSelectedArea(selection, token: token)
                }
            }
        }
    }
    func captureSelectedArea(_ selection: ScreenSelection, token: UUID) {
        let rect = selection.captureRect
        guard rect.width > 0, rect.height > 0 else { cancelCurrentWork(); return }
        resetContent(quiet: true)
        let dir = fm.temporaryDirectory.appendingPathComponent("ScreenLingo-capture-" + UUID().uuidString, isDirectory: true)
        let file = dir.appendingPathComponent("selection.png")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            captureDirectory = dir
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // Capture only the requested rectangle (or one explicitly chosen display).
            // No clipboard write, shell interpolation, or multi-display stitching.
            process.arguments = ["-x", "-t", "png", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", file.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] proc in
                let data = try? Data(contentsOf: file)
                try? FileManager.default.removeItem(at: dir)
                DispatchQueue.main.async {
                    guard let self = self, self.captureToken == token else { return }
                    self.captureToken = nil; self.captureProcess = nil; self.captureDirectory = nil; self.isCapturing = false
                    self.bubble.show(); self.emit(["type": "busy", "value": false])
                    if proc.terminationStatus == 0, let data = data, !data.isEmpty {
                        self.currentSelection = selection; self.placementToken = UUID()
                        self.acceptImage(data)
                    } else {
                        self.overlay.showStatus("截图失败 · 右键悬浮球检查权限或查看详情", selection: selection)
                        self.setStatus("没有获得截图。请检查屏幕录制权限；受保护的视频或系统画面可能无法截取。", kind: "error")
                        if !CGPreflightScreenCaptureAccess() { self.showWindow(); self.openPrivacySettings() }
                    }
                }
            }
            captureProcess = process; try process.run()
        } catch {
            try? fm.removeItem(at: dir)
            cancelCurrentWork()
            setStatus("无法截取所选区域：" + error.localizedDescription, kind: "error")
            overlay.showStatus("截图失败 · 点详情查看错误", selection: selection)
        }
    }

    func openImage() {
        guard !isUninstalling else { return }
        guard task == nil && !isCapturing else { setStatus("请先等待或取消当前任务。", kind: "warning"); return }
        showWindow()
        let panel = NSOpenPanel()
        panel.title = "选择需要识别的图片"
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 24 * 1024 * 1024 else { throw AppError.message("图片文件过大。") }
                let data = try Data(contentsOf: url)
                guard let bitmap = NSBitmapImageRep(data: data),
                      bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
                      bitmap.pixelsWide <= 12000, bitmap.pixelsHigh <= 12000,
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw AppError.message("无法读取这张图片，请改用 PNG 或 JPEG 截图。")
                }
                self.acceptImage(png)
            } catch { self.setStatus(error.localizedDescription, kind: "error") }
        }
    }
    func resetContent(quiet: Bool = false) {
        currentImage = nil; lastResult = nil; currentImageSize = ""
        emit(["type": "clear", "quiet": quiet])
    }
    func acceptImage(_ data: Data) {
        guard data.count <= APIClient.maxImageBytes,
              let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
            resetContent(quiet: true)
            setStatus("截图无法读取，或超过 12 MB。请缩小框选范围。", kind: "error")
            if let selection = currentSelection { overlay.showStatus("截图过大或无法读取 · 请缩小选区", selection: selection) }
            currentSelection = nil; placementToken = nil; bubble?.setMode("idle"); return
        }
        currentImage = data; lastResult = nil
        currentImageSize = "\(rep.pixelsWide) × \(rep.pixelsHigh) px"
        emit(["type": "image", "url": "data:image/png;base64," + data.base64EncodedString(), "size": currentImageSize])
        if settings.autoTranslate { translateImage() }
        else {
            setStatus("截图已就绪，尚未上传。点击悬浮球「发」或「识别并翻译」发送。")
            if let selection = currentSelection {
                pendingManual = true; bubble.setMode("pending")
                overlay.showStatus("截图尚未上传 · 点击发送开始翻译", selection: selection, pending: true)
            }
        }
    }
    func translateImage() {
        guard let data = currentImage else { setStatus("请先框选屏幕或打开图片。", kind: "warning"); return }
        startRequest(image: data, sourceText: nil)
    }
    func startRequest(image: Data?, sourceText: String?) {
        guard !isUninstalling else { return }
        guard task == nil && !isCapturing else { setStatus("请先等待或取消当前任务。", kind: "warning"); return }
        do {
            let key = try ensureReady()
            let snapshot = settings
            let placement = image != nil ? currentSelection : nil
            let placementID = placement != nil ? placementToken : nil
            let request = try APIClient.makeRequest(settings: snapshot, key: key, image: image, sourceText: sourceText, positioned: placement != nil)
            pendingManual = false
            bubble.setMode("busy")
            if let selection = placement { overlay.showStatus("正在识别翻译… 点击悬浮球可取消", selection: selection) }
            let id = UUID(); requestID = id
            emit(["type": "busy", "value": true])
            setStatus(image == nil ? "正在翻译修改后的原文…" : "正在识别并翻译所选区域…")
            task = client.perform(request, provider: snapshot.provider, secret: key) { [weak self] outcome in
                DispatchQueue.main.async {
                    guard let self = self, self.requestID == id else { return }
                    self.task = nil; self.requestID = nil
                    self.bubble.setMode("idle")
                    self.emit(["type": "busy", "value": false])
                    switch outcome {
                    case .success(let text):
                        let result = APIClient.parseTranslation(text, original: sourceText)
                        self.lastResult = result
                        if let data = try? JSONEncoder().encode(result), let obj = try? JSONSerialization.jsonObject(with: data) {
                            self.emit(["type": "result", "value": obj])
                        }
                        if let selection = placement, placementID == self.placementToken, self.currentSelection != nil {
                            if result.structured { self.overlay.show(result: result, selection: selection) }
                            else { self.overlay.showStatus("回复格式不正确 · 请点详情核对", selection: selection) }
                        }
                        self.setStatus(result.structured ? "已完成 · 原位译文可清除，完整原文与译文在此保留至清空或退出" : "已收到回复，但返回格式不符合要求。", kind: result.structured ? "success" : "warning")
                    case .failure(let error):
                        var message = error.localizedDescription
                        if !key.isEmpty { message = message.replacingOccurrences(of: key, with: "[已隐藏]") }
                        if (error as NSError).code == NSURLErrorTimedOut { message = "请求超时。请检查网络、API 地址，或缩小截图后重试。" }
                        self.setStatus(String(message.prefix(1000)), kind: "error")
                        if let selection = placement, placementID == self.placementToken, self.currentSelection != nil {
                            self.overlay.showStatus("请求失败 · 点详情查看原因", selection: selection)
                        }
                    }
                }
            }
        } catch {
            bubble?.setMode("idle")
            setStatus(error.localizedDescription, kind: "error")
            if let selection = currentSelection { overlay.showStatus("无法发送 · 右键悬浮球检查设置", selection: selection) }
            if !settings.consent || settings.activeProfile.model.isEmpty { openSettings() }
        }
    }
}

@main
struct ScreenLingoMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let controller = AppController()
        application.setActivationPolicy(.accessory)
        application.delegate = controller
        withExtendedLifetime(controller) { application.run() }
    }
}
