# STATUS

Build: `xcodegen generate && xcodebuild -project MasterFabricCut.xcodeproj -scheme MasterFabricCut -configuration Debug -derivedDataPath build build` — **succeeds** (Xcode 26.4, macOS 14 target). The app launches as a menu bar item.

## Implemented (compiles; wired in `AppCoordinator`)
- Menu bar app (LSUIElement), configurable global hotkeys (Carbon), Preferences (General, Shortcuts, Output, Format, Quick Access, Recording), About window with author credit, Info.plist copyright/usage strings, entitlements.
- Capture: area/window/fullscreen/previous area, crosshair + magnifier + dimensions, self-timer, scrolling capture, OCR (Vision), hide desktop icons.
- Annotate: editor (arrows, shapes, text, highlighter, blur/pixelate, steps, crop, background/padding, spotlight), Quick Access overlay (copy/save/annotate/pin/drag/close), pinned screenshots, history.
- Recording: area recording to MP4/GIF with mic + system audio, click/keystroke overlays, pause/resume (menu bar), trim editor opens after MP4 recording; Recording Studio (window/display + webcam bubble, layouts, mic, countdown, export).

## Caveats / stubbed
- **Not runtime-tested**: only build + launch smoke test was done; capture, recording and editor flows have not been exercised with real permissions. Expect bugs.
- Recording-time controls are menu bar items (Stop/Pause); no floating HUD for the non-Studio recorder.
- Screen/GIF recording hotkeys always start with an area selection (no window/fullscreen choice outside Studio).
- Preferences' Output format/save folder is mirrored into Quick Access; the editor's Save… always uses a save panel.
- No app icon asset; menu bar uses the SF Symbol `scissors`. Unsigned ad-hoc build ("-"), no notarization.
- Self-timer applies a countdown to area capture only.

## Integration fix applied
- Renamed a duplicate `CGRect.area` extension in Recording (`overlapArea`) that collided with Capture's.
