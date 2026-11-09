// MasterFabric Cut — Recording module
// Author: Gürkan Fikret Günak · masterfabric.co
import Foundation
@preconcurrency import AVFoundation

public struct SilenceSegment: Identifiable, Equatable, Sendable {
    public var id: String { "\(start)-\(end)" }
    public var start: Double
    public var end: Double
    public var duration: Double { max(0, end - start) }
}

public struct SilenceAnalysis: Equatable, Sendable {
    public var duration: Double
    public var silent: [SilenceSegment]
    public var keepRanges: [CMTimeRange]
    public var thresholdDB: Float
    public var minSilence: Double

    public var removedDuration: Double { silent.reduce(0) { $0 + $1.duration } }
    public var keptDuration: Double { max(0, duration - removedDuration) }
}

/// Detects quiet stretches in a media file's audio and builds a non-destructive keep list.
public enum SilenceRemover {

    /// Analyzes average power in ~50 ms windows. Threshold is dBFS (e.g. -40).
    public static func analyze(url: URL, thresholdDB: Float = -40, minSilence: Double = 0.45,
                               padding: Double = 0.12,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> SilenceAnalysis {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw RecordingError.exportFailed("Media has no readable duration")
        }
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            // No audio: nothing to remove — keep the whole file.
            let full = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
            return SilenceAnalysis(duration: duration, silent: [], keepRanges: [full],
                                   thresholdDB: thresholdDB, minSilence: minSilence)
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecordingError.exportFailed("Cannot read audio for silence analysis") }
        reader.add(output)
        guard reader.startReading() else {
            throw RecordingError.exportFailed(reader.error?.localizedDescription ?? "Audio reader failed")
        }

        let windowSec = 0.05
        var powers: [Float] = []
        var samplesInWindow = 0
        var windowSumSquares: Float = 0
        let samplesPerWindow = max(1, Int(16_000 * windowSec))

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let count = length / MemoryLayout<Int16>.size
                let ptr = raw.bindMemory(to: Int16.self)
                for i in 0..<count {
                    let s = Float(ptr[i]) / Float(Int16.max)
                    windowSumSquares += s * s
                    samplesInWindow += 1
                    if samplesInWindow >= samplesPerWindow {
                        let rms = sqrt(windowSumSquares / Float(samplesInWindow))
                        let db = 20 * log10(max(rms, 1e-8))
                        powers.append(db)
                        windowSumSquares = 0
                        samplesInWindow = 0
                        if powers.count % 20 == 0 {
                            progress?(min(0.95, Double(powers.count) * windowSec / duration))
                        }
                    }
                }
            }
        }
        if samplesInWindow > 0 {
            let rms = sqrt(windowSumSquares / Float(samplesInWindow))
            powers.append(20 * log10(max(rms, 1e-8)))
        }
        progress?(1)

        var silent: [SilenceSegment] = []
        var i = 0
        while i < powers.count {
            if powers[i] < thresholdDB {
                let startIdx = i
                while i < powers.count && powers[i] < thresholdDB { i += 1 }
                let start = Double(startIdx) * windowSec
                let end = min(duration, Double(i) * windowSec)
                if end - start >= minSilence {
                    silent.append(SilenceSegment(start: start, end: end))
                }
            } else {
                i += 1
            }
        }

        let keep = keepRanges(duration: duration, silent: silent, padding: padding)
        return SilenceAnalysis(duration: duration, silent: silent, keepRanges: keep,
                               thresholdDB: thresholdDB, minSilence: minSilence)
    }

    public static func keepRanges(duration: Double, silent: [SilenceSegment], padding: Double) -> [CMTimeRange] {
        var cuts = silent.map { (max(0, $0.start + padding), min(duration, $0.end - padding)) }
            .filter { $0.1 > $0.0 }
        cuts.sort { $0.0 < $1.0 }

        var cursor = 0.0
        var ranges: [CMTimeRange] = []
        for (s, e) in cuts {
            if s > cursor + 0.02 {
                ranges.append(CMTimeRange(
                    start: CMTime(seconds: cursor, preferredTimescale: 600),
                    end: CMTime(seconds: s, preferredTimescale: 600)))
            }
            cursor = max(cursor, e)
        }
        if cursor < duration - 0.02 {
            ranges.append(CMTimeRange(
                start: CMTime(seconds: cursor, preferredTimescale: 600),
                end: CMTime(seconds: duration, preferredTimescale: 600)))
        }
        if ranges.isEmpty {
            ranges = [CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))]
        }
        return ranges
    }

    /// Writes a new file that concatenates `keepRanges`. Never overwrites `source`.
    public static func exportKeeping(source: URL, ranges: [CMTimeRange], destination: URL,
                                     progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await MediaExporter.exportConcatenated(source: source, ranges: ranges,
                                                   destination: destination, progress: progress)
    }
}
