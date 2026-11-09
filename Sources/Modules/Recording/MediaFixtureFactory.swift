// MasterFabric Cut — Recording module (DEBUG fixtures)
// Author: Gürkan Fikret Günak · masterfabric.co
#if DEBUG
import Foundation
@preconcurrency import AVFoundation
import CoreVideo

/// Builds synthetic audiovisual MP4s without personal media.
/// Strategy (macOS 27-safe): video-only MOV via AVAssetWriter, PCM WAV on disk, then AVAssetExportSession mux.
enum MediaFixtureFactory {

    static func toneSilenceVideo(to url: URL, width: Int, height: Int, fps: Int,
                                 pattern: [(Double, Bool)] = [(0.7, true), (0.9, false), (0.7, true), (0.9, false), (0.6, true)]) async throws -> URL {
        let sr = 44_100
        var pcm = [Int16]()
        for (secs, tone) in pattern {
            let n = Int(secs * Double(sr))
            if tone {
                for i in 0..<n {
                    let t = Double(i) / Double(sr)
                    let s = sin(2 * Double.pi * 440 * t) * 0.35
                    pcm.append(Int16((s * Double(Int16.max)).rounded()))
                }
            } else {
                pcm.append(contentsOf: repeatElement(0, count: n))
            }
        }
        let duration = Double(pcm.count) / Double(sr)
        let videoURL = url.deletingPathExtension().appendingPathExtension("video.mov")
        let wavURL = url.deletingPathExtension().appendingPathExtension("wav")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: wavURL)
        }
        try writeVideoOnly(to: videoURL, width: width, height: height, fps: fps, duration: duration) { buf, frame, total in
            let phase = frame % 40
            fillSolid(buf, r: 28 + phase, g: 36, b: 52)
            let tSec = Double(frame) / Double(fps)
            var acc = 0.0
            var isTone = false
            for (secs, tone) in pattern {
                if tSec < acc + secs { isTone = tone; break }
                acc += secs
            }
            if isTone {
                let h = CVPixelBufferGetHeight(buf)
                let w = CVPixelBufferGetWidth(buf)
                fillRect(buf, x: 40, y: h / 2 - 20, w: w - 80, h: 40, r: 220, g: 220, b: 80)
            }
        }
        try writeWAV(pcm, sampleRate: sr, to: wavURL)
        try await mux(video: videoURL, audio: wavURL, to: url)
        return url
    }

    static func movingFaceVideo(to url: URL, width: Int, height: Int, fps: Int, seconds: Double) async throws -> URL {
        let sr = 44_100
        let n = Int(seconds * Double(sr))
        var pcm = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            let s = sin(2 * Double.pi * 330 * Double(i) / Double(sr)) * 0.2
            pcm[i] = Int16((s * Double(Int16.max)).rounded())
        }
        let videoURL = url.deletingPathExtension().appendingPathExtension("video.mov")
        let wavURL = url.deletingPathExtension().appendingPathExtension("wav")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: wavURL)
        }
        let frames = max(1, Int(seconds * Double(fps)))
        try writeVideoOnly(to: videoURL, width: width, height: height, fps: fps, duration: seconds) { buf, frame, total in
            fillSolid(buf, r: 40, g: 48, b: 60)
            let t = Double(frame) / Double(max(1, total - 1))
            let cx = Int(Double(width) * (0.22 + 0.56 * t))
            drawFace(buf, cx: cx, cy: height / 2, scale: 1.15)
        }
        try writeWAV(pcm, sampleRate: sr, to: wavURL)
        try await mux(video: videoURL, audio: wavURL, to: url)
        return url
    }

    // MARK: Writers

    private static func writeVideoOnly(to url: URL, width: Int, height: Int, fps: Int, duration: Double,
                                       draw: (_ buf: CVPixelBuffer, _ frame: Int, _ total: Int) -> Void) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(vIn)
        guard writer.startWriting() else {
            throw RecordingError.exportFailed(writer.error?.localizedDescription ?? "video writer start failed")
        }
        writer.startSession(atSourceTime: .zero)
        let total = max(1, Int((duration * Double(fps)).rounded()))
        let frameDur = CMTime(value: 1, timescale: CMTimeScale(fps))
        for frame in 0..<total {
            var waits = 0
            while !vIn.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.001)
                waits += 1
                if waits > 10_000 { throw RecordingError.exportFailed("video input never ready") }
            }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buf = pb else { continue }
            draw(buf, frame, total)
            if !adaptor.append(buf, withPresentationTime: CMTimeMultiply(frameDur, multiplier: Int32(frame))) {
                throw RecordingError.exportFailed(writer.error?.localizedDescription ?? "append frame failed")
            }
        }
        vIn.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        if sem.wait(timeout: .now() + 30) == .timedOut {
            throw RecordingError.exportFailed("video finish timed out")
        }
        if writer.status != .completed {
            throw RecordingError.exportFailed(writer.error?.localizedDescription ?? "video write failed")
        }
    }

    private static func writeWAV(_ pcm: [Int16], sampleRate: Int, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        var data = Data()
        func appendU32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        let dataSize = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        appendU32(36 + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        appendU32(16) // pcm fmt chunk
        appendU16(1) // PCM
        appendU16(1) // mono
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(sampleRate * 2))
        appendU16(2) // block align
        appendU16(16) // bits
        data.append(contentsOf: Array("data".utf8))
        appendU32(dataSize)
        pcm.withUnsafeBufferPointer { ptr in
            data.append(UnsafeBufferPointer(start: UnsafeRawPointer(ptr.baseAddress!).assumingMemoryBound(to: UInt8.self), count: pcm.count * 2))
        }
        try data.write(to: url)
    }

    private static func mux(video: URL, audio: URL, to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        let vAsset = AVURLAsset(url: video)
        let aAsset = AVURLAsset(url: audio)
        let comp = AVMutableComposition()
        guard let vt = try await vAsset.loadTracks(withMediaType: .video).first,
              let at = try await aAsset.loadTracks(withMediaType: .audio).first,
              let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecordingError.exportFailed("mux tracks unavailable")
        }
        let vd = try await vAsset.load(.duration)
        let ad = try await aAsset.load(.duration)
        let dur = CMTimeMinimum(vd, ad)
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vt, at: .zero)
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: at, at: .zero)
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingError.exportFailed("mux export session failed")
        }
        session.outputURL = output
        session.outputFileType = .mp4
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                if session.status == .completed { cont.resume() }
                else { cont.resume(throwing: RecordingError.exportFailed(session.error?.localizedDescription ?? "mux status \(session.status.rawValue)")) }
            }
        }
    }

    // MARK: Drawing

    private static func fillSolid(_ buf: CVPixelBuffer, r: Int, g: Int, b: Int) {
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return }
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let i = x * 4
                row[i] = UInt8(b); row[i + 1] = UInt8(g); row[i + 2] = UInt8(r); row[i + 3] = 255
            }
        }
    }

    private static func fillRect(_ buf: CVPixelBuffer, x: Int, y: Int, w: Int, h: Int, r: Int, g: Int, b: Int) {
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let width = CVPixelBufferGetWidth(buf), height = CVPixelBufferGetHeight(buf)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return }
        let x0 = max(0, x), y0 = max(0, y), x1 = min(width, x + w), y1 = min(height, y + h)
        for yy in y0..<y1 {
            let row = base.advanced(by: yy * stride).assumingMemoryBound(to: UInt8.self)
            for xx in x0..<x1 {
                let i = xx * 4
                row[i] = UInt8(b); row[i + 1] = UInt8(g); row[i + 2] = UInt8(r); row[i + 3] = 255
            }
        }
    }

    private static func drawFace(_ buf: CVPixelBuffer, cx: Int, cy: Int, scale: Double) {
        let fw = Int(90 * scale), fh = Int(120 * scale)
        for dy in -fh / 2 ... fh / 2 {
            let t = Double(dy) / Double(max(1, fh / 2))
            let half = Int(Double(fw / 2) * sqrt(max(0, 1 - t * t)))
            fillRect(buf, x: cx - half, y: cy + dy, w: max(1, half * 2), h: 1, r: 220, g: 175, b: 145)
        }
        fillRect(buf, x: cx - Int(22 * scale), y: cy - Int(18 * scale), w: Int(12 * scale), h: Int(10 * scale), r: 30, g: 30, b: 30)
        fillRect(buf, x: cx + Int(10 * scale), y: cy - Int(18 * scale), w: Int(12 * scale), h: Int(10 * scale), r: 30, g: 30, b: 30)
        fillRect(buf, x: cx - Int(18 * scale), y: cy + Int(28 * scale), w: Int(36 * scale), h: Int(8 * scale), r: 150, g: 60, b: 60)
    }
}
#endif
