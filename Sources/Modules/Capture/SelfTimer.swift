// MasterFabric Cut — Capture module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit

/// Floating countdown HUD used by the self-timer.
@MainActor
public enum SelfTimer {
    /// Shows a big countdown on the screen under the mouse. Returns false if cancelled (Task cancelled).
    public static func countdown(seconds: Int) async -> Bool {
        guard seconds > 0 else { return true }
        let screen = NSScreen.underMouse
        let side: CGFloat = 160
        let panel = NSPanel(contentRect: NSRect(x: screen.frame.midX - side / 2, y: screen.frame.midY - side / 2, width: side, height: side),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .screenSaver
        panel.ignoresMouseEvents = true; panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        bg.layer?.cornerRadius = 28
        let text = NSTextField(labelWithString: "\(seconds)")
        text.font = .monospacedDigitSystemFont(ofSize: 88, weight: .semibold)
        text.textColor = .white; text.alignment = .center
        text.frame = NSRect(x: 0, y: (side - 104) / 2, width: side, height: 104)
        bg.addSubview(text)
        panel.contentView = bg
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        for remaining in stride(from: seconds, through: 1, by: -1) {
            text.stringValue = "\(remaining)"
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return false }
        }
        panel.orderOut(nil)
        try? await Task.sleep(nanoseconds: 150_000_000) // let the HUD leave the compositor
        return !Task.isCancelled
    }
}
