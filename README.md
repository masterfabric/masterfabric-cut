# MasterFabric Cut

A native macOS menu bar app (Swift, SwiftUI + AppKit, ScreenCaptureKit, AVFoundation, Vision) that mirrors
the CleanShot X feature set and adds a **Recording Studio** mode.

Author: **Gürkan Fikret Günak** — [MasterFabric](https://masterfabric.co). Bundle id `com.masterfabric.cut`, macOS 14+. MIT licensed.

## Build

```sh
brew install xcodegen          # once
xcodegen generate              # creates MasterFabricCut.xcodeproj from project.yml
xcodebuild -project MasterFabricCut.xcodeproj -scheme MasterFabricCut -configuration Debug -derivedDataPath build build
open "build/Build/Products/Debug/MasterFabric Cut.app"
```

On first use grant **Screen Recording** (and Camera / Microphone / Accessibility for scrolling capture) in System Settings › Privacy & Security.
The app is not sandboxed (needed for hiding desktop icons and global capture).

### Permissions & rebuilds

Debug builds are **ad-hoc signed** (no Developer ID / Apple Development identity), so macOS ties each TCC grant
(Screen Recording, Camera, …) to the binary's hash. **Every rebuild invalidates the grant and you must re-grant it**
until the app is signed with a stable identity (set `CODE_SIGN_IDENTITY` / `DEVELOPMENT_TEAM` in `project.yml`).
To reset a stale entry: `tccutil reset ScreenCapture com.masterfabric.cut`.

macOS also only applies a new Screen Recording grant after the app is relaunched. The permission window therefore:
checks status with `CGPreflightScreenCaptureAccess` plus a `SCShareableContent` probe, calls
`CGRequestScreenCaptureAccess` once per launch (never in a loop), opens the Screen Recording pane, polls for the
grant, and offers a **Restart MasterFabric Cut** button that relaunches the app.

## Layout

| Path | Contents |
|---|---|
| `Sources/App` | App entry, menu bar, `AppCoordinator` (wires modules), Preferences, About, Info.plist, entitlements |
| `Sources/Shared` | `AppSettings` (UserDefaults), file output helpers |
| `Sources/Modules/Capture` | Area/window/fullscreen/previous capture, magnifier, scrolling, OCR, timer, hotkeys |
| `Sources/Modules/Annotate` | Annotation editor, Quick Access overlay, pins, history |
| `Sources/Modules/Recording` | Screen recording MP4/GIF, trim editor, Recording Studio, webcam bubble |

Each module has its own README with its API. See `STATUS.md` for what is implemented and what is not.
