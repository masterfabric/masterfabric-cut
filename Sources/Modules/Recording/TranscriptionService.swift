// MasterFabric Cut — Recording module
// Author: Gürkan Fikret Günak · masterfabric.co
import Foundation
import Speech
import AVFoundation

public struct CaptionCue: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: UUID = UUID(), start: Double, end: Double, text: String) {
        self.id = id; self.start = start; self.end = end; self.text = text
    }
}

public struct TranscriptionAvailability: Equatable, Sendable {
    public var localeIdentifier: String
    public var localeDisplayName: String
    public var recognizerAvailable: Bool
    public var onDeviceSupported: Bool
    public var authorization: SFSpeechRecognizerAuthorizationStatus
    public var note: String
}

public enum SubtitleFormat: String, CaseIterable, Identifiable, Sendable {
    case srt, vtt
    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
    public var fileExtension: String { rawValue }
}

/// On-device file transcription via Speech framework. Reports Turkish (and other) availability honestly.
public enum TranscriptionService {

    public static let preferredTurkish = Locale(identifier: "tr-TR")

    public static func availability(locale: Locale = preferredTurkish) -> TranscriptionAvailability {
        let id = locale.identifier
        let name = Locale.current.localizedString(forIdentifier: id) ?? id
        let auth = SFSpeechRecognizer.authorizationStatus()
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return TranscriptionAvailability(
                localeIdentifier: id, localeDisplayName: name,
                recognizerAvailable: false, onDeviceSupported: false, authorization: auth,
                note: "No Speech recognizer is installed for \(name) on this Mac. Install the language in System Settings › Keyboard › Dictation / Language, or pick another locale.")
        }
        let onDevice = recognizer.supportsOnDeviceRecognition
        var note: String
        if !recognizer.isAvailable {
            note = "The \(name) recognizer exists but is currently unavailable (network/language assets)."
        } else if !onDevice {
            note = "\(name) is available, but on-device recognition is not supported for this locale on this Mac. MasterFabric Cut will not fall back to cloud Speech."
        } else {
            note = "\(name) on-device recognition is available on this Mac."
        }
        switch auth {
        case .denied:
            note += " Speech Recognition permission is denied in System Settings."
        case .restricted:
            note += " Speech Recognition is restricted on this Mac."
        case .notDetermined:
            note += " Permission has not been requested yet."
        case .authorized:
            break
        @unknown default:
            break
        }
        return TranscriptionAvailability(localeIdentifier: id, localeDisplayName: name,
                                         recognizerAvailable: recognizer.isAvailable,
                                         onDeviceSupported: onDevice, authorization: auth, note: note)
    }

    public static func supportedLocales() -> [Locale] {
        Array(SFSpeechRecognizer.supportedLocales()).sorted {
            ($0.identifier) < ($1.identifier)
        }
    }

    @MainActor
    public static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    /// Transcribes a local media file on-device. Fails clearly when on-device is unavailable.
    public static func transcribe(url: URL, locale: Locale = preferredTurkish,
                                  progress: (@Sendable (Double) -> Void)? = nil) async throws -> [CaptionCue] {
        let avail = availability(locale: locale)
        guard avail.authorization == .authorized else {
            throw RecordingError.exportFailed("Speech Recognition permission is required for captions.")
        }
        guard avail.recognizerAvailable else {
            throw RecordingError.exportFailed(avail.note)
        }
        guard avail.onDeviceSupported else {
            throw RecordingError.exportFailed("On-device recognition is not available for \(avail.localeDisplayName). Cut refuses cloud Speech uploads.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw RecordingError.exportFailed("Could not create recognizer for \(locale.identifier)")
        }
        recognizer.defaultTaskHint = .dictation

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if !finished {
                        finished = true
                        cont.resume(throwing: RecordingError.exportFailed(error.localizedDescription))
                    }
                    return
                }
                guard let result else { return }
                progress?(result.isFinal ? 1 : 0.55)
                if result.isFinal {
                    guard !finished else { return }
                    finished = true
                    let cues = cues(from: result)
                    cont.resume(returning: cues)
                }
            }
            // Keep task alive until callback; Speech retains it via the recognizer.
            _ = task
        }
    }

    public static func exportSubtitles(_ cues: [CaptionCue], format: SubtitleFormat, to url: URL) throws {
        let body: String
        switch format {
        case .srt: body = srt(cues)
        case .vtt: body = vtt(cues)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func cues(from result: SFSpeechRecognitionResult) -> [CaptionCue] {
        // Prefer segment timing when present; otherwise chunk by approximate duration.
        let segments = result.bestTranscription.segments
        if !segments.isEmpty {
            var out: [CaptionCue] = []
            var buf = ""
            var start = segments[0].timestamp
            var end = start
            for (i, seg) in segments.enumerated() {
                if buf.isEmpty { start = seg.timestamp }
                if !buf.isEmpty { buf += " " }
                buf += seg.substring
                end = seg.timestamp + seg.duration
                let punct = seg.substring.contains(where: { ".!?。！？".contains($0) })
                if punct || buf.split(separator: " ").count >= 12 || i == segments.count - 1 {
                    out.append(CaptionCue(start: start, end: max(end, start + 0.4), text: buf.trimmingCharacters(in: .whitespacesAndNewlines)))
                    buf = ""
                }
            }
            return out.filter { !$0.text.isEmpty }
        }
        let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [CaptionCue(start: 0, end: 3, text: text)]
    }

    private static func srt(_ cues: [CaptionCue]) -> String {
        cues.enumerated().map { i, c in
            "\(i + 1)\n\(srtTime(c.start)) --> \(srtTime(c.end))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    private static func vtt(_ cues: [CaptionCue]) -> String {
        "WEBVTT\n\n" + cues.map { c in
            "\(vttTime(c.start)) --> \(vttTime(c.end))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    private static func srtTime(_ s: Double) -> String {
        let t = max(0, s)
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let sec = Int(t) % 60
        let ms = Int((t - floor(t)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, sec, ms)
    }

    private static func vttTime(_ s: Double) -> String {
        srtTime(s).replacingOccurrences(of: ",", with: ".")
    }
}
