# Recording module

Screen recording (MP4 / GIF), trim editor and Recording Studio. macOS 14+, ScreenCaptureKit + AVFoundation.
Author: Gürkan Fikret Günak — masterfabric.co. Self-contained; `swiftc -typecheck` clean on its own.

## Public API

| Type | Purpose |
|---|---|
| `RecordingManager` (`ObservableObject`, @MainActor) | `start(RecordingConfig)` (runs countdown), `pause()`, `resume()`, `togglePause()`, `stop() -> RecordingResult`, `cancel()`; `@Published state`, `elapsed`; `onFinished` |
| `RecordingConfig` | `target` (`.display(id)`, `.area(display:rect:)` — rect in display-local points, **top-left origin**, `.window(id)`), `format` (.mp4/.gif), `fps`, `retina`, `systemAudio`, `microphone`/`microphoneDeviceID`, `showClicks`, `showKeystrokes`, `countdown`, `includedWindowIDs`, `excludedWindowIDs`, `outputURL` |
| `RecordingStudio` + `RecordingStudioView` | Studio UI/model: window/display pick, webcam bubble, layout presets, mic, countdown, floating HUD, `onFinished` |
| `RecordingControlsView(manager:)` | Timer + pause/stop; embed in menu bar popover or use via the HUD |
| `CameraBubbleController`, `CameraLayoutPreset`, `CameraBubbleShape` | Movable/resizable webcam bubble (drag, scroll/pinch, right-click sizes) |
| `InputOverlayController.shared` | Click rings + keystroke HUD (managed by the manager; usable alone) |
| `TrimEditorView`, `TrimEditorWindowController.present(url:onExported:)` | Trim editor, export trimmed MP4/GIF |
| `MediaExporter.exportMP4/exportGIF` | Programmatic trim/export |
| `CountdownOverlay.run(seconds:)` | Standalone countdown |

## Integration

```swift
let manager = RecordingManager()
manager.onFinished = { if case .success(let r) = $0 { /* add to history / Quick Access */ } }
var cfg = RecordingConfig(target: .area(display: displayID, rect: rectInDisplayPointsTopLeft))
cfg.microphone = true; cfg.showClicks = true; cfg.countdown = 3
try await manager.start(cfg)          // later: try await manager.stop()

// Studio window
let studio = RecordingStudio()
studio.onFinished = { TrimEditorWindowController.present(url: $0.url) }
NSHostingController(rootView: RecordingStudioView(studio: studio))
```

Area capture: the Capture module's selection is in Cocoa screen coordinates (bottom-left origin); convert to display-local, top-left origin: `y = screen.frame.height - (rect.maxY - screen.frame.minY)`, `x = rect.minX - screen.frame.minX`.

## Required Info.plist / entitlements (lead)
- `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`; Screen Recording is requested via `CGRequestScreenCaptureAccess`.
- Sandbox (if enabled): `com.apple.security.device.camera`, `com.apple.security.device.audio-input`, and a writable output location (default `~/Movies/MasterFabric Cut`; set `outputURL` otherwise).
- Keystroke display needs Input Monitoring for events in other apps (prompted via `CGRequestListenEventAccess`); click rings need nothing.

## Behaviour notes
- Mic and system audio are written as separate AAC tracks, then mixed into one automatically on stop (`MediaExporter.mixAudioIfNeeded`).
- GIF: records silently to a temp MP4, then converts (≤15 fps, ≤800 px wide).
- Webcam bubble / click overlays are real windows. Display/area targets capture them naturally; window targets switch to a display crop of the window's frame so they are included (bubble must lie inside the window frame; crop does not follow the window if moved).
- HUD and countdown windows use `sharingType = .none` so they never appear in recordings.
- Pause drops frames/audio and closes the timeline gap, so the output has no frozen section.
