// MasterFabric Cut — App shell
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import AVFoundation
import SwiftUI

/// First-launch welcome + permissions + tips window. Reopenable from the menu bar ("Welcome & Permissions").
@MainActor
final class OnboardingWindow {
    static let shared = OnboardingWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.contentView = NSHostingView(rootView: OnboardingView(onFinish: { [weak self] in
                AppSettings.shared.onboardingCompleted = true
                self?.window?.close()
            }))
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center(); window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Permissions model

enum PermissionState { case granted, notDetermined, denied }

enum PermissionKind: CaseIterable, Identifiable {
    case screen, camera, microphone, accessibility
    var id: Self { self }

    var title: String {
        switch self {
        case .screen: return "Screen Recording"
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        }
    }
    var detail: String {
        switch self {
        case .screen: return "Required to take screenshots and record your screen."
        case .camera: return "Optional. Shows your webcam bubble in Recording Studio."
        case .microphone: return "Optional. Adds voice narration to recordings."
        case .accessibility: return "Optional. Lets keystroke overlays work while recording."
        }
    }
    var symbol: String {
        switch self {
        case .screen: return "rectangle.dashed.badge.record"
        case .camera: return "camera.fill"
        case .microphone: return "mic.fill"
        case .accessibility: return "accessibility"
        }
    }
    var tint: Color {
        switch self {
        case .screen: return .blue
        case .camera: return .green
        case .microphone: return .orange
        case .accessibility: return .purple
        }
    }
    var required: Bool { self == .screen }
    private var permission: Permission {
        switch self {
        case .screen: return .screen
        case .camera: return .camera
        case .microphone: return .microphone
        case .accessibility: return .accessibility
        }
    }

    @MainActor var state: PermissionState {
        switch PermissionManager.shared.status(permission) {
        case .granted: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        }
    }

    /// Explicit Grant click: one system prompt, otherwise the denied sheet.
    @MainActor func request() { Task { _ = await PermissionManager.shared.ensure(permission) } }
    func openSettings() { NSWorkspace.shared.open(permission.settingsURL) }
}

// MARK: - View

private struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0
    @State private var forward = true
    @State private var states: [PermissionKind: PermissionState] = [:]
    @State private var asked: Set<PermissionKind> = []
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let tips: [Tip] = [
        Tip(symbol: "keyboard", tint: .blue, title: "Global shortcuts",
            body: "Capture from anywhere. Area ⌃⇧⌘4, Fullscreen ⌃⇧⌘3, Window ⌃⇧⌘6, Scrolling ⌃⇧⌘7, OCR ⌃⇧⌘8. Rebind them in Preferences › Shortcuts."),
        Tip(symbol: "rectangle.on.rectangle", tint: .indigo, title: "Quick Access",
            body: "Every capture slides in as a card. Copy, Save, Annotate or Pin it, or drag it straight into any app. It hides itself after a few seconds."),
        Tip(symbol: "pencil.tip.crop.circle", tint: .pink, title: "Annotate",
            body: "Add arrows, shapes, text, highlights, blur, step numbers and spotlights. Crop, add a background and padding, then copy or save."),
        Tip(symbol: "pin.fill", tint: .mint, title: "Pin to screen",
            body: "Keep a screenshot floating above your windows as a reference. Pin the last capture from the launcher or the clipboard image from the menu."),
        Tip(symbol: "video.badge.waveform", tint: .orange, title: "Recording Studio",
            body: "Record a window or display with a webcam bubble, microphone and system audio, then trim and export as MP4 or GIF."),
    ]
    private var pageCount: Int { 2 + tips.count }   // welcome, permissions, tips…

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Group {
                    switch page {
                    case 0: welcome
                    case 1: permissions
                    default: tipPage(tips[page - 2])
                    }
                }
                .id(page)
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .frame(width: 680, height: 560)
        .background(.regularMaterial)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        for k in PermissionKind.allCases { states[k] = k.state }
    }

    private func go(_ delta: Int) {
        forward = delta > 0
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { page = min(max(page + delta, 0), pageCount - 1) }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
            Text("Welcome to").font(.title3).foregroundStyle(.secondary).padding(.top, 8)
            Text("MasterFabric Cut").font(.system(size: 38, weight: .bold, design: .rounded))
            Text("Beautiful screenshots, annotations and screen recordings, right from your menu bar.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 400)
            Spacer()
            Text("Made by Gürkan Fikret Günak · masterfabric.co").font(.footnote).foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 40)
    }

    private var permissions: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Permissions").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Status updates automatically as you change things in System Settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(.top, 36)
            VStack(spacing: 8) {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(kind: kind, state: states[kind] ?? .notDetermined, asked: asked.contains(kind)) {
                        handle(kind)
                    }
                }
            }.padding(.horizontal, 36)
            Spacer()
        }
    }

    private func handle(_ kind: PermissionKind) {
        let s = states[kind] ?? .notDetermined
        // Screen Recording and Accessibility never report "denied", so only prompt once, then deep-link.
        if s == .notDetermined && !asked.contains(kind) { asked.insert(kind); kind.request() }
        else { kind.openSettings() }
        refresh()
    }

    private func tipPage(_ t: Tip) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: t.symbol).font(.system(size: 46, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 100, height: 100)
                .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(t.tint.gradient))
                .shadow(color: t.tint.opacity(0.35), radius: 20, y: 8)
            Text("Tips & Tricks").font(.caption.bold()).foregroundStyle(.secondary).textCase(.uppercase).padding(.top, 8)
            Text(t.title).font(.system(size: 28, weight: .bold, design: .rounded))
            Text(t.body).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Back") { go(-1) }.opacity(page == 0 ? 0 : 1).disabled(page == 0).help("Previous step")
            Spacer()
            HStack(spacing: 7) {
                ForEach(0..<pageCount, id: \.self) { i in
                    Capsule().fill(i == page ? Color.accentColor : Color.primary.opacity(0.2))
                        .frame(width: i == page ? 20 : 7, height: 7)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: page)
            Spacer()
            if page == pageCount - 1 {
                Button("Get Started", action: onFinish).keyboardShortcut(.defaultAction).controlSize(.large)
                    .help("Finish and start using MasterFabric Cut")
            } else {
                Button("Continue") { go(1) }.keyboardShortcut(.defaultAction).controlSize(.large)
                    .help(page == 1 ? "You can change permissions later from Welcome & Permissions" : "Next step")
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
        .background(.black.opacity(0.05))
    }
}

private struct Tip { let symbol: String; let tint: Color; let title: String; let body: String }

private struct PermissionRow: View {
    let kind: PermissionKind
    let state: PermissionState
    let asked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(kind.tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind.title).font(.system(size: 14, weight: .semibold))
                    if kind.required { Text("Required").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                }
                Text(kind.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            badge
            if state != .granted {
                Button(buttonTitle, action: action).help(helpText)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.opacity(hovering ? 0.75 : 0.55)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var buttonTitle: String {
        state == .denied || asked ? "Open System Settings" : "Grant"
    }
    private var helpText: String {
        buttonTitle == "Grant" ? "Ask macOS for \(kind.title) access" : "Open the \(kind.title) pane in System Settings"
    }

    private var badge: some View {
        let (text, color, icon): (String, Color, String) = {
            switch state {
            case .granted: return ("Granted", .green, "checkmark.circle.fill")
            case .denied: return ("Denied", .red, "xmark.circle.fill")
            case .notDetermined: return (kind.required ? "Needed" : "Not set", .orange, "exclamationmark.circle.fill")
            }
        }()
        return Label(text, systemImage: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.14), in: Capsule())
    }
}
