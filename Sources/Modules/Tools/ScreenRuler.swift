// MasterFabric Cut — Tools module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit

/// Full-screen measuring overlay: drag between two points to see the width, height and distance in
/// points and pixels (Retina aware). ⇧ keeps the line straight, C / ⌘C / ↩ copies, Esc exits.
/// Draws only vectors on a transparent window, so no Screen Recording permission is needed.
@MainActor
final class ScreenRuler {
    static let shared = ScreenRuler()
    private var windows: [RulerWindow] = []

    var isActive: Bool { !windows.isEmpty }

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard !isActive else { return }
        for screen in NSScreen.screens {
            let w = RulerWindow(screen: screen)
            w.ruler.onExit = { [weak self] in self?.stop() }
            windows.append(w)
            w.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
    }

    func stop() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}

private final class RulerWindow: NSWindow {
    let ruler: RulerView

    init(screen: NSScreen) {
        ruler = RulerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        acceptsMouseMovedEvents = true
        contentView = ruler
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

final class RulerView: NSView {
    var onExit: (() -> Void)?
    private var start: NSPoint?
    private var end: NSPoint?
    private var hover: NSPoint?
    private var copied = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    private var scale: CGFloat { window?.screen?.backingScaleFactor ?? 2 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited], owner: self))
    }

    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        hover = convert(event.locationInWindow, from: nil)
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let p = snap(convert(event.locationInWindow, from: nil))
        start = p; end = p; copied = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = start else { return }
        var p = snap(convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.shift) {
            if abs(p.x - s.x) > abs(p.y - s.y) { p.y = s.y } else { p.x = s.x }
        }
        end = p; hover = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { needsDisplay = true }

    override func rightMouseDown(with event: NSEvent) { onExit?() }

    /// Snaps to the device pixel grid so pixel values are whole numbers.
    private func snap(_ p: NSPoint) -> NSPoint {
        NSPoint(x: (p.x * scale).rounded() / scale, y: (p.y * scale).rounded() / scale)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: onExit?()                                  // Esc
        case 36, 76: copyMeasurement(); onExit?()           // Return
        case 8: copyMeasurement()                           // C / ⌘C
        case 123, 124, 125, 126: nudge(event)               // arrows move the end point by 1 px (⇧: 10 px)
        default: super.keyDown(with: event)
        }
    }

    private func nudge(_ e: NSEvent) {
        guard var p = end else { return }
        let step = (e.modifierFlags.contains(.shift) ? 10 : 1) / scale
        switch Int(e.keyCode) {
        case 123: p.x -= step
        case 124: p.x += step
        case 125: p.y -= step
        default: p.y += step
        }
        end = p; copied = false
        needsDisplay = true
    }

    private var measurement: (w: CGFloat, h: CGFloat, d: CGFloat)? {
        guard let s = start, let e = end else { return nil }
        let w = abs(e.x - s.x), h = abs(e.y - s.y)
        return (w, h, hypot(w, h))
    }

    private func fmt(_ v: CGFloat) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
    }

    func copyMeasurement() {
        guard let m = measurement else { return }
        let text: String
        if m.w == 0 || m.h == 0 {
            text = "\(fmt(m.d * scale)) px (\(fmt(m.d)) pt)"
        } else {
            text = "\(fmt(m.w * scale)) × \(fmt(m.h * scale)) px (\(fmt(m.w)) × \(fmt(m.h)) pt)"
        }
        ToolClipboard.copy(text)
        copied = true
        needsDisplay = true
        Toast.show("Copied \(text)", symbol: "ruler.fill", tint: .orange)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // A faint tint keeps the window clickable everywhere and shows the ruler is active.
        NSColor.black.withAlphaComponent(0.06).setFill()
        bounds.fill()

        let accent = NSColor.systemOrange
        if let h = hover, start == nil || end == start {
            let guide = NSBezierPath()
            guide.move(to: NSPoint(x: 0, y: h.y)); guide.line(to: NSPoint(x: bounds.maxX, y: h.y))
            guide.move(to: NSPoint(x: h.x, y: 0)); guide.line(to: NSPoint(x: h.x, y: bounds.maxY))
            guide.lineWidth = 1
            accent.withAlphaComponent(0.55).setStroke()
            guide.stroke()
            label("\(fmt(h.x)), \(fmt(bounds.height - h.y)) pt", at: NSPoint(x: h.x + 14, y: h.y - 30), anchorLeft: true)
        }

        if let s = start, let e = end, s != e, let m = measurement {
            let rect = NSRect(x: min(s.x, e.x), y: min(s.y, e.y), width: m.w, height: m.h)
            if m.w > 0, m.h > 0 {
                let box = NSBezierPath(rect: rect)
                box.lineWidth = 1
                box.setLineDash([5, 4], count: 2, phase: 0)
                accent.withAlphaComponent(0.8).setStroke()
                box.stroke()
                accent.withAlphaComponent(0.08).setFill()
                rect.fill(using: .sourceOver)
            }
            let line = NSBezierPath()
            line.move(to: s); line.line(to: e)
            line.lineWidth = 2
            accent.setStroke()
            line.stroke()
            for p in [s, e] {
                let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                NSColor.white.setFill(); dot.fill()
                accent.setStroke(); dot.lineWidth = 2; dot.stroke()
            }
            var lines: [String] = []
            if m.w > 0, m.h > 0 {
                lines.append("\(fmt(m.w)) × \(fmt(m.h)) pt")
                lines.append("\(fmt(m.w * scale)) × \(fmt(m.h * scale)) px")
                lines.append("↗ \(fmt(m.d)) pt · \(fmt(m.d * scale)) px")
            } else {
                lines.append("\(fmt(m.d)) pt")
                lines.append("\(fmt(m.d * scale)) px")
            }
            if copied { lines.append("Copied ✓") }
            label(lines.joined(separator: "\n"), at: NSPoint(x: rect.midX, y: rect.midY), anchorLeft: false, big: true)
        }

        hint()
    }

    private func label(_ text: String, at p: NSPoint, anchorLeft: Bool, big: Bool = false) {
        let para = NSMutableParagraphStyle()
        para.alignment = anchorLeft ? .left : .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: big ? 13 : 11, weight: .semibold),
            .foregroundColor: NSColor.white, .paragraphStyle: para,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.boundingRect(with: NSSize(width: 400, height: 200), options: [.usesLineFragmentOrigin]).size
        var r = NSRect(x: anchorLeft ? p.x : p.x - size.width / 2 - 10, y: p.y - size.height / 2 - 6,
                       width: size.width + 20, height: size.height + 12)
        r.origin.x = min(max(r.minX, 6), bounds.maxX - r.width - 6)
        r.origin.y = min(max(r.minY, 6), bounds.maxY - r.height - 6)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        str.draw(with: r.insetBy(dx: 10, dy: 6), options: [.usesLineFragmentOrigin])
    }

    private func hint() {
        let text = "Drag to measure  ·  ⇧ straight  ·  arrows nudge  ·  C copy  ·  ↩ copy & close  ·  Esc exit"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let r = NSRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - size.height - 70, width: size.width + 28, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        str.draw(at: NSPoint(x: r.minX + 14, y: r.minY + 6))
    }
}
