// MasterFabric Cut — Capture module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit

/// Public façade of the Capture module. The app shell owns one instance, wires the callbacks and
/// calls `perform(_:)` from menu items and hotkeys.
@MainActor
public final class CaptureCoordinator {
    public let service = ScreenCaptureService()

    /// Delivered for every finished screenshot (area/window/fullscreen/scrolling).
    public var onCapture: ((CaptureResult) -> Void)?
    /// Delivered after OCR with the recognized text (already copied to the pasteboard when `copyOCRToPasteboard`).
    public var onText: ((String, CaptureResult) -> Void)?
    /// Non-cancellation errors, for the shell to present.
    public var onError: ((Error) -> Void)?

    /// Self-timer in seconds; 0 = off. Applies to every capture type.
    public var selfTimerSeconds = 0
    public var hideDesktopIconsDuringCapture = false
    public var copyOCRToPasteboard = true

    private let previousAreaKey = "com.masterfabric.cut.previousArea"
    private let overlay = SelectionOverlayController()
    private var scrolling: ScrollingCapture?
    private var busy = false
    /// Most recent action, so the shell can retry it after Screen Recording is granted.
    public private(set) var lastAction: CaptureAction?

    public init() {}

    public var previousArea: CGRect? {
        get { AppStateStore.shared.string(forKey: previousAreaKey).map(NSRectFromString).flatMap { $0.isEmpty ? nil : $0 } }
        set { AppStateStore.shared.set(newValue.map(NSStringFromRect), forKey: previousAreaKey) }
    }

    /// Entry point for menu items and hotkeys. Non-capture actions are ignored (handled by the shell).
    public func perform(_ action: CaptureAction) {
        lastAction = action
        switch action {
        case .captureArea: Task { await captureArea() }
        case .capturePreviousArea: Task { await capturePreviousArea() }
        case .captureWindow: Task { await captureWindow() }
        case .captureFullscreen: Task { await captureFullscreen() }
        case .captureScrolling: Task { await captureScrolling() }
        case .captureText: Task { await captureText() }
        case .toggleDesktopIcons: DesktopIconsManager.toggle()
        default: break
        }
    }

    /// Cancel an in-flight scrolling capture and stitch what was captured.
    public func stopScrolling() { scrolling?.stop() }

    // MARK: Capture flows

    public func captureArea() async { await selectAndCapture(initial: .area) }
    public func captureWindow() async { await selectAndCapture(initial: .window) }

    public func captureFullscreen() async {
        await run {
            let screen = NSScreen.underMouse
            guard await SelfTimer.countdown(seconds: self.selfTimerSeconds) else { return }
            let r = try await self.withDesktopPrep { try await self.service.captureFullscreen(screen: screen) }
            self.onCapture?(r)
        }
    }

    public func capturePreviousArea() async {
        await run {
            guard let rect = self.previousArea else { throw CaptureError.noPreviousArea }
            guard await SelfTimer.countdown(seconds: self.selfTimerSeconds) else { return }
            let r = try await self.withDesktopPrep { try await self.service.captureRect(rect) }
            self.onCapture?(r)
        }
    }

    public func captureScrolling() async {
        await run {
            guard case .rect(let rect)? = try await self.select(initial: .area) else { return }
            self.previousArea = rect
            guard await SelfTimer.countdown(seconds: self.selfTimerSeconds) else { return }
            let sc = ScrollingCapture(service: self.service)
            self.scrolling = sc
            defer { self.scrolling = nil }
            let r = try await self.withDesktopPrep { try await sc.capture(rect: rect) }
            self.onCapture?(r)
        }
    }

    public func captureText() async {
        await run {
            guard case .rect(let rect)? = try await self.select(initial: .area) else { return }
            try await Task.sleep(nanoseconds: 120_000_000)
            let shot = try await self.service.captureRect(rect)
            let text = try await OCRService.recognize(in: shot.image)
            if self.copyOCRToPasteboard { OCRService.copyToPasteboard(text) }
            self.onText?(text, CaptureResult(image: shot.image, scale: shot.scale, rect: rect, mode: .ocr))
        }
    }

    private func selectAndCapture(initial: SelectionOverlayController.Mode) async {
        await run {
            guard let outcome = try await self.select(initial: initial) else { return }
            guard await SelfTimer.countdown(seconds: self.selfTimerSeconds) else { return }
            try await Task.sleep(nanoseconds: 120_000_000) // overlay fade-out
            switch outcome {
            case .rect(let rect):
                self.previousArea = rect
                let r = try await self.withDesktopPrep { try await self.service.captureRect(rect) }
                self.onCapture?(r)
            case .window(let id, _):
                let r = try await self.withDesktopPrep { try await self.service.captureWindow(id: id) }
                self.onCapture?(r)
            }
        }
    }

    // MARK: Helpers

    private func select(initial: SelectionOverlayController.Mode) async throws -> SelectionOutcome? {
        guard await PermissionManager.shared.ensure(.screen) else { throw CaptureError.cancelled }
        let windows = (try? await service.listWindows()) ?? []
        var snaps: [CGDirectDisplayID: CGImage] = [:]
        for s in NSScreen.screens { snaps[s.displayID] = try? await service.captureRect(s.frame).image }
        return await overlay.run(mode: initial, windowCandidates: windows, snapshots: snaps)
    }

    private func withDesktopPrep<T>(_ body: () async throws -> T) async throws -> T {
        if hideDesktopIconsDuringCapture { return try await DesktopIconsManager.withIconsHidden(body) }
        return try await body()
    }

    private func run(_ body: @escaping () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await body() } catch CaptureError.cancelled {} catch is CancellationError {} catch { onError?(error) }
    }
}
