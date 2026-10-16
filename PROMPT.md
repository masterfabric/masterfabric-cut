Build "MasterFabric Cut", a native macOS app written entirely in Swift (SwiftUI + AppKit, ScreenCaptureKit, AVFoundation, Vision). Author: Gürkan Fikret Günak, MasterFabric (masterfabric.co) — in About window, Info.plist copyright, README, LICENSE. Bundle id: co.masterfabric.cut. macOS 14+.

Goal: a 1:1 functional clone of CleanShot X (https://cleanshot.com/), plus a "Recording Studio" mode.

CleanShot X parity (menu bar app): capture area/window/fullscreen/previous area with crosshair, magnifier, dimensions; configurable global hotkeys; Quick Access Overlay thumbnail (copy, save, annotate, pin, drag out, close); annotation editor (arrows, shapes, text, highlighter, blur/pixelate, numbered steps, crop, background/padding, spotlight); scrolling capture; OCR text capture; self-timer; hide desktop icons; pin screenshots floating; screen recording video + GIF with mic/system audio, show clicks/keystrokes, trim; capture history; Preferences (general, shortcuts, output, format, quick access).

Recording Studio: pick a specific window or display + webcam; camera as movable/resizable bubble overlay; layout presets; mic selection; countdown; pause/resume; simple trim editor; export MP4 — fast, studio-like.

Requirements: Xcode project buildable with xcodebuild (use XcodeGen project.yml if helpful), entitlements and privacy usage strings (screen recording, camera, mic), modular clean architecture, README with build steps. Build with xcodebuild and fix all errors until it compiles. Commit progress with git regularly. At the end write STATUS.md: implemented, stubbed, how to build.
