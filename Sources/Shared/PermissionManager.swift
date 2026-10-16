// MasterFabric Cut — Shared
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import AVFoundation
import ApplicationServices

enum Permission: String, CaseIterable {
    case screen, camera, microphone, accessibility

    var title: String {
        switch self {
        case .screen: return "Screen Recording"
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        }
    }
    var settingsURL: URL {
        let pane: String
        switch self {
        case .screen: pane = "Privacy_ScreenCapture"
        case .camera: pane = "Privacy_Camera"
        case .microphone: pane = "Privacy_Microphone"
        case .accessibility: pane = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

enum PermissionStatus { case granted, notDetermined, denied }

/// Single source of truth for system permissions.
/// - `status(_:)` is always silent (never shows a system prompt).
/// - `request(_:)` / `ensure(_:)` prompt only when called from an explicit user action, at most once ever per permission (flag persisted in SQLite).
/// - Already-denied permissions show one friendly sheet (Open System Settings / Restart) instead of re-requesting.
@MainActor
final class PermissionManager {
    static let shared = PermissionManager()
    private var requestedThisLaunch: Set<Permission> = []
    private let store = PermissionStore.shared

    // MARK: Silent status

    func status(_ p: Permission) -> PermissionStatus {
        let s = liveStatus(p)
        store.saveStatus(p.rawValue, "\(s)")
        return s
    }

    private func liveStatus(_ p: Permission) -> PermissionStatus {
        switch p {
        case .screen:
            if CGPreflightScreenCaptureAccess() { return .granted }
            // The OS can't tell "never asked" from "denied"; remember that we asked once.
            return store.wasRequested(p.rawValue) ? .denied : .notDetermined
        case .camera: return av(.video)
        case .microphone: return av(.audio)
        case .accessibility: return AXIsProcessTrusted() ? .granted : (store.wasRequested(p.rawValue) ? .denied : .notDetermined)
        }
    }
    func isGranted(_ p: Permission) -> Bool { status(p) == .granted }

    private func av(_ t: AVMediaType) -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: t) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Never prompted yet (persisted) and not this launch. Camera/mic: the OS itself only prompts while undetermined.
    private func canPrompt(_ p: Permission) -> Bool {
        guard !requestedThisLaunch.contains(p) else { return false }
        return p == .camera || p == .microphone || !store.wasRequested(p.rawValue)
    }

    // MARK: Requesting (explicit user action only)

    /// Fires the system prompt if the permission was never requested and not yet asked this launch. Returns whether it is granted afterwards.
    @discardableResult
    func request(_ p: Permission) async -> Bool {
        if isGranted(p) { return true }
        guard status(p) == .notDetermined, canPrompt(p) else { return false }
        requestedThisLaunch.insert(p)
        store.markRequested(p.rawValue)
        switch p {
        case .screen: return CGRequestScreenCaptureAccess()
        case .camera: return await AVCaptureDevice.requestAccess(for: .video)
        case .microphone: return await AVCaptureDevice.requestAccess(for: .audio)
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return AXIsProcessTrusted()
        }
    }

    /// Call right before a feature needs `p`. Granted → true. Not yet asked → one system prompt. Denied → friendly sheet, false.
    func ensure(_ p: Permission, onGranted: (() -> Void)? = nil) async -> Bool {
        if isGranted(p) { return true }
        if status(p) == .notDetermined, canPrompt(p) {
            if await request(p) { return true }
            // The prompt is now on screen (screen/accessibility) or was just answered; don't stack a sheet on top of it.
            if p == .camera || p == .microphone, status(p) == .denied { showDenied(p, onGranted: onGranted) }
            return false
        }
        showDenied(p, onGranted: onGranted)
        return false
    }

    func showDenied(_ p: Permission, onGranted: (() -> Void)? = nil) {
        PermissionSheet.shared.show(p, onGranted: onGranted)
    }
}
