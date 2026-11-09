// MasterFabric Cut — Recording module
// Author: Gürkan Fikret Günak · masterfabric.co
import Foundation
import AVFoundation
import CoreGraphics

/// Destination platforms and shared size/quality knobs for batch / single export.
public enum ExportPlatform: String, CaseIterable, Identifiable, Sendable {
    case original
    case youtube
    case twitter
    case linkedIn
    case tikTok
    case instagramReel
    case instagramFeed
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: return "Original"
        case .youtube: return "YouTube"
        case .twitter: return "X / Twitter"
        case .linkedIn: return "LinkedIn"
        case .tikTok: return "TikTok"
        case .instagramReel: return "Instagram Reel"
        case .instagramFeed: return "Instagram Feed"
        case .custom: return "Custom"
        }
    }

    public var detail: String {
        switch self {
        case .original: return "Keep source resolution and timing"
        case .youtube: return "1920×1080 landscape, high quality"
        case .twitter: return "1280×720 landscape"
        case .linkedIn: return "1920×1080 landscape"
        case .tikTok: return "1080×1920 portrait"
        case .instagramReel: return "1080×1920 portrait"
        case .instagramFeed: return "1080×1350 portrait (4:5)"
        case .custom: return "Pick resolution and quality yourself"
        }
    }

    /// Suggested pixel size. `nil` means leave source size alone.
    public var suggestedSize: CGSize? {
        switch self {
        case .original: return nil
        case .youtube, .linkedIn: return CGSize(width: 1920, height: 1080)
        case .twitter: return CGSize(width: 1280, height: 720)
        case .tikTok, .instagramReel: return CGSize(width: 1080, height: 1920)
        case .instagramFeed: return CGSize(width: 1080, height: 1350)
        case .custom: return nil
        }
    }

    public var isPortrait: Bool {
        guard let s = suggestedSize else { return false }
        return s.height > s.width
    }
}

public enum ExportQuality: String, CaseIterable, Identifiable, Sendable {
    case highest, high, medium, smallFile
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .highest: return "Highest"
        case .high: return "High"
        case .medium: return "Medium"
        case .smallFile: return "Smaller file"
        }
    }

    public var avPreset: String {
        switch self {
        case .highest: return AVAssetExportPresetHighestQuality
        case .high: return AVAssetExportPreset1920x1080
        case .medium: return AVAssetExportPreset1280x720
        case .smallFile: return AVAssetExportPreset960x540
        }
    }
}

/// Shared settings applied to every item in a batch (or a single export).
public struct SharedExportSettings: Equatable, Sendable {
    public var platform: ExportPlatform = .original
    public var quality: ExportQuality = .high
    public var format: RecordingFormat = .mp4
    /// Trim applied to every file that is long enough. Nil = full duration.
    public var trimStart: Double = 0
    public var trimEnd: Double? = nil
    /// Custom size when platform == .custom (pixels). Nil = source.
    public var customWidth: Int = 1080
    public var customHeight: Int = 1920
    /// Soft target for output size guidance (MB). Used only as a quality hint, not a hard cap.
    public var targetFileSizeMB: Double? = nil
    public var removeSilence: Bool = false
    public var silenceThresholdDB: Float = -40
    public var silenceMinDuration: Double = 0.45
    public var paddingAroundSpeech: Double = 0.12
    public var reframePortrait: Bool = false
    public var reframeMode: PortraitReframeMode = .faceGuided
    /// Manual crop center X in source-normalized 0…1 (used when face-guided finds nothing, or mode is manual).
    public var manualCropCenterX: Double = 0.5
    public var outputFolder: URL? = nil
    /// Always write beside the original under a new name; never overwrite.
    public var keepOriginals: Bool = true

    public init() {}

    public var resolvedSize: CGSize? {
        switch platform {
        case .custom: return CGSize(width: customWidth, height: customHeight)
        default: return platform.suggestedSize
        }
    }

    public func qualityPreset(for size: CGSize?) -> String {
        if let mb = targetFileSizeMB {
            if mb <= 8 { return AVAssetExportPreset960x540 }
            if mb <= 25 { return AVAssetExportPreset1280x720 }
            if mb <= 80 { return AVAssetExportPreset1920x1080 }
            return AVAssetExportPresetHighestQuality
        }
        if let size, max(size.width, size.height) <= 960 { return AVAssetExportPreset960x540 }
        if let size, max(size.width, size.height) <= 1280 { return AVAssetExportPreset1280x720 }
        return quality.avPreset
    }
}
