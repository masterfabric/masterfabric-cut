// MasterFabric Cut — App shell
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import SwiftUI

/// Always-on-top draggable button (default: bottom-right) that opens an action palette.
@MainActor
final class FloatingLauncher {
    static let shared = FloatingLauncher()

    private static let buttonSize: CGFloat = 54
    private var buttonPanel: NSPanel?
    private var palette: NSPanel?
    private var monitors: [Any] = []

    func refresh() {
        if AppSettings.shared.showLauncher { showButton() } else { hideButton() }
    }

    // MARK: Button

    private func showButton() {
        if buttonPanel == nil {
            let size = Self.buttonSize
            let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: size + 16, height: size + 16),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isReleasedWhenClosed = false
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView: LauncherButton(
                size: size,
                onMove: { [weak self] origin in self?.buttonPanel?.setFrameOrigin(origin); self?.movePalette() },
                onMoveEnd: { [weak self] in AppSettings.shared.launcherOrigin = self?.buttonPanel?.frame.origin },
                onClick: { [weak self] in self?.togglePalette() }))
            p.setFrameOrigin(initialOrigin(for: p.frame.size))
            buttonPanel = p
        }
        buttonPanel?.orderFrontRegardless()
    }

    private func hideButton() {
        closePalette()
        buttonPanel?.orderOut(nil)
        buttonPanel = nil
    }

    private func initialOrigin(for size: NSSize) -> NSPoint {
        if let saved = AppSettings.shared.launcherOrigin,
           NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -4, dy: -4).contains(NSPoint(x: saved.x + size.width / 2, y: saved.y + size.height / 2)) }) {
            return saved
        }
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vf.maxX - size.width - 12, y: vf.minY + 12)
    }

    // MARK: Palette

    private func togglePalette() { palette == nil ? openPalette() : closePalette() }

    private func openPalette() {
        guard let bp = buttonPanel else { return }
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

    private func movePalette() { if let bp = buttonPanel { movePalette(for: bp) } }

    private func movePalette(for bp: NSPanel) {
        guard let p = palette else { return }
        let b = bp.frame.insetBy(dx: 8, dy: 8)
        let vf = (bp.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = b.maxX - p.frame.width
        x = min(max(x, vf.minX + 8), vf.maxX - p.frame.width - 8)
        var y = b.maxY + 10
        if y + p.frame.height > vf.maxY { y = max(b.minY - 10 - p.frame.height, vf.minY + 8) }
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func closePalette() {
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
            cap(.recordScreen, "Record Screen", "Save a region as MP4", "record.circle", .red),
            cap(.recordGIF, "Record GIF", "Save a region as a GIF", "gift", .pink),
            cap(.openStudio, "Recording Studio", "Webcam, mic and layouts", "video.badge.waveform", .orange),
            LauncherAction(id: "pinLast", title: "Pin Last", subtitle: "Float your latest capture", symbol: "pin.fill", tint: .mint, shortcut: nil) {
                let store = CaptureHistoryStore.shared
                if let item = store.items.first(where: { $0.kind == .screenshot }),
                   let url = item.fileURL, let img = NSImage(contentsOf: url) {
                    AnnotateModule.shared.pin(image: img)
                } else {
                    let a = NSAlert(); a.messageText = "Nothing to pin yet"
                    a.informativeText = "Take a screenshot first, then pin it from here."
                    NSApp.activate(ignoringOtherApps: true); a.runModal()
                }
            },
            cap(.openHistory, "History", "Screenshots, recordings, text", "clock.arrow.circlepath", .brown),
        ]
    }
}

// MARK: - Views

private struct LauncherButton: View {
    let size: CGFloat
    let onMove: (NSPoint) -> Void
    let onMoveEnd: () -> Void
    let onClick: () -> Void
    @State private var hovering = false
    @State private var pressing = false
    @State private var startOrigin: NSPoint?
    @State private var startMouse: NSPoint = .zero
    @State private var moved = false

    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial)
            Circle().fill(Color.accentColor.gradient).padding(4)
            Image(systemName: "scissors").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
        .shadow(color: .black.opacity(hovering ? 0.35 : 0.25), radius: hovering ? 14 : 9, y: 4)
        .scaleEffect(pressing ? 0.92 : (hovering ? 1.08 : 1))
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Circle())
        .onHover { hovering = $0 }
        .help("MasterFabric Cut — click for actions, drag to move")
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in
                    let mouse = NSEvent.mouseLocation
                    if startOrigin == nil {
                        startOrigin = NSApp.windows.first(where: { $0.contentView is NSHostingView<LauncherButton> })?.frame.origin
                        startMouse = mouse; pressing = true
                    }
                    guard let o = startOrigin else { return }
                    let dx = mouse.x - startMouse.x, dy = mouse.y - startMouse.y
                    if moved || hypot(dx, dy) > 4 {
                        moved = true; pressing = false
                        onMove(NSPoint(x: o.x + dx, y: o.y + dy))
                    }
                }
                .onEnded { _ in
                    pressing = false
                    if moved { onMoveEnd() } else { onClick() }
                    startOrigin = nil; moved = false
                }
        )
    }
}

private struct ActionPalette: View {
    let dismiss: () -> Void
    let run: (LauncherAction) -> Void
    private let actions = LauncherAction.all
    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "scissors").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.gradient))
                Text("What would you like to do?").font(.system(size: 13, weight: .semibold))
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
