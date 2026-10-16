// MasterFabric Cut — App shell
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import SwiftUI

/// Borderless rounded panel anchored under the status item that hosts `MenuBarView`.
@MainActor
final class MenuBarPanelController: NSObject {
    private var panel: NSPanel?
    private var monitors: [Any] = []

    var isShown: Bool { panel?.isVisible == true }

    func toggle(relativeTo button: NSStatusBarButton, actions: MenuBarActions) {
        isShown ? close() : show(relativeTo: button, actions: actions)
    }

    func show(relativeTo button: NSStatusBarButton, actions: MenuBarActions) {
        close()
        var acts = actions
        acts.dismiss = { [weak self] in self?.close() }
        let host = NSHostingView(rootView: MenuBarView(actions: acts))
        host.setFrameSize(host.fittingSize)
        let size = host.fittingSize

        let p = MenuPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host

        if let bw = button.window {
            let b = bw.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = bw.screen ?? NSScreen.main
            var x = b.midX - size.width / 2
            if let vf = screen?.visibleFrame { x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8) }
            p.setFrameOrigin(NSPoint(x: x, y: b.minY - size.height - 6))
        }
        p.makeKeyAndOrderFront(nil)
        panel = p

        let click = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.close() }
        }
        let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.close(); return nil }
            return e
        }
        monitors = [click, key].compactMap { $0 }
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct MenuBarActions {
    var perform: (CaptureAction) -> Void = { _ in }
    var selfTimer: () -> Void = {}
    var pinClipboard: () -> Void = {}
    var preferences: () -> Void = {}
    var welcome: () -> Void = {}
    var about: () -> Void = {}
    var openItem: (CaptureHistoryItem) -> Void = { _ in }
    var dismiss: () -> Void = {}
}

// MARK: - View

struct MenuBarView: View {
    let actions: MenuBarActions
    @ObservedObject private var recorder = AppCoordinator.shared.recorder
    @ObservedObject private var history = CaptureHistoryStore.shared

    private func hint(_ a: CaptureAction) -> String? { HotkeyManager.shared.bindings[a]?.displayString }

    private func run(_ block: @escaping () -> Void) {
        actions.dismiss()
        // Let the panel disappear before overlays appear.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: block)
    }

    private func action(_ a: CaptureAction, _ title: String, _ subtitle: String, _ symbol: String, _ tint: Color) -> some View {
        MenuRow(title: title, subtitle: subtitle, symbol: symbol, tint: tint, shortcut: hint(a)) { run { actions.perform(a) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    if recorder.state.isActive { recordingControls }
                    section("Capture")
                    action(.captureArea, "Capture Area", "Drag to select any region", "rectangle.dashed", .blue)
                    action(.captureWindow, "Capture Window", "Click a window to grab it", "macwindow", .indigo)
                    action(.captureFullscreen, "Capture Fullscreen", "The whole display under the cursor", "display", .cyan)
                    action(.capturePreviousArea, "Previous Area", "Repeat the last selection", "arrow.counterclockwise", .teal)
                    section("Record")
                    action(.recordScreen, "Record Screen", "Save a region as MP4 video", "record.circle", .red)
                    action(.recordGIF, "Record GIF", "Save a region as an animated GIF", "gift", .pink)
                    action(.openStudio, "Recording Studio", "Window or display with webcam and audio", "video.badge.waveform", .orange)
                    section("Tools")
                    action(.captureScrolling, "Scrolling Capture", "Stitch a long page into one image", "arrow.up.and.down.text.horizontal", .purple)
                    action(.captureText, "Capture Text", "Copy text from the screen (OCR)", "text.viewfinder", .green)
                    MenuRow(title: "Self-Timer", subtitle: "Capture an area after a countdown", symbol: "timer", tint: .yellow, shortcut: nil) {
                        run { actions.selfTimer() }
                    }
                    action(.toggleDesktopIcons, "Toggle Desktop Icons", "Hide clutter before you capture", "eye.slash", .gray)
                    MenuRow(title: "Pin Clipboard Image", subtitle: "Float it above your other windows", symbol: "pin", tint: .mint, shortcut: nil) {
                        run { actions.pinClipboard() }
                    }
                    section("History")
                    recents
                    action(.openHistory, "Show All History", "Screenshots, recordings and text", "clock.arrow.circlepath", .brown)
                    section("Help")
                    MenuRow(title: "Welcome & Permissions", subtitle: "Permission status, tips and tricks", symbol: "hand.wave.fill", tint: .blue, shortcut: nil) {
                        run(actions.welcome)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .frame(maxHeight: 560)
            footer
        }
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(1)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.gradient).frame(width: 26, height: 26)
                Image(systemName: "scissors").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
            Text("MasterFabric Cut").font(.system(size: 14, weight: .semibold))
            Spacer()
            if recorder.state.isActive {
                Label("REC", systemImage: "circle.fill").font(.caption2.bold()).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 2)
    }

    private var recordingControls: some View {
        VStack(spacing: 2) {
            MenuRow(title: "Stop Recording", subtitle: "Finish and save", symbol: "stop.circle.fill", tint: .red, shortcut: nil) {
                run { AppCoordinator.shared.stopRecording() }
            }
            MenuRow(title: recorder.state == .paused ? "Resume Recording" : "Pause Recording", subtitle: "Temporarily halt capture",
                    symbol: recorder.state == .paused ? "play.circle.fill" : "pause.circle.fill", tint: .orange, shortcut: nil) {
                run { AppCoordinator.shared.togglePauseRecording() }
            }
        }
    }

    @ViewBuilder private var recents: some View {
        let items = Array(history.items.prefix(5))
        if items.isEmpty {
            Text("Nothing captured yet").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    RecentThumb(item: item) { run { actions.openItem(item) } }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            FooterButton(title: "Preferences…", symbol: "gearshape") { run(actions.preferences) }
            FooterButton(title: "About", symbol: "info.circle") { run(actions.about) }
            Spacer()
            FooterButton(title: "Quit", symbol: "power") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(.black.opacity(0.05))
    }
}

private struct MenuRow: View {
    let title: String, subtitle: String, symbol: String
    let tint: Color
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let shortcut {
                    Text(shortcut).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Color.primary.opacity(0.09) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(subtitle)
    }
}

private struct RecentThumb: View {
    let item: CaptureHistoryItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary)
                if let img = CaptureHistoryStore.shared.thumbnail(for: item) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: item.kind == .ocr ? "text.alignleft" : "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 58, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(hovering ? Color.accentColor : .white.opacity(0.15), lineWidth: hovering ? 2 : 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.date.formatted(date: .abbreviated, time: .shortened))
    }
}

private struct FooterButton: View {
    let title: String, symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.primary.opacity(0.09) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
