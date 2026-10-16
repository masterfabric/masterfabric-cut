import AppKit

/// Full-screen-centered "3, 2, 1" countdown. The panel is hidden from screen capture and closed before recording starts.
@MainActor
public enum CountdownOverlay {
    /// Shows the countdown on `screen` (default: screen under the mouse). Returns false if cancelled.
    @discardableResult
    public static func run(seconds: Int, on screen: NSScreen? = nil) async -> Bool {
        guard seconds > 0 else { return true }
        let target = screen ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let target else { return true }

        let size: CGFloat = 180
        let panel = NSPanel(contentRect: CGRect(x: target.frame.midX - size / 2, y: target.frame.midY - size / 2,
                                                width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSView(frame: CGRect(origin: .zero, size: CGSize(width: size, height: size)))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        bg.layer?.cornerRadius = size / 2
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 96, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: (size - 116) / 2, width: size, height: 116)
        bg.addSubview(label)
        panel.contentView = bg
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        for n in stride(from: seconds, through: 1, by: -1) {
            label.stringValue = "\(n)"
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return false }
        }
        return true
    }
}
