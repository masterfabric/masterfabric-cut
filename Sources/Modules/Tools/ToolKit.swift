// MasterFabric Cut — Tools module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import SwiftUI

// MARK: - Shared UI for the general tools

/// Header used by every tool window (same look as the QR tool and the menu rows).
struct ToolHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// Small rounded status line ("Copied", errors) shown at the bottom of tool windows.
struct ToolStatus: View {
    let text: String
    var isError = false
    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .lineLimit(2)
    }
}

/// One regular window per tool id; calling `show` again brings the existing window to the front.
@MainActor
enum ToolWindows {
    private static var windows: [String: NSWindow] = [:]

    @discardableResult
    static func show<V: View>(_ id: String, title: String, resizable: Bool = false, @ViewBuilder content: () -> V) -> NSWindow {
        let window: NSWindow
        if let w = windows[id] {
            window = w
        } else {
            let w = NSWindow(contentViewController: NSHostingController(rootView: content()))
            w.isReleasedWhenClosed = false
            w.title = title
            var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            if resizable { mask.insert(.resizable) }
            w.styleMask = mask
            w.titlebarAppearsTransparent = true
            w.center()
            windows[id] = w
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    static func window(_ id: String) -> NSWindow? { windows[id] }
}

/// Text helpers shared by the tools.
enum ToolClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static var string: String? { NSPasteboard.general.string(forType: .string) }
}

/// Lets a SwiftUI area drag its (borderless) window around, like the floating button does.
struct WindowDragArea: ViewModifier {
    let window: () -> NSWindow?
    var onEnd: (() -> Void)? = nil
    @State private var start: (origin: NSPoint, mouse: NSPoint)?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { _ in
                    guard let w = window() else { return }
                    let m = NSEvent.mouseLocation
                    if start == nil { start = (w.frame.origin, m) }
                    guard let s = start else { return }
                    w.setFrameOrigin(NSPoint(x: s.origin.x + m.x - s.mouse.x, y: s.origin.y + m.y - s.mouse.y))
                }
                .onEnded { _ in start = nil; onEnd?() })
    }
}

extension View {
    func dragsWindow(_ window: @escaping () -> NSWindow?, onEnd: (() -> Void)? = nil) -> some View {
        modifier(WindowDragArea(window: window, onEnd: onEnd))
    }
}

// MARK: - Toast

/// A short HUD message near the bottom of the screen under the cursor ("Copied #1E90FF").
/// Ignores the mouse and never takes focus, so it works on top of every app and overlay.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", tint: Color = .green,
                     swatch: NSColor? = nil, duration: TimeInterval = 1.6) {
        let host = NSHostingView(rootView: ToastView(text: text, symbol: symbol, tint: tint, swatch: swatch.map { Color(nsColor: $0) }))
        let size = host.fittingSize
        let p = panel ?? makePanel()
        panel = p
        p.contentView = host
        let vf = NSScreen.underMouse.visibleFrame
        p.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.minY + 90, width: size.width, height: size.height), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.25; p.animator().alphaValue = 0 }) {
                if p.alphaValue < 0.05 { p.orderOut(nil) }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }
}

private struct ToastView: View {
    let text: String
    let symbol: String
    let tint: Color
    let swatch: Color?

    var body: some View {
        HStack(spacing: 8) {
            if let swatch {
                Circle().fill(swatch).frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
            } else {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            }
            Text(text).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Capsule().fill(Color.black.opacity(0.78)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .padding(2)
    }
}

#if DEBUG
/// Debug-only: writes a window's content to PNG without Screen Recording permission.
enum DebugSnapshot {
    @MainActor static func write(_ window: NSWindow?, to dir: String, name: String) {
        guard let v = window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
}
#endif
