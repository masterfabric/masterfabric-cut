import Foundation
import CoreGraphics
import AVFoundation

/// What to record.
public enum RecordingTarget: Equatable {
    /// A whole display.
    case display(CGDirectDisplayID)
    /// A rectangle on a display. `rect` is in display-local points, origin at the TOP-LEFT of the display.
    case area(display: CGDirectDisplayID, rect: CGRect)
    /// A single window (follows the window when it moves unless overlays/webcam force a display crop).
    case window(CGWindowID)
}

public enum RecordingFormat: String, CaseIterable, Identifiable {
    case mp4, gif
    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
}

public enum RecordingCodec {
    case h264, hevc
    var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}

public struct RecordingConfig {
    public var target: RecordingTarget
    public var format: RecordingFormat = .mp4
    public var codec: RecordingCodec = .h264
    public var fps: Int = 30
    /// Capture at native pixel resolution (Retina) instead of points.
    public var retina: Bool = true
    public var showsCursor: Bool = true
    /// Record system audio (MP4 only).
    public var systemAudio: Bool = false
    /// Record microphone (MP4 only). `microphoneDeviceID` nil = system default.
    public var microphone: Bool = false
    public var microphoneDeviceID: String? = nil
    /// Draw click rings / keystroke HUD into the recording.
    public var showClicks: Bool = false
    public var showKeystrokes: Bool = false
    /// Seconds of on-screen countdown before recording starts (0 = none).
    public var countdown: Int = 0
    /// Extra windows that must appear in the recording (e.g. webcam bubble). Only meaningful for `.window` targets.
    public var includedWindowIDs: [CGWindowID] = []
    /// Windows to hide from the recording (e.g. your own HUD) for display/area targets.
    public var excludedWindowIDs: [CGWindowID] = []
    /// Dim everything outside the recorded frame (area/window targets only) while recording.
    public var dimOutside: Bool = false
    public var dimOpacity: Double = 0.45
    /// Final file location. nil = ~/Movies/MasterFabric Cut/Recording <date>.<ext>
    public var outputURL: URL? = nil

    public init(target: RecordingTarget) { self.target = target }
}

public struct RecordingResult {
    public let url: URL
    public let duration: TimeInterval
    public let format: RecordingFormat
}

public enum RecordingState: Equatable {
    case idle, countdown, recording, paused, finishing
    public var isActive: Bool { self == .recording || self == .paused }
}

public enum RecordingError: LocalizedError {
    case screenPermissionDenied
    case microphonePermissionDenied
    case cameraPermissionDenied
    case targetNotFound
    case invalidState
    case noFramesCaptured
    case writerFailed(String)
    case exportFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .screenPermissionDenied: return "Screen Recording permission is required. Enable it in System Settings › Privacy & Security."
        case .microphonePermissionDenied: return "Microphone permission is required."
        case .cameraPermissionDenied: return "Camera permission is required."
        case .targetNotFound: return "The selected window or display is no longer available."
        case .invalidState: return "Invalid recording state."
        case .noFramesCaptured: return "No video frames were captured."
        case .writerFailed(let m): return "Writing the recording failed: \(m)"
        case .exportFailed(let m): return "Export failed: \(m)"
        case .cancelled: return "Recording cancelled."
        }
    }
}

enum RecordingPaths {
    static func defaultOutputURL(ext: String) -> URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("MasterFabric Cut", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return dir.appendingPathComponent("Recording \(f.string(from: Date())).\(ext)")
    }

    static func tempURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mfcut-\(UUID().uuidString).\(ext)")
    }
}
