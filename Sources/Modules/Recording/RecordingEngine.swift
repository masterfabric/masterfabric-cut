import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Low-level capture pipeline: ScreenCaptureKit video (+ system audio) and AVCapture microphone,
/// written with AVAssetWriter. All sample handling is serialized on one queue.
final class RecordingEngine: NSObject, SCStreamOutput, SCStreamDelegate,
                             AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    private let queue = DispatchQueue(label: "co.masterfabric.cut.recording.writer")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var micSession: AVCaptureSession?

    private var firstPTS: CMTime?
    private var pausedTotal = CMTime.zero
    private var lastVideoPTS = CMTime.invalid
    private var paused = false
    private var resumePending = false
    private var frameInterval = CMTime(value: 1, timescale: 30)

    var onError: ((Error) -> Void)?
    private(set) var outputURL: URL?

    // MARK: Start

    func start(config: RecordingConfig, outputURL url: URL, extraIncludedWindowIDs: [CGWindowID]) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let resolved = try resolve(config: config, content: content, extra: extraIncludedWindowIDs)

        let scale = config.retina ? CGFloat(resolved.filter.pointPixelScale) : 1
        let width = Self.even(resolved.pointSize.width * scale)
        let height = Self.even(resolved.pointSize.height * scale)

        let sc = SCStreamConfiguration()
        sc.width = width
        sc.height = height
        if let r = resolved.sourceRect { sc.sourceRect = r }
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, config.fps)))
        sc.pixelFormat = kCVPixelFormatType_32BGRA
        sc.showsCursor = config.showsCursor
        sc.queueDepth = 6
        let wantsAudio = config.format == .mp4
        sc.capturesAudio = wantsAudio && config.systemAudio
        sc.excludesCurrentProcessAudio = true
        sc.sampleRate = 48000
        sc.channelCount = 2

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: config.format == .mp4 ? .mp4 : .mov)
        let bitrate = max(2_000_000, Int(Double(width * height) * Double(config.fps) * 0.08))
        let vSettings: [String: Any] = [
            AVVideoCodecKey: config.codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: config.fps,
                AVVideoMaxKeyFrameIntervalKey: config.fps * 2
            ] as [String: Any]
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.expectsMediaDataInRealTime = true
        writer.add(vIn)

        var sysIn: AVAssetWriterInput?
        if wantsAudio && config.systemAudio {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 2, bitrate: 128_000))
            i.expectsMediaDataInRealTime = true
            writer.add(i); sysIn = i
        }
        var mIn: AVAssetWriterInput?
        if wantsAudio && config.microphone {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 1, bitrate: 96_000))
            i.expectsMediaDataInRealTime = true
            writer.add(i); mIn = i
        }
        guard writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        queue.sync {
            self.writer = writer
            self.videoInput = vIn
            self.systemInput = sysIn
            self.micInput = mIn
            self.firstPTS = nil
            self.pausedTotal = .zero
            self.lastVideoPTS = .invalid
            self.paused = false
            self.resumePending = false
            self.frameInterval = sc.minimumFrameInterval
            self.outputURL = url
        }

        let stream = SCStream(filter: resolved.filter, configuration: sc, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if sc.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if mIn != nil {
            try startMicrophone(deviceID: config.microphoneDeviceID)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    private func startMicrophone(deviceID: String?) throws {
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw RecordingError.microphonePermissionDenied }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecordingError.microphonePermissionDenied }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw RecordingError.microphonePermissionDenied }
        session.addOutput(output)
        session.startRunning()
        micSession = session
    }

    // MARK: Pause / resume

    func pause() { queue.async { self.paused = true } }

    func resume() {
        queue.async {
            guard self.paused else { return }
            self.paused = false
            self.resumePending = true
        }
    }

    // MARK: Stop

    /// Stops capture and finalizes the file. Returns duration in seconds.
    func stop() async throws -> TimeInterval {
        try? await stream?.stopCapture()
        stream = nil
        micSession?.stopRunning()
        micSession = nil
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard let writer = self.writer else { cont.resume(throwing: RecordingError.invalidState); return }
                guard let first = self.firstPTS else {
                    writer.cancelWriting()
                    self.writer = nil
                    cont.resume(throwing: RecordingError.noFramesCaptured)
                    return
                }
                let end: CMTime
                if self.paused || self.resumePending {
                    end = self.lastVideoPTS - first - self.pausedTotal
                } else {
                    end = CMClockGetTime(CMClockGetHostTimeClock()) - first - self.pausedTotal
                }
                self.videoInput?.markAsFinished()
                self.systemInput?.markAsFinished()
                self.micInput?.markAsFinished()
                writer.endSession(atSourceTime: max(end, .zero))
                writer.finishWriting {
                    self.writer = nil
                    if writer.status == .completed {
                        cont.resume(returning: max(end.seconds, 0))
                    } else {
                        cont.resume(throwing: RecordingError.writerFailed(writer.error?.localizedDescription ?? "unknown"))
                    }
                }
            }
        }
    }

    func cancel() {
        let s = stream; stream = nil
        micSession?.stopRunning(); micSession = nil
        Task { try? await s?.stopCapture() }
        queue.async {
            self.writer?.cancelWriting()
            self.writer = nil
            if let u = self.outputURL { try? FileManager.default.removeItem(at: u) }
        }
    }

    // MARK: Sample handling (runs on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen: handleVideo(sampleBuffer)
        case .audio: handleAudio(sampleBuffer, input: systemInput)
        default: break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handleAudio(sampleBuffer, input: micInput)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    private func handleVideo(_ sb: CMSampleBuffer) {
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = atts.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let writer, writer.status == .writing, let input = videoInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if paused { return }
        if firstPTS == nil { firstPTS = pts }
        if resumePending {
            let gap = pts - lastVideoPTS
            pausedTotal = pausedTotal + max(gap - frameInterval, .zero)
            resumePending = false
        }
        guard input.isReadyForMoreMediaData,
              let out = Self.retimed(sb, by: firstPTS! + pausedTotal) else { return }
        if input.append(out) { lastVideoPTS = pts }
    }

    private func handleAudio(_ sb: CMSampleBuffer, input: AVAssetWriterInput?) {
        guard let input, let first = firstPTS, !paused, !resumePending,
              CMSampleBufferDataIsReady(sb),
              let writer, writer.status == .writing, input.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts >= first else { return }
        if let out = Self.retimed(sb, by: first + pausedTotal) { input.append(out) }
    }

    // MARK: Helpers

    private struct Resolved {
        let filter: SCContentFilter
        let pointSize: CGSize
        let sourceRect: CGRect?
    }

    private func resolve(config: RecordingConfig, content: SCShareableContent, extra: [CGWindowID]) throws -> Resolved {
        func display(_ id: CGDirectDisplayID) throws -> SCDisplay {
            guard let d = content.displays.first(where: { $0.displayID == id }) else { throw RecordingError.targetNotFound }
            return d
        }
        let excluded = content.windows.filter { config.excludedWindowIDs.contains($0.windowID) }
        switch config.target {
        case .display(let id):
            let d = try display(id)
            return Resolved(filter: SCContentFilter(display: d, excludingWindows: excluded),
                            pointSize: CGSize(width: d.width, height: d.height), sourceRect: nil)
        case .area(let id, let rect):
            let d = try display(id)
            let bounds = CGRect(x: 0, y: 0, width: d.width, height: d.height)
            let r = rect.intersection(bounds).integral
            guard !r.isEmpty else { throw RecordingError.targetNotFound }
            return Resolved(filter: SCContentFilter(display: d, excludingWindows: excluded),
                            pointSize: r.size, sourceRect: r)
        case .window(let wid):
            guard let w = content.windows.first(where: { $0.windowID == wid }) else { throw RecordingError.targetNotFound }
            let extras = content.windows.filter { extra.contains($0.windowID) || config.includedWindowIDs.contains($0.windowID) }
            if extras.isEmpty {
                return Resolved(filter: SCContentFilter(desktopIndependentWindow: w), pointSize: w.frame.size, sourceRect: nil)
            }
            // Display crop so overlay windows (webcam bubble, click rings) are composited into the output.
            let d = content.displays.max(by: {
                $0.frame.intersection(w.frame).overlapArea < $1.frame.intersection(w.frame).overlapArea
            }) ?? content.displays.first
            guard let d else { throw RecordingError.targetNotFound }
            let local = CGRect(x: w.frame.minX - d.frame.minX, y: w.frame.minY - d.frame.minY,
                               width: w.frame.width, height: w.frame.height)
                .intersection(CGRect(x: 0, y: 0, width: d.width, height: d.height)).integral
            return Resolved(filter: SCContentFilter(display: d, including: [w] + extras),
                            pointSize: local.size, sourceRect: local)
        }
    }

    static func even(_ v: CGFloat) -> Int { max(2, Int(v.rounded()) & ~1) }

    static func aacSettings(channels: Int, bitrate: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC,
         AVNumberOfChannelsKey: channels,
         AVSampleRateKey: 48000,
         AVEncoderBitRateKey: bitrate]
    }

    static func retimed(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var info = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &info, entriesNeededOut: &count)
        for i in info.indices {
            info[i].presentationTimeStamp = info[i].presentationTimeStamp - offset
            if info[i].decodeTimeStamp.isValid { info[i].decodeTimeStamp = info[i].decodeTimeStamp - offset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: info, sampleBufferOut: &out)
        return out
    }
}

private extension CGRect {
    var overlapArea: CGFloat { isNull ? 0 : width * height }
}
