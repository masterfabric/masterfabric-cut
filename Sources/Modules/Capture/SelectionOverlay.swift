// MasterFabric Cut — Capture module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit

public enum SelectionOutcome {
    case rect(CGRect)                 // global AppKit coordinates
    case window(CGWindowID, CGRect)
}

/// Full-screen crosshair overlay (one borderless window per screen) with magnifier and live dimensions.
/// Space toggles between area and window picking; Esc cancels.
@MainActor
final class SelectionOverlayController {
    enum Mode { case area, window }

    private var windows: [OverlayWindow] = []
    private var views: [SelectionView] = []
    private var continuation: CheckedContinuation<SelectionOutcome?, Never>?

    /// - Parameters:
    ///   - snapshots: per-display frozen pixels used by the magnifier.
    ///   - previous: optional rect to preselect (not used for drawing, reserved).
    func run(mode: Mode, windowCandidates: [WindowInfo], snapshots: [CGDirectDisplayID: CGImage]) async -> SelectionOutcome? {
        await withCheckedContinuation { (c: CheckedContinuation<SelectionOutcome?, Never>) in
            continuation = c
            for screen in NSScreen.screens {
                let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
                w.isOpaque = false
                w.backgroundColor = .clear
                w.hasShadow = false
                w.level = .screenSaver
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                let v = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
                v.screen_ = screen
                v.mode = mode
                v.candidates = windowCandidates
                v.snapshot = snapshots[screen.displayID]
                v.onFinish = { [weak self] in self?.finish($0) }
                v.onToggle = { [weak self] in self?.toggle() }
                w.contentView = v
                w.setFrame(screen.frame, display: true)
                w.orderFrontRegardless()
                windows.append(w); views.append(v)
            }
            NSApp.activate(ignoringOtherApps: true)
            let target = windows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? windows.first
            target?.makeKeyAndOrderFront(nil)
            if let v = target?.contentView { target?.makeFirstResponder(v) }
            views.forEach { $0.refreshMouse() }
        }
    }

    private func toggle() {
        for v in views { v.mode = (v.mode == .area) ? .window : .area; v.needsDisplay = true }
    }

    private func finish(_ outcome: SelectionOutcome?) {
        guard let c = continuation else { return }
        continuation = nil
        // finish() runs inside the view's mouse/key handler: never tear the window down synchronously.
        // Keep the windows alive past the current event, then release them.
        let dying = windows
        views.forEach { $0.onFinish = nil; $0.onToggle = nil }
        windows.removeAll(); views.removeAll()
        dying.forEach { $0.orderOut(nil) }
        DispatchQueue.main.async {
            dying.forEach { $0.contentView = nil; $0.close() }
        }
        c.resume(returning: outcome)
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        isReleasedWhenClosed = false // ARC owns the window; the default would over-release it
    }
}

private final class SelectionView: NSView {
    var screen_: NSScreen!
    var mode: SelectionOverlayController.Mode = .area
    var candidates: [WindowInfo] = []
    var snapshot: CGImage?
    var onFinish: ((SelectionOutcome?) -> Void)?
    var onToggle: (() -> Void)?

    private var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var dragRect: CGRect?
    private var hover: WindowInfo?

    private let magSize: CGFloat = 140
    private let magZoom: CGFloat = 10

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    func refreshMouse() {
        guard let w = window else { return }
        let p = NSEvent.mouseLocation
        if w.frame.contains(p) { mouse = CGPoint(x: p.x - w.frame.minX, y: p.y - w.frame.minY); updateHover() }
        needsDisplay = true
    }

    private func local(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    private var origin: CGPoint { window?.frame.origin ?? .zero }
    private func toGlobal(_ r: CGRect) -> CGRect { r.offsetBy(dx: origin.x, dy: origin.y) }

    private func updateHover() {
        guard mode == .window, let m = mouse else { hover = nil; return }
        let g = CGPoint(x: m.x + origin.x, y: m.y + origin.y)
        hover = candidates.first { $0.frame.contains(g) }
    }

    override func mouseMoved(with e: NSEvent) { mouse = local(e); updateHover(); needsDisplay = true }
    override func mouseExited(with e: NSEvent) { mouse = nil; needsDisplay = true }

    override func mouseDown(with e: NSEvent) {
        mouse = local(e)
        if mode == .area { dragStart = mouse; dragRect = nil }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        let p = local(e); mouse = p
        if mode == .area, let s = dragStart {
            dragRect = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        switch mode {
        case .area:
            defer { dragStart = nil }
            guard let r = dragRect, r.width >= 3, r.height >= 3 else { dragRect = nil; needsDisplay = true; return }
            onFinish?(.rect(toGlobal(r.integral)))
        case .window:
            updateHover()
            if let h = hover { onFinish?(.window(h.id, h.frame)) }
        }
    }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: onFinish?(nil)                       // esc
        case 49: onToggle?()                          // space
        default: super.keyDown(with: e)
        }
    }
    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }

    // MARK: Drawing

    private var highlight: CGRect? {
        switch mode {
        case .area: return dragRect
        case .window: return hover.map { $0.frame.offsetBy(dx: -origin.x, dy: -origin.y) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dim = NSBezierPath(rect: bounds)
        if let h = highlight { dim.append(NSBezierPath(rect: h)); dim.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()

        if let h = highlight {
            if mode == .window { NSColor.systemBlue.withAlphaComponent(0.18).setFill(); NSBezierPath(rect: h).fill() }
            let border = NSBezierPath(rect: h.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = mode == .window ? 3 : 1
            (mode == .window ? NSColor.systemBlue : NSColor.white).setStroke()
            border.stroke()
            label("\(Int(h.width)) × \(Int(h.height))", near: h)
        }

        guard mode == .area, let m = mouse else { return }
        // Crosshair
        ctx.saveGState()
        ctx.setLineWidth(1)
        for (color, off) in [(NSColor.black.withAlphaComponent(0.5), CGFloat(1)), (NSColor.white.withAlphaComponent(0.9), CGFloat(0))] {
            ctx.setStrokeColor(color.cgColor)
            ctx.move(to: CGPoint(x: 0, y: m.y.rounded() + 0.5 + off)); ctx.addLine(to: CGPoint(x: bounds.width, y: m.y.rounded() + 0.5 + off))
            ctx.move(to: CGPoint(x: m.x.rounded() + 0.5 + off, y: 0)); ctx.addLine(to: CGPoint(x: m.x.rounded() + 0.5 + off, y: bounds.height))
            ctx.strokePath()
        }
        ctx.restoreGState()

        if dragRect == nil {
            label("\(Int(m.x + origin.x)), \(Int(screen_.frame.maxY - (m.y + origin.y)))",
                  at: CGPoint(x: m.x + 14, y: m.y - 30))
        }
        drawMagnifier(at: m, ctx: ctx)
    }

    private func drawMagnifier(at m: CGPoint, ctx: CGContext) {
        guard let snap = snapshot else { return }
        var box = CGRect(x: m.x + 24, y: m.y - 24 - magSize, width: magSize, height: magSize)
        if box.maxX > bounds.maxX - 4 { box.origin.x = m.x - 24 - magSize }
        if box.minY < 4 { box.origin.y = m.y + 24 }
        let scale = CGFloat(snap.width) / bounds.width
        let span = magSize / magZoom
        let srcPts = CGRect(x: m.x - span / 2, y: bounds.height - m.y - span / 2, width: span, height: span)
        let src = CGRect(x: srcPts.minX * scale, y: srcPts.minY * scale, width: srcPts.width * scale, height: srcPts.height * scale).integral
        let imgBounds = CGRect(x: 0, y: 0, width: snap.width, height: snap.height)

        ctx.saveGState()
        let clip = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12)
        clip.addClip()
        NSColor.black.setFill(); clip.fill()
        if imgBounds.contains(src), let crop = snap.cropping(to: src) {
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: box)
        }
        // center pixel marker
        let px = magZoom
        let center = CGRect(x: box.midX - px / 2, y: box.midY - px / 2, width: px, height: px)
        ctx.setStrokeColor(NSColor.systemRed.cgColor); ctx.setLineWidth(1.5); ctx.stroke(center)
        ctx.restoreGState()

        NSColor.white.setStroke()
        let ring = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12); ring.lineWidth = 2; ring.stroke()
        if let r = dragRect { label("\(Int(r.width)) × \(Int(r.height))", at: CGPoint(x: box.minX, y: box.minY - 24)) }
    }

    private func label(_ s: String, near r: CGRect) {
        let attrs = labelAttrs
        let size = (s as NSString).size(withAttributes: attrs)
        var p = CGPoint(x: r.maxX - size.width - 10, y: r.minY - size.height - 12)
        if p.y < 4 { p.y = r.maxY + 6 }
        if p.x < 4 { p.x = 4 }
        label(s, at: p)
    }

    private var labelAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
    }

    private func label(_ s: String, at p: CGPoint) {
        let size = (s as NSString).size(withAttributes: labelAttrs)
        let pill = CGRect(x: p.x, y: p.y, width: size.width + 12, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        (s as NSString).draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: labelAttrs)
    }
}
