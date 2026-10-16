import Foundation
import AVFoundation
import CoreGraphics

/// High-level recording controller. Create one and keep it alive; observe `state` / `elapsed` from SwiftUI.
@MainActor
public final class RecordingManager: ObservableObject {
    @Published public private(set) var state: RecordingState = .idle
    @Published public private(set) var elapsed: TimeInterval = 0
    /// Called after `stop()` finishes or a stream error ends the recording.
    public var onFinished: ((Result<RecordingResult, Error>) -> Void)?

    private let engine = RecordingEngine()
    private var config: RecordingConfig?
    private var startedAt = Date()
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var ticker: Task<Void, Never>?
    private var cancelRequested = false

    public init() {
        engine.onError = { [weak self] err in
            Task { @MainActor in
                guard let self, self.state.isActive else { return }
                self.finishAfterError(err)
            }
        }
    }

    public static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified).devices
    }

    // MARK: Control

    /// Runs the optional countdown, then starts recording.
    public func start(_ config: RecordingConfig) async throws {
        guard state == .idle else { throw RecordingError.invalidState }
        guard await PermissionManager.shared.ensure(.screen) else { throw RecordingError.cancelled }
        if config.microphone && config.format == .mp4 {
            guard await PermissionManager.shared.ensure(.microphone) else { throw RecordingError.cancelled }
        }
        self.config = config
        cancelRequested = false

        if config.countdown > 0 {
            state = .countdown
            let ok = await CountdownOverlay.run(seconds: config.countdown)
            if !ok || cancelRequested { state = .idle; throw RecordingError.cancelled }
        }

        var extra = config.includedWindowIDs
        let overlays = InputOverlayController.shared
        if config.showClicks || config.showKeystrokes {
            overlays.start(showClicks: config.showClicks, showKeystrokes: config.showKeystrokes)
            extra += overlays.windowIDs
            try? await Task.sleep(nanoseconds: 150_000_000) // let WindowServer register the panels
        }

        let tempOrFinal = config.format == .gif
            ? RecordingPaths.tempURL(ext: "mp4")
            : (config.outputURL ?? RecordingPaths.defaultOutputURL(ext: "mp4"))
        do {
            var cfg = config
            if cfg.format == .gif { cfg.systemAudio = false; cfg.microphone = false }
            try await engine.start(config: cfg, outputURL: tempOrFinal, extraIncludedWindowIDs: extra)
        } catch {
            overlays.stop()
            state = .idle
            throw error
        }
        startedAt = Date(); pausedAt = nil; pausedTotal = 0; elapsed = 0
        state = .recording
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                self?.tick()
            }
        }
    }

    public func pause() {
        guard state == .recording else { return }
        engine.pause()
        pausedAt = Date()
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        engine.resume()
        if let p = pausedAt { pausedTotal += Date().timeIntervalSince(p) }
        pausedAt = nil
        state = .recording
    }

    public func togglePause() { state == .paused ? resume() : pause() }

    /// Stops, finalizes the file (mixing audio / converting to GIF as needed) and returns it.
    @discardableResult
    public func stop() async throws -> RecordingResult {
        if state == .countdown { cancelRequested = true; throw RecordingError.cancelled }
        guard state.isActive, let config else { throw RecordingError.invalidState }
        state = .finishing
        ticker?.cancel()
        InputOverlayController.shared.stop()
        do {
            let duration = try await engine.stop()
            let raw = engine.outputURL!
            let result: RecordingResult
            switch config.format {
            case .mp4:
                try await MediaExporter.mixAudioIfNeeded(at: raw)
                result = RecordingResult(url: raw, duration: duration, format: .mp4)
            case .gif:
                let dest = config.outputURL ?? RecordingPaths.defaultOutputURL(ext: "gif")
                try await MediaExporter.exportGIF(source: raw, destination: dest, fps: min(config.fps, 15))
                try? FileManager.default.removeItem(at: raw)
                result = RecordingResult(url: dest, duration: duration, format: .gif)
            }
            state = .idle
            onFinished?(.success(result))
            return result
        } catch {
            state = .idle
            onFinished?(.failure(error))
            throw error
        }
    }

    /// Aborts and deletes the partial recording.
    public func cancel() {
        if state == .countdown { cancelRequested = true; return }
        guard state.isActive else { return }
        ticker?.cancel()
        InputOverlayController.shared.stop()
        engine.cancel()
        state = .idle
    }

    // MARK: Private

    private func tick() {
        guard state == .recording else { return }
        elapsed = Date().timeIntervalSince(startedAt) - pausedTotal
    }

    private func finishAfterError(_ err: Error) {
        Task {
            do { try await stop() } catch { /* onFinished already notified */ }
        }
    }
}
