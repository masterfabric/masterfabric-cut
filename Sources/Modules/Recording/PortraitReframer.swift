// MasterFabric Cut — Recording module
// Author: Gürkan Fikret Günak · masterfabric.co
import Foundation
@preconcurrency import AVFoundation
import Vision
import CoreImage
import CoreGraphics

public enum PortraitReframeMode: String, CaseIterable, Identifiable, Sendable {
    case faceGuided
    case manual
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .faceGuided: return "Face-guided when available"
        case .manual: return "Manual crop"
        }
    }
    public var detail: String {
        switch self {
        case .faceGuided:
            return "Samples on-device Vision face boxes over time and animates the crop between those centers. Not speaker diarization or lip tracking — if no face is found, falls back to the manual center."
        case .manual:
            return "Fixed vertical crop centered on the position you set. No automatic tracking."
        }
    }
}

public struct FaceCenterSample: Equatable, Sendable {
    public var time: Double
    public var x: Double
    public init(time: Double, x: Double) { self.time = time; self.x = x }
}

public struct PortraitReframePlan: Equatable, Sendable {
    public var sourceSize: CGSize
    public var outputSize: CGSize
    /// Normalized crop centers over time (0…1 X in source). Empty → use `fallbackCenterX` for the whole clip.
    public var centers: [FaceCenterSample]
    public var fallbackCenterX: Double
    public var facesDetected: Bool
    public var modeUsed: PortraitReframeMode
    public var note: String
}

/// Landscape → portrait crop. Face-guided path samples Vision face boxes; otherwise honest manual crop.
public enum PortraitReframer {

    public static func plan(url: URL, outputSize: CGSize = CGSize(width: 1080, height: 1920),
                            mode: PortraitReframeMode = .faceGuided,
                            manualCenterX: Double = 0.5,
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> PortraitReframePlan {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingError.exportFailed("No video track to reframe")
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let size = natural.applying(transform).applying(CGAffineTransform(scaleX: 1, y: 1))
        let src = CGSize(width: abs(size.width), height: abs(size.height))
        let duration = try await asset.load(.duration).seconds

        var centers: [FaceCenterSample] = []
        var faces = false

        if mode == .faceGuided {
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 640, height: 640)
            let step = max(0.35, duration / 48)
            var t = 0.0
            var idx = 0
            let total = max(1, Int(duration / step) + 1)
            while t <= duration + 0.001 {
                try Task.checkCancellation()
                let cm = CMTime(seconds: t, preferredTimescale: 600)
                if let (cg, _) = try? await gen.image(at: cm),
                   let x = try? await faceCenterX(in: cg) {
                    centers.append(FaceCenterSample(time: t, x: x))
                    faces = true
                }
                t += step
                idx += 1
                progress?(Double(idx) / Double(total) * 0.7)
            }
            centers = smooth(centers)
        }

        let note: String
        let modeUsed: PortraitReframeMode
        if mode == .faceGuided && faces {
            note = "Face boxes detected on \(centers.count) sampled frame(s). Export animates crop between smoothed centers (Vision faces only — not lip/speaker ID)."
            modeUsed = .faceGuided
        } else if mode == .faceGuided {
            note = "No face detected in sampled frames. Using fixed manual crop center \(String(format: "%.0f%%", manualCenterX * 100))."
            modeUsed = .manual
        } else {
            note = "Manual crop center \(String(format: "%.0f%%", manualCenterX * 100))."
            modeUsed = .manual
        }

        progress?(1)
        return PortraitReframePlan(sourceSize: src, outputSize: outputSize, centers: centers,
                                   fallbackCenterX: min(1, max(0, manualCenterX)),
                                   facesDetected: faces, modeUsed: modeUsed, note: note)
    }

    /// Linear interpolation of normalized crop center X at `time` (seconds).
    public static func centerX(at time: Double, plan: PortraitReframePlan) -> Double {
        let pts = plan.centers.sorted { $0.time < $1.time }
        guard plan.modeUsed == .faceGuided, !pts.isEmpty else { return plan.fallbackCenterX }
        if time <= pts.first!.time { return pts.first!.x }
        if time >= pts.last!.time { return pts.last!.x }
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            if time >= a.time && time <= b.time {
                let span = max(0.0001, b.time - a.time)
                let t = (time - a.time) / span
                return a.x + (b.x - a.x) * t
            }
        }
        return plan.fallbackCenterX
    }

    public static func transform(for plan: PortraitReframePlan, preferred: CGAffineTransform, centerX: Double) -> CGAffineTransform {
        let aspect = plan.outputSize.width / max(1, plan.outputSize.height)
        let crop = cropRect(source: plan.sourceSize, outputAspect: aspect, centerX: centerX)
        let scale = plan.outputSize.width / max(1, crop.width)
        return preferred
            .concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }

    public static func export(source: URL, plan: PortraitReframePlan, destination: URL,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await MediaExporter.exportPortraitReframe(source: source, plan: plan,
                                                      destination: destination, progress: progress)
    }

    private static func faceCenterX(in image: CGImage) async throws -> Double? {
        try await withCheckedThrowingContinuation { cont in
            let request = VNDetectFaceRectanglesRequest { req, err in
                if let err { cont.resume(throwing: err); return }
                let faces = (req.results as? [VNFaceObservation]) ?? []
                guard let best = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height
                    < $1.boundingBox.width * $1.boundingBox.height }) else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: Double(best.boundingBox.midX))
            }
            request.revision = VNDetectFaceRectanglesRequestRevision3
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            do { try handler.perform([request]) }
            catch { cont.resume(throwing: error) }
        }
    }

    private static func smooth(_ pts: [FaceCenterSample]) -> [FaceCenterSample] {
        guard pts.count > 2 else { return pts }
        var out = pts
        for i in 1..<out.count - 1 {
            out[i].x = (pts[i - 1].x + pts[i].x + pts[i + 1].x) / 3
        }
        return out
    }

    /// Crop rect in source pixels for a given normalized center X and output aspect.
    public static func cropRect(source: CGSize, outputAspect: CGFloat, centerX: Double) -> CGRect {
        let targetAspect = outputAspect
        var cropW = source.height * targetAspect
        var cropH = source.height
        if cropW > source.width {
            cropW = source.width
            cropH = source.width / targetAspect
        }
        let cx = CGFloat(centerX) * source.width
        var x = cx - cropW / 2
        var y = (source.height - cropH) / 2
        x = min(max(0, x), source.width - cropW)
        y = min(max(0, y), source.height - cropH)
        return CGRect(x: x, y: y, width: cropW, height: cropH)
    }
}

private extension CGSize {
    func applying(_ t: CGAffineTransform) -> CGSize {
        let r = CGRect(origin: .zero, size: self).applying(t)
        return CGSize(width: r.width, height: r.height)
    }
}
