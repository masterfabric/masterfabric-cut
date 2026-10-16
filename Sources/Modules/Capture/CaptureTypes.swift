// MasterFabric Cut — Capture module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import ScreenCaptureKit
import CoreGraphics

/// What the user asked to capture.
public enum CaptureMode: String, CaseIterable, Codable, Sendable {
    case area, window, fullscreen, previousArea, scrolling, ocr
}

/// A finished screenshot handed to the rest of the app (Quick Access overlay, history, …).
public struct CaptureResult {
    public let image: CGImage
    /// Backing scale factor the image was captured at (pixels per point).
    public let scale: CGFloat
    /// Captured region in global AppKit screen coordinates, when known.
    public let rect: CGRect?
    public let mode: CaptureMode
    public let date: Date

    public init(image: CGImage, scale: CGFloat, rect: CGRect?, mode: CaptureMode, date: Date = Date()) {
        self.image = image; self.scale = scale; self.rect = rect; self.mode = mode; self.date = date
    }

    /// Size in points.
    public var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }

    public var nsImage: NSImage { NSImage(cgImage: image, size: pointSize) }
}

public enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case windowNotFound
    case cancelled
    case noPreviousArea
    case accessibilityRequired
    case scrollingFailed
    case ocrFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen Recording permission is required. Enable it in System Settings › Privacy & Security."
        case .noDisplay: return "No display found for the requested region."
        case .windowNotFound: return "The window is no longer available."
        case .cancelled: return "Capture cancelled."
        case .noPreviousArea: return "There is no previous capture area yet."
        case .accessibilityRequired: return "Accessibility permission is required for scrolling capture."
        case .scrollingFailed: return "Scrolling capture could not stitch any frames."
        case .ocrFailed(let m): return "Text recognition failed: \(m)"
        }
    }
}

/// An on-screen window that can be picked in window mode.
public struct WindowInfo {
    public let id: CGWindowID
    /// Frame in global AppKit coordinates (origin bottom-left of primary screen).
    public let frame: CGRect
    public let title: String?
    public let appName: String?
}

public enum CapturePermissions {
    public static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }
    private static var didRequest = false
    /// Triggers the system prompt at most once per launch (macOS ignores repeats and re-prompting is noisy).
    @discardableResult public static func requestScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if didRequest { return false }
        didRequest = true
        return CGRequestScreenCaptureAccess()
    }
    /// `CGPreflightScreenCaptureAccess` is cached per process and can lag behind System Settings, so also ask ScreenCaptureKit.
    public static func probeScreenRecording() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil
    }
    public static let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    public static var hasAccessibility: Bool { AXIsProcessTrusted() }
    public static func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}

extension NSScreen {
    public var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    /// Screen under the mouse cursor, falling back to main.
    public static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(p) } ?? main ?? screens[0]
    }
}
