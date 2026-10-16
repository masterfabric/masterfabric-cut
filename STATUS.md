# STATUS

Build: `xcodegen generate && xcodebuild -project MasterFabricCut.xcodeproj -scheme MasterFabricCut -configuration Debug -derivedDataPath build build` — **succeeds** (Xcode 26.4, macOS 14 target). The app launches as a menu bar item.

## Implemented (compiles; wired in `AppCoordinator`)
- Menu bar app (LSUIElement), configurable global hotkeys (Carbon), Preferences (General, Shortcuts, Output, Format, Quick Access, Recording), About window with author credit, Info.plist copyright/usage strings, entitlements.
- Capture: area/window/fullscreen/previous area, crosshair + magnifier + dimensions, self-timer, scrolling capture, OCR (Vision), hide desktop icons.
- Annotate: editor (arrows, shapes, text, highlighter, blur/pixelate, steps, crop, background/padding, spotlight), Quick Access overlay (copy/save/annotate/pin/drag/close), pinned screenshots, history.
- Recording: area recording to MP4/GIF with mic + system audio, click/keystroke overlays, pause/resume (menu bar), trim editor opens after MP4 recording; Recording Studio (window/display + webcam bubble, layouts, mic, countdown, export).

## Caveats / stubbed
- **Not fully runtime-tested**: build + launch smoke test only; synthetic keystrokes/screenshots are blocked in the dev sandbox, so capture → Quick Access flows were not exercised end-to-end. Verify visually.
- Recording-time controls are menu bar items (Stop/Pause); no floating HUD for the non-Studio recorder.
- Screen/GIF recording hotkeys always start with an area selection (no window/fullscreen choice outside Studio).
- Preferences' Output format/save folder is mirrored into Quick Access; the editor's Save… always uses a save panel.
- No app icon asset; menu bar uses the SF Symbol `scissors`. Unsigned ad-hoc build ("-"), no notarization.
- Self-timer applies a countdown to area capture only.

## Integration fix applied
- Renamed a duplicate `CGRect.area` extension in Recording (`overlapArea`) that collided with Capture's.

## Crash fix (reports in `.agents/crash/*.ips`)
- All 3 reports: `EXC_BAD_ACCESS` in `objc_release` during `NSAutoreleasePool drain` on the main thread (no app frames) = over-released AppKit object.
- Root cause: capture overlay `OverlayWindow` (and the self-timer HUD, Preferences/About/Studio windows) kept the NSWindow default `isReleasedWhenClosed = true` under ARC, so `close()` released the window a second time; additionally the overlay was closed synchronously from inside its own view's mouseUp handler. Fixed: `isReleasedWhenClosed = false` everywhere, overlay windows are ordered out immediately and closed/deallocated on the next run loop turn with delegates cleared.
- Quick Access panels likewise retained until slide-out ends, closed outside event handlers.

## Quick Access (CleanShot X-style)
- Bottom-left (configurable) stack of rounded (continuous, r=20) material cards with layered shadow, spring slide-in from the edge, slide/fade-out, stack re-layout animation, hover scale + scrim, Copy/Save pills + Close/Pin/Annotate round buttons, live hover hint text + `.help` tooltips, drag-out (file URL, rounded drag preview), context menu, auto-dismiss timer paused on hover, max 5 stacked.

## UI polish
- Tooltips on menu bar items, annotate toolbar/sidebar, Recording Studio, trim editor and every Preferences control; hover states on toolbar buttons; SF Symbols on editor actions.
