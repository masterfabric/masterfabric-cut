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
        if isPermission(error) { PermissionOnboarding.shared.show(onGranted: retry); return }
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = title
        a.informativeText = message(for: error)
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

/// Friendly "how to grant Screen Recording" window that polls for the grant and then retries the action.
@MainActor
final class PermissionOnboarding {
    static let shared = PermissionOnboarding()
    private var window: NSWindow?
    private var onGranted: (() -> Void)?

    func show(onGranted: (() -> Void)? = nil) {
        self.onGranted = onGranted
        if CapturePermissions.hasScreenRecording { finish(); return }
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PermissionOnboardingView(
                onGranted: { [weak self] in self?.finish() },
                onClose: { [weak self] in self?.window?.close() })))
            w.isReleasedWhenClosed = false
            w.title = "Allow Screen Recording"
            w.styleMask = [.titled, .closable]
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center(); window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        window?.orderOut(nil)
        let cb = onGranted; onGranted = nil
        DispatchQueue.main.async { cb?() }
    }
}

private struct PermissionOnboardingView: View {
    let onGranted: () -> Void
    let onClose: () -> Void
    @State private var granted = CapturePermissions.hasScreenRecording
    @State private var requested = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.accentColor.gradient).frame(width: 64, height: 64)
                Image(systemName: granted ? "checkmark" : "rectangle.dashed.badge.record")
                    .font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
            }
            Text("Allow Screen Recording").font(.title2.bold())
            Text("MasterFabric Cut needs permission to see your screen so it can take screenshots and record video. Nothing leaves your Mac.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Click **Open System Settings** below.")
                step(2, "Turn on **MasterFabric Cut** under Privacy & Security › Screen & System Audio Recording.")
                step(3, "If macOS asks, choose **Quit & Reopen**, then try your capture again.")
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 6) {
                Circle().fill(granted ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(granted ? "Access granted" : "Waiting for permission…").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Not Now", action: onClose)
                Spacer()
                Button("Restart App") { relaunch() }.help("macOS sometimes only applies the permission after a restart")
                Button(requested ? "Open System Settings Again" : "Open System Settings") {
                    if !requested { _ = CapturePermissions.requestScreenRecording() }
                    requested = true
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460)
        .onReceive(timer) { _ in
            if CapturePermissions.hasScreenRecording { granted = true; onGranted() }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.bold()).frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}
