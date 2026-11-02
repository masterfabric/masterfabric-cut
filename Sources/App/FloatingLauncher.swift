// MasterFabric Cut — App shell
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import SwiftUI

/// The action palette (every capture/record/pin action as a grid) opened by clicking the floating button.
/// The button itself lives in `QuickHelpButton`; this type only owns the palette window.
@MainActor
final class FloatingLauncher {
    static let shared = FloatingLauncher()

    private var palette: NSPanel?
    private weak var anchor: NSWindow?
    private var monitors: [Any] = []

    var isPaletteOpen: Bool { palette != nil }

    /// Drops the button window from builds before 0.1.3 (no-op now; kept so callers stay simple).
    func refresh() {}

    // MARK: Palette

    func togglePalette(anchor: NSWindow) { palette == nil ? openPalette(anchor: anchor) : closePalette() }

    func openPalette(anchor bp: NSWindow) {
        guard palette == nil else { return }
        anchor = bp
        let host = NSHostingView(rootView: ActionPalette(dismiss: { [weak self] in self?.closePalette() },
                                                         run: { [weak self] a in self?.run(a) }))
        let size = host.fittingSize
        let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        palette = p
        movePalette(for: bp)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18
            p.animator().alphaValue = 1
        }

        let click = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.closePalette() }
        }
        let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.closePalette(); return nil }
            return e
        }
        monitors = [click, key].compactMap { $0 }
    }

    func movePalette() { if let bp = anchor { movePalette(for: bp) } }

    private func movePalette(for bp: NSWindow) {
        guard let p = palette else { return }
        let b = bp.frame.insetBy(dx: QuickHelpButton.inset, dy: QuickHelpButton.inset)
        let vf = (bp.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        // Open towards the screen: beside the button when it hugs a side edge, otherwise above/below it.
        var x: CGFloat, y: CGFloat
        if b.midX > vf.maxX - 120 || b.midX < vf.minX + 120 {
            x = b.midX > vf.midX ? b.minX - 10 - p.frame.width : b.maxX + 10
            y = b.midY - p.frame.height / 2
        } else {
            x = b.midX - p.frame.width / 2
            y = b.midY > vf.midY ? b.minY - 10 - p.frame.height : b.maxY + 10
        }
        x = min(max(x, vf.minX + 8), vf.maxX - p.frame.width - 8)
        y = min(max(y, vf.minY + 8), vf.maxY - p.frame.height - 8)
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func closePalette() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        palette?.orderOut(nil)
        palette = nil
    }

    private func run(_ a: LauncherAction) {
        closePalette()
        // Let the palette disappear before overlays/snapshots appear.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { a.perform() }
    }
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Actions

struct LauncherAction: Identifiable {
    let id: String
    let title: String, subtitle: String, symbol: String
    let tint: Color
    let shortcut: String?
    let perform: () -> Void

    @MainActor static var all: [LauncherAction] {
        func hint(_ a: CaptureAction) -> String? { HotkeyManager.shared.bindings[a]?.displayString }
        func cap(_ a: CaptureAction, _ t: String, _ s: String, _ sym: String, _ c: Color) -> LauncherAction {
            LauncherAction(id: a.rawValue, title: t, subtitle: s, symbol: sym, tint: c, shortcut: hint(a)) { AppCoordinator.shared.perform(a) }
        }
        return [
            cap(.captureArea, "Capture Area", "Drag to select a region", "rectangle.dashed", .blue),
            cap(.captureWindow, "Capture Window", "Click a window to grab it", "macwindow", .indigo),
            cap(.captureFullscreen, "Fullscreen", "The whole display", "display", .cyan),
            cap(.captureScrolling, "Scrolling", "Stitch a long page", "arrow.up.and.down.text.horizontal", .purple),
            cap(.captureText, "OCR Text", "Copy text from the screen", "text.viewfinder", .green),
            cap(.linkToQR, "Link to QR", "Present a link as a QR code", "qrcode", .teal),
            cap(.recordScreen, "Record Screen", "Save a region as MP4", "record.circle", .red),
            cap(.recordGIF, "Record GIF", "Save a region as a GIF", "gift", .pink),
            cap(.openStudio, "Recording Studio", "Webcam, mic and layouts", "video.badge.waveform", .orange),
            cap(.pinFile, "Pin Image / PDF", "Float a file on screen (or drop it here)", "pin.square.fill", .mint),
            LauncherAction(id: "pinClipboard", title: "Pin Clipboard", subtitle: "Float the copied image or PDF", symbol: "doc.on.clipboard", tint: .mint, shortcut: nil) {
                PinnedScreenshotController.shared.pinFromClipboard()
            },
            LauncherAction(id: "pinLast", title: "Pin Last", subtitle: "Float your latest capture", symbol: "pin.fill", tint: .mint, shortcut: nil) {
                PinnedScreenshotController.shared.pinLastCapture()
            },
            cap(.openHistory, "History", "Screenshots, recordings, text", "clock.arrow.circlepath", .brown),
        ]
    }
}

// MARK: - Views

private struct ActionPalette: View {
    let dismiss: () -> Void
    let run: (LauncherAction) -> Void
    private let actions = LauncherAction.all
    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                BrandIcon(size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text("MasterFabric Cut").font(.system(size: 13, weight: .semibold))
                    Text("What would you like to do?").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("esc").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
            }
            .padding(.horizontal, 6).padding(.top, 2)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(actions) { a in PaletteTile(action: a) { run(a) } }
            }
        }
        .padding(12)
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(1)
    }
}

private struct PaletteTile: View {
    let action: LauncherAction
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: action.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(action.tint.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(action.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    if let s = action.shortcut {
                        Text(s).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hovering ? Color.primary.opacity(0.1) : Color.primary.opacity(0.03)))
            .scaleEffect(hovering ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .help(action.shortcut.map { "\(action.title) (\($0))" } ?? action.title)
    }
}
