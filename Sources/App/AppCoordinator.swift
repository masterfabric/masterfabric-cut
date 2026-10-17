import AppKit
import Combine
import SwiftUI

/// Single integration point between the app shell and the feature modules.
/// Menu items and global hotkeys both route through `perform(_:)`.
@MainActor
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    let capture = CaptureCoordinator()
    let recorder = RecordingManager()
    private let studio = RecordingStudio()
    private var studioWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    /// Fired when recording state changes so the menu bar can update.
    var onRecordingStateChange: (() -> Void)?

    private init() {
        capture.onCapture = { [weak self] r in self?.handle(r) }
        capture.onText = { text, _ in AnnotateModule.shared.handleOCRText(text) }
        capture.onError = { [weak self] error in
            ErrorPresenter.present(error, title: "Capture couldn't finish") {
                if let a = self?.capture.lastAction { self?.perform(a) }
            }
        }
        recorder.onFinished = { [weak self] result in self?.finished(result) }
        studio.onFinished = { [weak self] r in self?.finished(.success(r)) }
        recorder.$state.sink { [weak self] _ in DispatchQueue.main.async { self?.onRecordingStateChange?() } }.store(in: &cancellables)
    }

    func start() {
        HotkeyManager.shared.start { [weak self] action in self?.perform(action) }
    }

    func perform(_ action: CaptureAction) {
        syncSettings()
        switch action {
        case .captureArea, .capturePreviousArea, .captureWindow, .captureFullscreen,
             .captureScrolling, .captureText, .toggleDesktopIcons:
            capture.perform(action)
        case .recordScreen: Task { await startRecording(format: .mp4) }
        case .recordGIF: Task { await startRecording(format: .gif) }
        case .openStudio: showStudio()
        case .openHistory: AnnotateModule.shared.showHistory()
        }
    }

    func selfTimerCapture() {
        syncSettings()
        capture.selfTimerSeconds = AppSettings.shared.timerSeconds
        capture.perform(.captureArea)
        // Capture reads the value when the selection completes; reset on the next action via syncSettings.
    }

    func pinClipboardImage() {
        if let img = NSImage(pasteboard: .general) { AnnotateModule.shared.pin(image: img) }
    }

    func stopRecording() { Task { _ = try? await recorder.stop() } }
    func togglePauseRecording() { recorder.togglePause() }

    // MARK: Settings sync

    private func syncSettings() {
        let s = AppSettings.shared
        capture.selfTimerSeconds = 0
        capture.hideDesktopIconsDuringCapture = s.hideDesktopIcons
        let qa = QuickAccessOverlayController.shared
        qa.configuration.position = QuickAccessPosition(rawValue: s.overlayCorner.rawValue) ?? .bottomLeft
        qa.configuration.autoCloseDelay = TimeInterval(s.overlayAutoCloseSeconds)
        qa.configuration.saveDirectory = s.saveDirectory
        qa.configuration.format = AnnotateOutputFormat(rawValue: s.imageFormat == .jpg ? "jpeg" : s.imageFormat.rawValue) ?? .png
        qa.configuration.closeAfterAction = s.overlayCloseAfterAction
        CaptureHistoryStore.shared.maxItems = s.historyLimit
    }

    // MARK: Capture results

    private func handle(_ r: CaptureResult) {
        let s = AppSettings.shared
        let image = r.nsImage
        if s.copyToClipboard { FileOutput.copy(image) }
        let url = s.saveAutomatically ? FileOutput.save(image) : nil
        if s.playSounds { NSSound(named: "Grab")?.play() ?? NSSound(named: "Pop")?.play() }
        AnnotateModule.shared.handleCapture(image, fileURL: url, showQuickAccess: s.overlayEnabled)
    }

    // MARK: Recording

    private func startRecording(format: RecordingFormat) async {
        if recorder.state.isActive { stopRecording(); return }
        let s = AppSettings.shared
        let overlay = SelectionOverlayController()
        guard await PermissionManager.shared.ensure(.screen, onGranted: { [weak self] in Task { await self?.startRecording(format: format) } }) else { return }
        guard case .rect(let rect)? = await overlay.run(mode: .area, windowCandidates: [], snapshots: [:]) else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else { return }
        let local = CGRect(x: rect.minX - screen.frame.minX,
                           y: screen.frame.height - (rect.maxY - screen.frame.minY),
                           width: rect.width, height: rect.height)
        var cfg = RecordingConfig(target: .area(display: screen.displayID, rect: local))
        cfg.format = format
        cfg.fps = format == .gif ? s.gifFPS : s.recordFPS
        cfg.retina = s.retina
        cfg.systemAudio = s.recordSystemAudio && format == .mp4
        cfg.microphone = s.recordMic && format == .mp4
        cfg.showClicks = s.showClicks
        cfg.showKeystrokes = s.showKeystrokes
        cfg.countdown = 3
        cfg.dimOutside = s.recordDimEnabled
        cfg.dimOpacity = s.recordDimOpacity
        do { try await recorder.start(cfg) } catch {
            ErrorPresenter.present(error, title: "Recording couldn't start") { [weak self] in Task { await self?.startRecording(format: format) } }
        }
    }

    private func finished(_ result: Result<RecordingResult, Error>) {
        switch result {
        case .success(let r):
            AnnotateModule.shared.handleRecording(at: r.url, isGIF: r.format == .gif)
            if r.format == .mp4 { TrimEditorWindowController.present(url: r.url, onExported: { _ in }) }
            NSWorkspace.shared.activateFileViewerSelecting([r.url])
        case .failure(let e):
            ErrorPresenter.present(e, title: "Recording couldn't be saved")
        }
    }

    // MARK: Studio

    func showStudio() {
        if studioWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: RecordingStudioView(studio: studio)))
            w.isReleasedWhenClosed = false; w.title = "Recording Studio"; w.styleMask = [.titled, .closable, .miniaturizable]
            studioWindow = w
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.studio.setStudioOpen(false) }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        studioWindow?.center(); studioWindow?.makeKeyAndOrderFront(nil)
        studio.setStudioOpen(true)
        Task { await studio.refresh(); await studio.syncBubble() }
    }
}
