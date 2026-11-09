import Foundation
@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Trim / export helpers for MP4 and GIF.
public enum MediaExporter {

    /// Exports `source` (optionally trimmed to `range`) as MP4. Multiple audio tracks (system + mic) are mixed down.
    public static func exportMP4(source: URL, range: CMTimeRange? = nil, destination: URL,
                                 progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let r = range ?? CMTimeRange(start: .zero, duration: duration)

        let comp = AVMutableComposition()
        var audioParams: [AVMutableAudioMixInputParameters] = []
        if let v = try await asset.loadTracks(withMediaType: .video).first,
           let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try ct.insertTimeRange(r, of: v, at: .zero)
            ct.preferredTransform = try await v.load(.preferredTransform)
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        for a in audioTracks {
            guard let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try ct.insertTimeRange(r, of: a, at: .zero)
            let p = AVMutableAudioMixInputParameters(track: ct)
            p.setVolume(1, at: .zero)
            audioParams.append(p)
        }

        let preset = audioTracks.count > 1 ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough
        guard let session = AVAssetExportSession(asset: comp, presetName: preset) else {
            throw RecordingError.exportFailed("Cannot create export session")
        }
        if audioParams.count > 1 {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioParams
            session.audioMix = mix
        }
        try? FileManager.default.removeItem(at: destination)
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        let poll = Task {
            while !Task.isCancelled {
                progress?(Double(session.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { poll.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                if session.status == .completed { cont.resume() }
                else { cont.resume(throwing: RecordingError.exportFailed(session.error?.localizedDescription ?? "status \(session.status.rawValue)")) }
            }
        }
        progress?(1)
    }

    /// Exports `source` (optionally trimmed) as an animated GIF.
    public static func exportGIF(source: URL, range: CMTimeRange? = nil, destination: URL,
                                 fps: Int = 12, maxWidth: CGFloat = 800,
                                 progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let r = range ?? CMTimeRange(start: .zero, duration: duration)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await track.load(.naturalSize)
            if size.width > maxWidth { gen.maximumSize = CGSize(width: maxWidth, height: maxWidth * size.height / size.width) }
        }

        let step = 1.0 / Double(max(1, fps))
        let total = max(1, Int(r.duration.seconds / step))
        try? FileManager.default.removeItem(at: destination)
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, total, nil) else {
            throw RecordingError.exportFailed("Cannot create GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: step]] as CFDictionary
        for i in 0..<total {
            try Task.checkCancellation()
            let t = r.start + CMTime(seconds: Double(i) * step, preferredTimescale: 600)
            let (image, _) = try await gen.image(at: t)
            CGImageDestinationAddImage(dest, image, frameProps)
            progress?(Double(i + 1) / Double(total))
        }
        guard CGImageDestinationFinalize(dest) else { throw RecordingError.exportFailed("GIF finalize failed") }
    }

    /// If the file has more than one audio track, re-encodes in place with the tracks mixed together.
    static func mixAudioIfNeeded(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard try await asset.loadTracks(withMediaType: .audio).count > 1 else { return }
        let tmp = RecordingPaths.tempURL(ext: "mp4")
        try await exportMP4(source: url, destination: tmp)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    /// Concatenates selected time ranges from one source into a new MP4 (used by silence removal).
    public static func exportConcatenated(source: URL, ranges: [CMTimeRange], destination: URL,
                                          progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard !ranges.isEmpty else { throw RecordingError.exportFailed("Nothing left to export after silence removal") }
        let asset = AVURLAsset(url: source)
        let comp = AVMutableComposition()
        let vTrack = try await asset.loadTracks(withMediaType: .video).first
        let aTracks = try await asset.loadTracks(withMediaType: .audio)
        let cv = vTrack.flatMap { _ in comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) }
        var cas: [AVMutableCompositionTrack] = []
        for _ in aTracks {
            if let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                cas.append(t)
            }
        }
        if let vTrack, let cv {
            cv.preferredTransform = try await vTrack.load(.preferredTransform)
        }
        var cursor = CMTime.zero
        for (i, r) in ranges.enumerated() {
            try Task.checkCancellation()
            if let vTrack, let cv {
                try cv.insertTimeRange(r, of: vTrack, at: cursor)
            }
            for (ai, a) in aTracks.enumerated() where ai < cas.count {
                try cas[ai].insertTimeRange(r, of: a, at: cursor)
            }
            cursor = cursor + r.duration
            progress?(Double(i + 1) / Double(ranges.count) * 0.5)
        }
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingError.exportFailed("Cannot create export session")
        }
        try? FileManager.default.removeItem(at: destination)
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        try await run(session, progress: { p in progress?(0.5 + p * 0.5) })
    }

    /// Exports with shared batch settings (trim, optional silence, optional portrait reframe, profile size/quality).
    public static func exportWithSettings(source: URL, settings: SharedExportSettings, destination: URL,
                                          progress: (@Sendable (Double) -> Void)? = nil) async throws {
        var working = source
        var tempFiles: [URL] = []
        defer { for u in tempFiles { try? FileManager.default.removeItem(at: u) } }

        let asset = AVURLAsset(url: working)
        let duration = try await asset.load(.duration).seconds
        let trimEnd = min(settings.trimEnd ?? duration, duration)
        let trimStart = min(max(0, settings.trimStart), max(0, trimEnd - 0.05))
        let trim = CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600),
                               end: CMTime(seconds: trimEnd, preferredTimescale: 600))

        if settings.removeSilence {
            progress?(0.05)
            let analysis = try await SilenceRemover.analyze(
                url: working, thresholdDB: settings.silenceThresholdDB,
                minSilence: settings.silenceMinDuration, padding: settings.paddingAroundSpeech,
                progress: { p in progress?(0.05 + p * 0.2) })
            let clipped = analysis.keepRanges.compactMap { r -> CMTimeRange? in
                let inter = r.intersection(trim)
                return inter.duration.seconds > 0.05 ? inter : nil
            }
            let tmp = RecordingPaths.tempURL(ext: "mp4")
            tempFiles.append(tmp)
            try await SilenceRemover.exportKeeping(source: working, ranges: clipped.isEmpty ? [trim] : clipped,
                                                   destination: tmp) { p in progress?(0.25 + p * 0.25) }
            working = tmp
        } else if trimStart > 0.01 || trimEnd < duration - 0.01 {
            let tmp = RecordingPaths.tempURL(ext: "mp4")
            tempFiles.append(tmp)
            try await exportMP4(source: working, range: trim, destination: tmp) { p in progress?(p * 0.35) }
            working = tmp
        }

        if settings.reframePortrait || (settings.resolvedSize?.height ?? 0) > (settings.resolvedSize?.width ?? 1) {
            let outSize = settings.resolvedSize ?? CGSize(width: 1080, height: 1920)
            let plan = try await PortraitReframer.plan(
                url: working, outputSize: outSize, mode: settings.reframeMode,
                manualCenterX: settings.manualCropCenterX,
                progress: { p in progress?(0.55 + p * 0.15) })
            let tmp = RecordingPaths.tempURL(ext: "mp4")
            tempFiles.append(tmp)
            try await PortraitReframer.export(source: working, plan: plan, destination: tmp) { p in
                progress?(0.7 + p * 0.25)
            }
            working = tmp
        } else if let size = settings.resolvedSize, settings.platform != .original {
            try await exportScaled(source: working, size: size, qualityPreset: settings.qualityPreset(for: size),
                                   destination: destination, progress: { p in progress?(0.55 + p * 0.45) })
            progress?(1)
            return
        }

        if working == destination {
            progress?(1); return
        }
        if working != source {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: working, to: destination)
            progress?(1)
            return
        }
        try await exportMP4(source: working, destination: destination, progress: progress)
    }

    public static func exportScaled(source: URL, size: CGSize, qualityPreset: String, destination: URL,
                                    progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: source)
        // Prefer a size-matching preset; fall back to highest + video composition when needed.
        let preset = AVAssetExportSession.allExportPresets().contains(qualityPreset)
            ? qualityPreset : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw RecordingError.exportFailed("Cannot create scaled export session")
        }
        try? FileManager.default.removeItem(at: destination)
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let rendered = natural.applying(transform)
            let src = CGSize(width: abs(rendered.width), height: abs(rendered.height))
            if abs(src.width - size.width) > 2 || abs(src.height - size.height) > 2 {
                let comp = AVMutableVideoComposition()
                comp.renderSize = size
                comp.frameDuration = CMTime(value: 1, timescale: 30)
                let instruction = AVMutableVideoCompositionInstruction()
                let duration = try await asset.load(.duration)
                instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                let scale = min(size.width / src.width, size.height / src.height)
                let scaled = CGSize(width: src.width * scale, height: src.height * scale)
                let tx = (size.width - scaled.width) / 2
                let ty = (size.height - scaled.height) / 2
                var t = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
                t = t.concatenating(CGAffineTransform(translationX: tx, y: ty))
                layer.setTransform(t, at: .zero)
                instruction.layerInstructions = [layer]
                comp.instructions = [instruction]
                session.videoComposition = comp
            }
        }
        try await run(session, progress: progress)
    }

    public static func exportPortraitReframe(source: URL, plan: PortraitReframePlan, destination: URL,
                                             progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingError.exportFailed("No video track")
        }
        let duration = try await asset.load(.duration)
        let aspect = plan.outputSize.width / max(1, plan.outputSize.height)
        let centerX: Double = {
            if plan.modeUsed == .faceGuided, let mid = plan.centers.sorted(by: { $0.time < $1.time }).dropFirst(plan.centers.count / 2).first {
                return mid.x
            }
            return plan.fallbackCenterX
        }()
        // Single crop for the clip: face-guided uses the median center (honest: not per-frame warp in this increment).
        let crop = PortraitReframer.cropRect(source: plan.sourceSize, outputAspect: aspect, centerX: centerX)

        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecordingError.exportFailed("Cannot create composition")
        }
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        for a in try await asset.loadTracks(withMediaType: .audio) {
            guard let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try ca.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: a, at: .zero)
        }

        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = plan.outputSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: cv)
        let scale = plan.outputSize.width / crop.width
        let preferred = try await track.load(.preferredTransform)
        var t = preferred
        t = t.concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        layer.setTransform(t, at: .zero)
        instruction.layerInstructions = [layer]
        videoComp.instructions = [instruction]

        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingError.exportFailed("Cannot create portrait export session")
        }
        session.videoComposition = videoComp
        try? FileManager.default.removeItem(at: destination)
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        try await run(session, progress: progress)
    }

    /// Unique sibling path so originals are never overwritten.
    public static func nonDestructiveURL(for source: URL, suffix: String, ext: String, folder: URL?) -> URL {
        let dir = folder ?? source.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(base) (\(suffix)).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(suffix) \(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    private static func run(_ session: AVAssetExportSession, progress: (@Sendable (Double) -> Void)?) async throws {
        let poll = Task {
            while !Task.isCancelled {
                progress?(Double(session.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { poll.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                if session.status == .completed { cont.resume() }
                else if session.status == .cancelled { cont.resume(throwing: CancellationError()) }
                else { cont.resume(throwing: RecordingError.exportFailed(session.error?.localizedDescription ?? "status \(session.status.rawValue)")) }
            }
        }
        progress?(1)
    }
}

private extension CGSize {
    func applying(_ t: CGAffineTransform) -> CGSize {
        let r = CGRect(origin: .zero, size: self).applying(t)
        return CGSize(width: r.width, height: r.height)
    }
}
