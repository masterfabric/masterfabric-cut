import AppKit
import QuartzCore

/// Click rings and keystroke HUD drawn on click-through, full-screen panels so they are part of the recording.
@MainActor
public final class InputOverlayController {
    public static let shared = InputOverlayController()

    private var panels: [NSScreen: OverlayPanel] = [:]
    private var monitors: [Any] = []
    private var showClicks = false
    private var showKeys = false
    private var keyBuffer = ""
    private var hideWork: DispatchWorkItem?

    /// Window numbers of the overlay panels (pass to the recorder so they are captured).
    public var windowIDs: [CGWindowID] { panels.values.map { CGWindowID($0.windowNumber) } }
    public var isRunning: Bool { !panels.isEmpty }

    /// Keystroke capture needs Input Monitoring permission for events in other apps.
    public static var hasInputMonitoringAccess: Bool { CGPreflightListenEventAccess() }
    public static func requestInputMonitoringAccess() { _ = CGRequestListenEventAccess() }

    public func start(showClicks: Bool, showKeystrokes: Bool) {
        stop()
        guard showClicks || showKeystrokes else { return }
        self.showClicks = showClicks
        self.showKeys = showKeystrokes
        for screen in NSScreen.screens {
            let p = OverlayPanel(screen: screen)
            p.orderFrontRegardless()
            panels[screen] = p
        }
        if showClicks {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
                let loc = NSEvent.mouseLocation
                let right = e.type == .rightMouseDown
                Task { @MainActor in self?.ring(at: loc, right: right) }
            }) { monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
                let loc = NSEvent.mouseLocation
                let right = e.type == .rightMouseDown
                Task { @MainActor in self?.ring(at: loc, right: right) }
                return e
            }) { monitors.append(m) }
        }
        if showKeystrokes {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
                let text = Self.describe(e)
                let plain = e.modifierFlags.intersection([.command, .control, .option]).isEmpty
                Task { @MainActor in self?.key(text, plain: plain) }
            }) { monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
                let text = Self.describe(e)
                let plain = e.modifierFlags.intersection([.command, .control, .option]).isEmpty
                Task { @MainActor in self?.key(text, plain: plain) }
                return e
            }) { monitors.append(m) }
        }
    }

    public func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        hideWork?.cancel()
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        keyBuffer = ""
    }

    // MARK: Drawing

    private func panel(containing p: NSPoint) -> OverlayPanel? {
        for (s, panel) in panels where s.frame.contains(p) { return panel }
        return panels.values.first
    }

    private func ring(at global: NSPoint, right: Bool) {
        guard let panel = panel(containing: global) else { return }
        panel.overlay.addRing(at: panel.localPoint(fromScreen: global), right: right)
    }

    private func key(_ text: String, plain: Bool) {
        guard let panel = panel(containing: NSEvent.mouseLocation) else { return }
        if plain && text.count == 1 {
            keyBuffer += text
            if keyBuffer.count > 24 { keyBuffer.removeFirst(keyBuffer.count - 24) }
        } else {
            keyBuffer = text
        }
        for p in panels.values where p !== panel { p.overlay.setKeys(nil) }
        panel.overlay.setKeys(keyBuffer)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.keyBuffer = ""
            self?.panels.values.forEach { $0.overlay.setKeys(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    nonisolated static func describe(_ e: NSEvent) -> String {
        var s = ""
        let f = e.modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        let special: [UInt16: String] = [36: "⏎", 76: "⏎", 48: "⇥", 49: "␣", 51: "⌫", 117: "⌦", 53: "⎋",
                                         123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟"]
        if let sp = special[e.keyCode] { return s + sp }
        let ch = (e.charactersIgnoringModifiers ?? "").uppercased()
        if f.intersection([.command, .control, .option]).isEmpty {
            // Preserve typed case for plain typing.
            return e.characters ?? ch
        }
        return s + ch
    }
}

private final class OverlayPanel: NSPanel {
    let overlay: OverlayView

    init(screen: NSScreen) {
        overlay = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = overlay
        setFrame(screen.frame, display: false)
    }

    func localPoint(fromScreen p: NSPoint) -> NSPoint {
        NSPoint(x: p.x - frame.minX, y: p.y - frame.minY)
    }
}

private final class OverlayView: NSView {
    private let pill = NSView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        pill.layer?.cornerRadius = 14
        pill.isHidden = true
        label.font = .systemFont(ofSize: 28, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        pill.addSubview(label)
        addSubview(pill)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    func addRing(at p: NSPoint, right: Bool) {
        guard let root = layer else { return }
        let size: CGFloat = 46
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        let color = right ? NSColor.systemOrange : NSColor.systemYellow
        ring.fillColor = color.withAlphaComponent(0.35).cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 3
        root.addSublayer(ring)

        let group = CAAnimationGroup()
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.6; scale.toValue = 1.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        group.animations = [scale, fade]
        group.duration = 0.55
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ring.add(group, forKey: "click")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ring.removeFromSuperlayer() }
    }

    func setKeys(_ text: String?) {
        guard let text, !text.isEmpty else { pill.isHidden = true; return }
        label.stringValue = text
        label.sizeToFit()
        let w = label.frame.width + 40, h = label.frame.height + 20
        pill.frame = CGRect(x: (bounds.width - w) / 2, y: 90, width: w, height: h)
        label.frame.origin = CGPoint(x: 20, y: 10)
        pill.isHidden = false
    }
}
