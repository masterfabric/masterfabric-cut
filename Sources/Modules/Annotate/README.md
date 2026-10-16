# Annotate module

Annotation editor, Quick Access Overlay, pinned screenshots and capture history for MasterFabric Cut.
Pure AppKit + SwiftUI, macOS 14+, no external dependencies. Every file in this folder is compile-ready
(type-checked with `swiftc -typecheck`); add the folder to the app target. Call everything on the main thread.

## Integration (the lead agent's checklist)

```swift
// After a screenshot is captured (Capture module):
AnnotateModule.shared.handleCapture(image, fileURL: savedURL)   // history + Quick Access overlay

// After a recording/GIF finishes (Recording module):
AnnotateModule.shared.handleRecording(at: url, isGIF: false)

// After OCR:
AnnotateModule.shared.handleOCRText(text)

// Menu bar items:
AnnotateModule.shared.showHistory()
AnnotateModule.shared.pin(image: image)                 // pin clipboard / last capture
AnnotateModule.shared.openEditor(fileURL: url)          // or openEditor(image:sourceURL:)
```

Preferences hooks (Quick Access tab / Output tab):

```swift
let qa = QuickAccessOverlayController.shared
qa.configuration.position = .bottomLeft      // .bottomRight / .topLeft / .topRight
qa.configuration.autoCloseDelay = 8          // 0 = never
qa.configuration.saveDirectory = url
qa.configuration.format = .png               // .jpeg / .tiff
qa.configuration.filenamePrefix = "MasterFabric Cut"
qa.onSaved = { url in ... }                  // fired on Save (also from editor Save…)
CaptureHistoryStore.shared.maxItems = 200
```

## Files

| File | Purpose |
|---|---|
| `AnnotateModule.swift` | Facade (`AnnotateModule.shared`). |
| `AnnotationModel.swift` | `AnnotationTool`, `AnnotationItem`, `BackgroundSettings`, `AnnotationDocument` (state, undo/redo, crop). |
| `AnnotationRenderer.swift` | CoreGraphics/CoreImage renderer shared by canvas and export (arrows, shapes, text, highlighter, pencil, blur, pixelate, steps, spotlight, background/padding/shadow). |
| `AnnotationCanvasView.swift` | Interactive `NSView` + SwiftUI wrapper (draw, select/move, delete, crop, Shift-constrain, undo shortcuts). |
| `AnnotationEditorView.swift` | Toolbar/sidebar UI and `AnnotationEditorWindowController.open(image:sourceURL:onSaved:)`. |
| `QuickAccessOverlay.swift` | Floating thumbnail stack: copy, save, annotate, pin, close, drag-out (file drag), auto-close. |
| `PinnedScreenshot.swift` | Always-on-top pins: scroll/pinch to zoom, double-click = 100%, right-click menu (opacity, copy, save, annotate), Esc closes. |
| `CaptureHistory.swift` / `CaptureHistoryView.swift` | JSON-indexed history in `~/Library/Application Support/MasterFabric Cut/History`, thumbnails, grid window. |
| `AnnotateImageUtil.swift` | Image encoding, pasteboard, unique file names. |

## Notes

- Editor coordinates are source-image pixels; line widths/fonts/padding scale with image width so retina captures look right.
- Text tool uses a modal text prompt (double-click a text item with the Select tool to edit).
- The editor's "Save…" always uses a save panel (never overwrites the original); "Done" copies to the clipboard and closes.
- Video thumbnails use `AVAssetImageGenerator.copyCGImage` (deprecated in macOS 15 SDK but functional).
- No hotkeys are registered here; the shell owns global shortcuts. No entitlements needed (save panels / Desktop writes
  need user-selected or Desktop access if sandboxed).
