import Cocoa
import Carbon.HIToolbox
import WebKit
import CoreGraphics

// Panels float over the current application without activating ScreenLingo.
class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
final class SelectionPanel: PassivePanel {
    override var canBecomeKey: Bool { true }
}
@MainActor
func configureOverlayPanel(_ panel: NSPanel, level: Int = 0) {
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isFloatingPanel = true
    panel.isReleasedWhenClosed = false
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + level)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
}

final class BubbleView: NSView {
    var onClick: (() -> Void)?
    var onClear: (() -> Void)?
    var onMenu: ((NSEvent, NSView) -> Void)?
    var onMoved: (() -> Void)?
    var mode = "idle" { didSet { needsDisplay = true } }
    var singleKeyActive = false { didSet { needsDisplay = true } }
    private var mouseStart = NSPoint.zero
    private var windowStart = NSPoint.zero
    private var moved = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 6, dy: 6)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -2); shadow.shadowBlurRadius = 5; shadow.set()
        let color: NSColor
        switch mode {
        case "busy": color = NSColor(calibratedRed: 0.66, green: 0.39, blue: 0.10, alpha: 1)
        case "pending": color = NSColor(calibratedRed: 0.20, green: 0.44, blue: 0.65, alpha: 1)
        default: color = NSColor(calibratedRed: 0.12, green: 0.37, blue: 0.34, alpha: 1)
        }
        color.setFill(); NSBezierPath(ovalIn: circle).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let rim = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5)); rim.lineWidth = 1; rim.stroke()
        let text = mode == "busy" ? "···" : (mode == "pending" ? "发" : "译")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 23, weight: .semibold), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2), withAttributes: attributes)
        if singleKeyActive {
            let badge = NSRect(x: bounds.maxX-22, y: 5, width: 18, height: 18)
            NSColor.white.setFill(); NSBezierPath(ovalIn: badge).fill()
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: color]
            let s = ("T" as NSString).size(withAttributes: a)
            ("T" as NSString).draw(at: NSPoint(x: badge.midX-s.width/2, y: badge.midY-s.height/2), withAttributes: a)
        }
    }
    override func mouseDown(with event: NSEvent) {
        mouseStart = NSEvent.mouseLocation; windowStart = window?.frame.origin ?? .zero; moved = false
    }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        if hypot(p.x-mouseStart.x, p.y-mouseStart.y) > 4 { moved = true }
        if moved { window?.setFrameOrigin(NSPoint(x: windowStart.x+p.x-mouseStart.x, y: windowStart.y+p.y-mouseStart.y)) }
    }
    override func mouseUp(with event: NSEvent) {
        if moved { onMoved?() }
        else if event.modifierFlags.contains(.option) { onClear?() }
        else { onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event, self) }
}

@MainActor
final class FloatingBubbleController {
    let panel: PassivePanel
    let view: BubbleView
    init() {
        panel = PassivePanel(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureOverlayPanel(panel, level: 5)
        view = BubbleView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        panel.contentView = view
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("框译悬浮球。点击框选翻译，拖动移动，右键打开菜单。")
        view.toolTip = "点击：框选翻译；拖动：移动；右键：菜单；⌥点击：清除译文"
        let saved = UserDefaults.standard.string(forKey: "floatingBubbleOrigin")
        if let saved = saved { panel.setFrameOrigin(NSPointFromString(saved)) }
        else if let screen = NSScreen.main ?? NSScreen.screens.first {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX-88, y: screen.visibleFrame.midY))
        }
        view.onMoved = { [weak self] in self?.keepOnScreen(); self?.savePosition() }
        keepOnScreen()
    }
    func savePosition() { UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "floatingBubbleOrigin") }
    func keepOnScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: panel.frame.midX, y: panel.frame.midY)) }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: max(f.minX, min(panel.frame.minX, f.maxX-panel.frame.width)),
                                     y: max(f.minY, min(panel.frame.minY, f.maxY-panel.frame.height))))
    }
    func show() { keepOnScreen(); panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    func setSingleKeyActive(_ active: Bool) {
        view.singleKeyActive = active
        setMode(view.mode)
    }
    func setMode(_ mode: String, hint: String? = nil) {
        view.mode = mode
        view.toolTip = hint ?? (mode == "busy" ? "正在识别翻译；点击取消。可拖动悬浮球。" : mode == "pending" ? "截图尚未上传；点击发送并在原处显示译文。右键可预览。" : "点击：框选翻译；拖动：移动；右键：菜单；⌥点击：清除译文")
        if view.singleKeyActive { view.toolTip = (view.toolTip ?? "") + "；T：整屏翻译（右键可暂停 T 单键）" }
    }
}

struct ScreenSelection {
    let frame: NSRect            // Global AppKit points, not backing pixels.
    let screenFrame: NSRect
    let visibleFrame: NSRect
    let displayBounds: CGRect
    var captureRect: CGRect { CaptureGeometry.quartzRect(selection: frame, screenFrame: screenFrame, displayBounds: displayBounds) }
    @MainActor
    static func entireScreen(_ screen: NSScreen) -> ScreenSelection? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return ScreenSelection(frame: screen.frame, screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                               displayBounds: CGDisplayBounds(CGDirectDisplayID(number.uint32Value)))
    }
}

final class SelectionView: NSView {
    var onSelection: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: NSPoint?
    private var current = NSPoint.zero
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    private func clamped(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil)
        return NSPoint(x: min(bounds.maxX, max(0, p.x)), y: min(bounds.maxY, max(0, p.y)))
    }
    private var selection: NSRect {
        guard let start = start else { return .zero }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x-current.x), height: abs(start.y-current.y))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        start = clamped(event); current = start!; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { current = clamped(event); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        current = clamped(event)
        let rect = selection
        if rect.width >= 12 && rect.height >= 12 { onSelection?(rect) }
        else { start = nil; needsDisplay = true }
    }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onCancel?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if start != nil { dim.append(NSBezierPath(rect: selection)); dim.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.22).setFill(); dim.fill()
        if start != nil {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection); border.lineWidth = 1.5; border.stroke()
        }
        let text = "拖动框选文字 · 松开后在原处翻译 · Esc / 右键取消 · 每次选择一个屏幕"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let badge = NSRect(x: max(12, (bounds.width-size.width-32)/2), y: max(12, bounds.height-94), width: min(bounds.width-24, size.width+32), height: 40)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 12, yRadius: 12).fill()
        (text as NSString).draw(in: badge.insetBy(dx: 16, dy: 10), withAttributes: attrs)
    }
}

@MainActor
final class SelectionController {
    private var panels: [SelectionPanel] = []
    private var callback: ((ScreenSelection?) -> Void)?
    private var keyMonitor: Any?
    func start(completion: @escaping (ScreenSelection?) -> Void) {
        cancel(notify: false)
        callback = completion
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            configureOverlayPanel(panel, level: 20)
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            panel.contentView = view; panel.acceptsMouseMovedEvents = true
            view.onCancel = { [weak self] in self?.cancel() }
            view.onSelection = { [weak self] rect in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { self?.cancel(); return }
                let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                let value = ScreenSelection(frame: global, screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                            displayBounds: CGDisplayBounds(CGDirectDisplayID(number.uint32Value)))
                // Do not release a view while its mouseUp callback is executing.
                DispatchQueue.main.async { self?.finish(value) }
            }
            panels.append(panel)
            panel.orderFrontRegardless()
            if screen.frame.contains(mouse) { panel.makeKey(); panel.makeFirstResponder(view) }
        }
        if panels.isEmpty { finish(nil); return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) { self?.cancel(); return nil }
            return event
        }
        NSCursor.crosshair.set()
    }
    func cancel(notify: Bool = true) {
        let cb = callback; callback = nil
        teardown()
        if notify { cb?(nil) }
    }
    private func finish(_ selection: ScreenSelection?) {
        guard let cb = callback else { return }
        callback = nil; teardown(); cb(selection)
    }
    private func teardown() {
        if let keyMonitor = keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll(); NSCursor.arrow.set()
    }
}
