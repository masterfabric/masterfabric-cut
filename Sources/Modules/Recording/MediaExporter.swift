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
}
