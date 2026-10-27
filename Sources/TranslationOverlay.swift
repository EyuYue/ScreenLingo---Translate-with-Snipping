import Cocoa
import WebKit

@MainActor
final class TranslationOverlayController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var panel: PassivePanel?
    private var toolbar: PassivePanel?
    private var webView: WKWebView?
    private var label: NSTextField?
    private var originalButton: NSButton?
    private var layoutButton: NSButton?
    private var result: TranslationResult?
    private var selection: ScreenSelection?
    private var loaded = false
    private var hidden = false
    private var wholeSelection = false
    private var pending = false
    private var needsReview = false
    private var fontSize = 21.0
    var direction = UserDefaults.standard.string(forKey: "overlayDirection") ?? "auto"
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDetails: (() -> Void)?
    var onSend: (() -> Void)?
    private var indexURL: URL { Bundle.main.resourceURL!.appendingPathComponent("overlay.html") }

    func showStatus(_ text: String, selection: ScreenSelection, pending: Bool = false) {
        dismiss()
        self.selection = selection; self.pending = pending
        makeToolbar(text: text, hasResult: false)
    }
    func show(result: TranslationResult, selection: ScreenSelection) {
        dismiss()
        self.selection = selection; self.result = result
        self.wholeSelection = false  // Full-selection masking is opt-in, never an automatic fallback.
        self.needsReview = !result.notes.isEmpty
        guard !result.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            makeToolbar(text: result.notes.isEmpty ? "未识别到可翻译文字" : result.notes, hasResult: false)
            return
        }
        let p = PassivePanel(contentRect: selection.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureOverlayPanel(p)
        p.ignoresMouseEvents = true  // Never intercept clicks intended for the reader/browser.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(self, name: "overlayReport")
        let web = WKWebView(frame: NSRect(origin: .zero, size: selection.frame.size), configuration: config)
        web.autoresizingMask = [.width, .height]
        // Clear every backing layer; keep the window at full opacity so text masks
        // remain genuinely opaque instead of making the entire overlay translucent.
        p.alphaValue = 1
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.wantsLayer = true
        web.layer?.backgroundColor = NSColor.clear.cgColor
        web.navigationDelegate = self
        p.contentView = web; self.panel = p; self.webView = web
        web.loadFileURL(indexURL, allowingReadAccessTo: Bundle.main.resourceURL!)
        p.orderFrontRegardless()
        makeToolbar(text: statusText(), hasResult: true)
    }
    func dismiss() {
        panel?.orderOut(nil); toolbar?.orderOut(nil)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "overlayReport")
        webView?.navigationDelegate = nil
        panel = nil; toolbar = nil; webView = nil; label = nil
        originalButton = nil; layoutButton = nil
        selection = nil; result = nil; loaded = false; hidden = false; pending = false; needsReview = false
        wholeSelection = false
    }
    func setDirection(_ value: String) {
        guard ["auto", "horizontal", "vertical-rtl", "vertical-ltr"].contains(value) else { return }
        direction = value; UserDefaults.standard.set(value, forKey: "overlayDirection"); render()
    }
    private func statusText() -> String {
        if !wholeSelection, result?.blocks.isEmpty == true { return "未返回文字位置 · 点整块或详情" }
        if !wholeSelection, result?.positioningIncomplete == true { return "部分文字未定位 · 点详情核对" }
        if needsReview { return "译文有不确定处 · 点详情核对" }
        return wholeSelection ? "整块覆盖" : "透明背景 · \(result?.blocks.count ?? 0) 处文字"
    }
    private func button(_ title: String, _ action: Selector, _ tip: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded; b.controlSize = .small; b.font = .systemFont(ofSize: 12)
        b.toolTip = tip
        return b
    }
    private func makeToolbar(text: String, hasResult: Bool) {
        guard let selection = selection else { return }
        toolbar?.orderOut(nil)
        let width: CGFloat = min(hasResult ? 452 : 390, selection.visibleFrame.width-16)
        let height: CGFloat = 40
        let vf = selection.visibleFrame
        let x = max(vf.minX+8, min(selection.frame.minX, vf.maxX-width-8))
        let preferredY = selection.frame.maxY+8
        let y: CGFloat
        if preferredY+height <= vf.maxY { y = preferredY }
        else if selection.frame.minY-height-8 >= vf.minY { y = selection.frame.minY-height-8 }
        else { y = max(vf.minY+8, vf.maxY-height-8) }
        let p = PassivePanel(contentRect: NSRect(x: x, y: y, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureOverlayPanel(p, level: 2); p.hasShadow = true
        let background = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor
        background.layer?.cornerRadius = 10
        p.contentView = background
        let stack = NSStackView(); stack.orientation = .horizontal; stack.spacing = 4; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false; background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -5)])
        let label = NSTextField(labelWithString: text)
        label.textColor = NSColor(calibratedWhite: 0.18, alpha: 1)
        label.font = .systemFont(ofSize: 11, weight: .medium); label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1; label.toolTip = text
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(label); self.label = label
        if hasResult {
            let original = button("原文", #selector(toggleOriginal), "临时隐藏译文，查看原文；再次点击恢复")
            stack.addArrangedSubview(original); originalButton = original
            let layout = button(wholeSelection ? "分区" : "整块", #selector(toggleLayout), "默认只遮盖文字；点击整块才会遮盖整个选区")
            stack.addArrangedSubview(layout); layoutButton = layout
            stack.addArrangedSubview(button("A−", #selector(smaller), "缩小译文字号"))
            stack.addArrangedSubview(button("A+", #selector(larger), "增大译文字号；超过原区域会提示查看详情"))
            stack.addArrangedSubview(button("复制", #selector(copyText), "复制完整译文"))
        } else if pending {
            stack.addArrangedSubview(button("发送", #selector(sendImage), "把已框选的截图发送给所选 AI 服务"))
        }
        stack.addArrangedSubview(button("详情", #selector(details), "查看截图、可编辑原文和完整译文"))
        stack.addArrangedSubview(button("×", #selector(closeOverlay), "清除译文 / 取消当前请求"))
        toolbar = p; p.orderFrontRegardless()
    }
    @objc private func toggleOriginal() {
        hidden.toggle()
        if hidden { panel?.orderOut(nil) } else { panel?.orderFrontRegardless() }
        originalButton?.title = hidden ? "译文" : "原文"
    }
    @objc private func toggleLayout() {
        wholeSelection.toggle(); layoutButton?.title = wholeSelection ? "分区" : "整块"
        label?.stringValue = statusText(); render()
    }
    @objc private func smaller() { fontSize = max(10, fontSize-2); render() }
    @objc private func larger() { fontSize = min(48, fontSize+2); render() }
    @objc private func copyText() { onCopy?() }
    @objc private func details() { onDetails?() }
    @objc private func sendImage() { onSend?() }
    @objc private func closeOverlay() { onClose?() }
    private func render() {
        guard loaded, let result = result else { return }
        let data = try? JSONEncoder().encode(result)
        guard let data = data, let object = try? JSONSerialization.jsonObject(with: data) else { return }
        let payload: [String: Any] = ["result": object, "wholeSelection": wholeSelection, "direction": direction, "fontSize": fontSize]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: encoded, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.renderOverlay(\(json));", completionHandler: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; render() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.request.url?.standardizedFileURL.path == indexURL.standardizedFileURL.path
        decisionHandler(allowed ? .allow : .cancel)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL.path == indexURL.standardizedFileURL.path,
              let obj = message.body as? [String: Any] else { return }
        if obj["missingPositions"] as? Bool == true { label?.stringValue = "未返回文字位置 · 点整块或详情" }
        else if obj["overflow"] as? Bool == true { label?.stringValue = "部分译文放不下 · 点整块或详情" }
        else if obj["incomplete"] as? Bool == true, !wholeSelection { label?.stringValue = "部分文字未定位 · 点详情核对" }
        else { label?.stringValue = statusText() }
        label?.toolTip = label?.stringValue
    }
}
