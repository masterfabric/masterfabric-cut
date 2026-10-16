# MasterFabric Cut

A native macOS menu bar app (Swift, SwiftUI + AppKit, ScreenCaptureKit, AVFoundation, Vision) that mirrors
the CleanShot X feature set and adds a **Recording Studio** mode.

Author: **Gürkan Fikret Günak** — [MasterFabric](https://masterfabric.co). Bundle id `co.masterfabric.cut`, macOS 14+. MIT licensed.

## Build

```sh
brew install xcodegen          # once
xcodegen generate              # creates MasterFabricCut.xcodeproj from project.yml
xcodebuild -project MasterFabricCut.xcodeproj -scheme MasterFabricCut -configuration Debug -derivedDataPath build build
open "build/Build/Products/Debug/MasterFabric Cut.app"
```

On first use grant **Screen Recording** (and Camera / Microphone / Accessibility for scrolling capture) in System Settings › Privacy & Security.
The app is not sandboxed (needed for hiding desktop icons and global capture).

## Layout

| Path | Contents |
|---|---|
| `Sources/App` | App entry, menu bar, `AppCoordinator` (wires modules), Preferences, About, Info.plist, entitlements |
| `Sources/Shared` | `AppSettings` (UserDefaults), file output helpers |
| `Sources/Modules/Capture` | Area/window/fullscreen/previous capture, magnifier, scrolling, OCR, timer, hotkeys |
| `Sources/Modules/Annotate` | Annotation editor, Quick Access overlay, pins, history |
| `Sources/Modules/Recording` | Screen recording MP4/GIF, trim editor, Recording Studio, webcam bubble |

Each module has its own README with its API. See `STATUS.md` for what is implemented and what is not.
