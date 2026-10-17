import SwiftUI
import AppKit
import ScreenCaptureKit

/// On-screen furniture shown while recording: the focus dim around the recorded frame and the control pill.
/// Every window is click-through where possible, on all spaces, and hidden from capture
/// (`sharingType = .none` plus the explicit SCContentFilter exclusion done by the engine).
@MainActor
final class RecordingChrome {
    private var dimPanels: [NSPanel] = []
    private var pill: NSPanel?

    var windowIDs: [CGWindowID] { (dimPanels + [pill].compactMap { $0 }).map { CGWindowID($0.windowNumber) } }

    /// - Parameters:
    ///   - screen: the screen being recorded; the pill is placed on it.
    ///   - focus: the recorded frame in Cocoa screen coordinates. nil = no dim (full-screen recording).
    func show(manager: RecordingManager, screen: NSScreen, focus: CGRect?, dimOpacity: Double) {
        hide()
        if let focus {
            let p = Self.makePanel(frame: screen.frame, level: .statusBar, clickThrough: true)
            p.contentView = FocusDimView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                         hole: focus.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
                                         opacity: dimOpacity)
            p.orderFrontRegardless()
            dimPanels = [p]
        }
        let size = CGSize(width: RecordingControlsView.width, height: RecordingControlsView.height)
        let p = Self.makePanel(frame: CGRect(origin: Self.pillOrigin(on: screen, size: size), size: size),
                               level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1), clickThrough: false)
        p.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: RecordingControlsView(manager: manager))
        host.layer?.backgroundColor = .clear
        p.contentView = host
        p.orderFrontRegardless()
        pill = p
    }

    func hide() {
        dimPanels.forEach { $0.orderOut(nil) }
        dimPanels = []
        pill?.orderOut(nil)
        pill = nil
    }

    /// Centered directly below the camera housing on notched displays, otherwise top-center below the menu bar.
    static func pillOrigin(on screen: NSScreen, size: CGSize) -> CGPoint {
        let gap: CGFloat = 8
        let f = screen.frame
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 {
            let centerX: CGFloat
            if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
                centerX = (l.maxX + r.minX) / 2
            } else {
                centerX = f.midX
            }
            return CGPoint(x: centerX - size.width / 2, y: f.maxY - screen.safeAreaInsets.top - gap - size.height)
        }
        return CGPoint(x: f.midX - size.width / 2, y: screen.visibleFrame.maxY - gap - size.height)
    }

    private static func makePanel(frame: CGRect, level: NSWindow.Level, clickThrough: Bool) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = !clickThrough
        p.level = level
        p.ignoresMouseEvents = clickThrough
        p.sharingType = .none
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.setFrame(frame, display: false)
        return p
    }
}

/// Dark veil over the whole screen with a transparent cut-out (plus a hairline border) for the recorded frame.
private final class FocusDimView: NSView {
    let hole: CGRect
    let opacity: Double

    init(frame: CGRect, hole: CGRect, opacity: Double) {
        self.hole = hole; self.opacity = opacity
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        path.appendRect(hole)
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(opacity).setFill()
        path.fill()
        // Border just outside the frame so it never overlaps the recorded pixels.
        let border = NSBezierPath(rect: hole.insetBy(dx: -1, dy: -1))
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.55).setStroke()
        border.stroke()
    }
}

/// CleanShot-style pill: recording dot, mm:ss timer, Pause/Resume, Stop, Restart and Cancel.
public struct RecordingControlsView: View {
    static let width: CGFloat = 268
    static let height: CGFloat = 40

    @ObservedObject var manager: RecordingManager
    public init(manager: RecordingManager) { self.manager = manager }

    private var paused: Bool { manager.state == .paused }

    public var body: some View {
        HStack(spacing: 4) {
            Circle().fill(paused ? Color.orange : Color.red)
                .frame(width: 10, height: 10)
                .opacity(paused ? 1 : 0.95)
                .padding(.leading, 8).padding(.trailing, 2)
            Text(time(manager.elapsed))
                .font(.system(.body, design: .monospaced).weight(.medium))
                .foregroundStyle(.white)
                .frame(width: 52, alignment: .leading)
            Spacer(minLength: 0)
            PillButton(symbol: paused ? "play.fill" : "pause.fill", tint: .white,
                       tip: paused ? "Resume recording" : "Pause recording") { manager.togglePause() }
            PillButton(symbol: "stop.fill", tint: .red, tip: "Stop and open in Quick Access") {
                Task { try? await manager.stop() }
            }
            PillButton(symbol: "arrow.counterclockwise", tint: .white, tip: "Restart recording") { manager.restart() }
            PillButton(symbol: "xmark", tint: .white, tip: "Cancel and discard recording") { manager.cancel() }
        }
        .padding(.horizontal, 6)
        .frame(width: Self.width, height: Self.height)
        .background(Capsule().fill(Color.black.opacity(0.88)))
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func time(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

private struct PillButton: View {
    let symbol: String
    let tint: Color
    let tip: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(hover ? 0.18 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tip)
    }
}
