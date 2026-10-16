// MasterFabric Cut — Shared
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import ScreenCaptureKit
import SwiftUI

/// Turns thrown errors into friendly UI. Raw system errors are logged, never shown.
enum ErrorPresenter {
    static func isPermission(_ error: Error) -> Bool {
        if let e = error as? CaptureError, case .permissionDenied = e { return true }
        if let e = error as? RecordingError, case .screenPermissionDenied = e { return true }
        let ns = error as NSError
        return ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let e = error as? CaptureError, case .cancelled = e { return true }
        if let e = error as? RecordingError, case .cancelled = e { return true }
        return false
    }

    static func message(for error: Error) -> String {
        NSLog("MasterFabric Cut error: \(error)")
        if isPermission(error) { return "MasterFabric Cut needs Screen Recording access." }
        if let e = error as? CaptureError {
            switch e {
            case .ocrFailed: return "Text couldn't be recognized in that area. Try selecting a clearer region."
            default: return e.errorDescription ?? "Something went wrong. Please try again."
            }
        }
        if let e = error as? RecordingError {
            switch e {
            case .writerFailed, .exportFailed: return "The recording couldn't be saved. Check that your save location has free space and try again."
            default: return e.errorDescription ?? "Something went wrong. Please try again."
            }
        }
        return "Something went wrong. Please try again."
    }

    /// Permission problems open the onboarding sheet (and run `retry` once granted); everything else is a friendly alert.
    @MainActor static func present(_ error: Error, title: String, retry: (() -> Void)? = nil) {
        if isCancellation(error) { return }
        if isPermission(error) { PermissionManager.shared.showDenied(.screen, onGranted: retry); return }
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = title
        a.informativeText = message(for: error)
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

/// The one friendly sheet shown when a permission is already denied: Open System Settings + Restart app.
@MainActor
final class PermissionSheet {
    static let shared = PermissionSheet()
    private var window: NSWindow?
    private var onGranted: (() -> Void)?

    func show(_ p: Permission, onGranted: (() -> Void)? = nil) {
        self.onGranted = onGranted
        if PermissionManager.shared.isGranted(p) { finish(); return }
        window?.close()
        let w = NSWindow(contentViewController: NSHostingController(rootView: PermissionSheetView(
            permission: p,
            onGranted: { [weak self] in self?.finish() },
            onClose: { [weak self] in self?.window?.close() })))
        w.isReleasedWhenClosed = false
        w.title = "Allow \(p.title)"
        w.styleMask = [.titled, .closable]
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center(); w.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        window?.orderOut(nil)
        let cb = onGranted; onGranted = nil
        DispatchQueue.main.async { cb?() }
    }
}

private struct PermissionSheetView: View {
    let permission: Permission
    let onGranted: () -> Void
    let onClose: () -> Void
    @State private var granted = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.accentColor.gradient).frame(width: 64, height: 64)
                Image(systemName: granted ? "checkmark" : "lock.open")
                    .font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
            }
            Text("\(permission.title) is turned off").font(.title2.bold())
            Text("MasterFabric Cut needs \(permission.title) access for this. Nothing leaves your Mac.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Click **Open System Settings** and turn on **MasterFabric Cut**.")
                step(2, "Click **Restart App** (or **Quit & Reopen** if macOS asks), then try again.")
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                Button("Not Now", action: onClose)
                Spacer()
                Button("Restart App") { AppRelauncher.relaunch() }
                    .help("macOS applies a new Screen Recording grant only after the app is relaunched")
                Button("Open System Settings") { NSWorkspace.shared.open(permission.settingsURL) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460)
        .onReceive(timer) { _ in
            if PermissionManager.shared.isGranted(permission) { granted = true; onGranted() }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.bold()).frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum AppRelauncher {
    @MainActor static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
