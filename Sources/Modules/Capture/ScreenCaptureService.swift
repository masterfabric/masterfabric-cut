// MasterFabric Cut — Capture module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import ScreenCaptureKit

/// Thin async wrapper over ScreenCaptureKit's one-shot screenshot API.
@MainActor
public final class ScreenCaptureService {
    public init() {}

    /// Exclude this app's own windows (overlays, Quick Access, …) from captures.
    public var excludeOwnApp = true
    /// Include the drop shadow when capturing a single window.
    public var includeWindowShadow = false
    public var showsCursor = false

    private func shareable() async throws -> SCShareableContent {
        guard await CapturePermissions.probeScreenRecording() else { throw CaptureError.permissionDenied }
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if ErrorPresenter.isPermission(error) { throw CaptureError.permissionDenied }
            throw error
        }
    }

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Windows eligible for window-mode picking, front-most first.
    public func listWindows() async throws -> [WindowInfo] {
        let content = try await shareable()
        let ownBundle = Bundle.main.bundleIdentifier
        let h = primaryHeight
        return content.windows.compactMap { w in
            guard w.windowLayer == 0, w.isOnScreen, w.frame.width > 40, w.frame.height > 40,
                  w.owningApplication?.bundleIdentifier != ownBundle else { return nil }
            let f = CGRect(x: w.frame.minX, y: h - w.frame.maxY, width: w.frame.width, height: w.frame.height)
            return WindowInfo(id: w.windowID, frame: f, title: w.title, appName: w.owningApplication?.applicationName)
        }
    }

    /// Capture a rectangle given in global AppKit screen coordinates (single display).
    public func captureRect(_ rect: CGRect) async throws -> CaptureResult {
        let screens = NSScreen.screens
        guard let screen = screens.max(by: { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }),
              screen.frame.intersects(rect) else { throw CaptureError.noDisplay }
        let clipped = rect.intersection(screen.frame)
        let content = try await shareable()
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw CaptureError.noDisplay }

        let ownApps = excludeOwnApp
            ? content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier } : []
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let scale = screen.backingScaleFactor

        let cfg = SCStreamConfiguration()
        // sourceRect is display-local, points, origin top-left.
        cfg.sourceRect = CGRect(x: clipped.minX - screen.frame.minX,
                                y: screen.frame.maxY - clipped.maxY,
                                width: clipped.width, height: clipped.height)
        cfg.width = max(1, Int((clipped.width * scale).rounded()))
        cfg.height = max(1, Int((clipped.height * scale).rounded()))
        cfg.showsCursor = showsCursor
        cfg.scalesToFit = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return CaptureResult(image: image, scale: scale, rect: clipped, mode: .area)
    }

    /// Capture the whole screen under the mouse (or a specific screen).
    public func captureFullscreen(screen: NSScreen = .underMouse) async throws -> CaptureResult {
        var r = try await captureRect(screen.frame)
        r = CaptureResult(image: r.image, scale: r.scale, rect: r.rect, mode: .fullscreen)
        return r
    }

    /// Capture one window (without desktop/other windows behind it).
    public func captureWindow(id: CGWindowID) async throws -> CaptureResult {
        let content = try await shareable()
        guard let win = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.windowNotFound }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let scale = CGFloat(filter.pointPixelScale)
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        cfg.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        cfg.showsCursor = showsCursor
        cfg.ignoreShadowsSingleWindow = !includeWindowShadow
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        let h = primaryHeight
        let f = CGRect(x: win.frame.minX, y: h - win.frame.maxY, width: win.frame.width, height: win.frame.height)
        return CaptureResult(image: image, scale: scale, rect: f, mode: .window)
    }
}

extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
