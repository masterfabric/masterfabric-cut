// MasterFabric Cut — Capture module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import Vision

public enum OCRService {
    /// Recognize text in an image. `languages` are BCP-47 codes; nil = automatic detection.
    public static func recognize(in image: CGImage, languages: [String]? = nil) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if let languages { request.recognitionLanguages = languages } else { request.automaticallyDetectsLanguage = true }
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                throw CaptureError.ocrFailed(error.localizedDescription)
            }
            let observations = (request.results ?? []).sorted {
                // top-to-bottom, then left-to-right (Vision origin is bottom-left)
                abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01
                    ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
            }
            return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }

    @MainActor public static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
