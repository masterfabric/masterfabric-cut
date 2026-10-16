import AppKit

/// Single entry point for the Annotate module. All methods must be called on the main thread.
final class AnnotateModule {
    static let shared = AnnotateModule()

    let quickAccess = QuickAccessOverlayController.shared
    let pins = PinnedScreenshotController.shared
    let history = CaptureHistoryStore.shared

    /// Handle a freshly captured screenshot: add it to history and show the Quick Access overlay.
    /// - Parameters:
    ///   - fileURL: where the capture was already saved, if the Capture module wrote it to disk.
    func handleCapture(_ image: NSImage, fileURL: URL? = nil,
                       addToHistory: Bool = true, showQuickAccess: Bool = true) {
        if addToHistory { history.addScreenshot(image) }
        if showQuickAccess { quickAccess.show(image: image, fileURL: fileURL) }
    }

    /// Register a finished recording (MP4/MOV) or GIF in the history.
    func handleRecording(at url: URL, isGIF: Bool = false) {
        history.addFile(at: url, kind: isGIF ? .gif : .recording)
    }

    func handleOCRText(_ text: String) {
        history.addOCRText(text)
    }

    func openEditor(image: NSImage, sourceURL: URL? = nil) {
        AnnotationEditorWindowController.open(image: image, sourceURL: sourceURL,
                                              onSaved: { [weak self] _ in _ = self })
    }

    func openEditor(fileURL: URL) {
        guard let image = NSImage(contentsOf: fileURL) else { return }
        openEditor(image: image, sourceURL: fileURL)
    }

    func pin(image: NSImage) {
        pins.pin(image: image)
    }

    func showHistory() {
        CaptureHistoryWindowController.shared.show()
    }
}
