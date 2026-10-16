# Capture module — MasterFabric Cut

Author: Gürkan Fikret Günak · masterfabric.co. Requires macOS 14+; links ScreenCaptureKit, Vision, Carbon, AppKit.

## Files
| File | Purpose |
|---|---|
| `CaptureTypes.swift` | `CaptureMode`, `CaptureResult`, `CaptureError`, `WindowInfo`, `CapturePermissions`, `NSScreen` helpers |
| `ScreenCaptureService.swift` | SCScreenshotManager capture: `captureRect`, `captureFullscreen`, `captureWindow`, `listWindows` |
| `SelectionOverlay.swift` | Crosshair overlay per screen, magnifier, live W×H, window picking (Space toggles area/window, Esc cancels) |
| `ScrollingCapture.swift` | Auto-scroll + overlap stitching |
| `SelfTimer.swift` | Countdown HUD |
| `OCRService.swift` | Vision text recognition + pasteboard copy |
| `DesktopIconsManager.swift` | Hide/show Finder desktop icons |
| `HotkeyManager.swift` | `CaptureAction`, `HotkeyBinding` (Codable), Carbon global hotkeys with persistence |
| `CaptureCoordinator.swift` | Public façade used by the shell |

## Integration
```swift
let capture = CaptureCoordinator()
capture.onCapture = { result in /* result.image (CGImage), .nsImage, .scale, .rect, .mode → Quick Access overlay */ }
capture.onText    = { text, shot in /* show toast */ }
capture.onError   = { error in /* alert */ }
capture.selfTimerSeconds = 5                 // from Preferences; 0 = off
capture.hideDesktopIconsDuringCapture = true // optional

HotkeyManager.shared.start { action in
    capture.perform(action)                  // capture actions + toggleDesktopIcons
    // recordScreen / recordGIF / openStudio / openHistory: handle in the shell
}
// Preferences › Shortcuts:
HotkeyManager.shared.register(.captureArea, binding: HotkeyBinding(event: recordedNSEvent))
HotkeyManager.shared.resetToDefaults()
```
Menu items call `capture.perform(.captureArea)` etc. (or the `async` methods directly). `HotkeyBinding.displayString` gives "⌃⇧⌘4" for UI.

## Permissions / Info.plist / entitlements
- **Screen Recording** — prompted automatically (`CGRequestScreenCaptureAccess`); add `NSScreenCaptureUsageDescription`-style text in Info.plist.
- **Accessibility** — only for scrolling capture (posting scroll events); `CapturePermissions.requestAccessibility()`.
- `DesktopIconsManager` shells out to `defaults`/`killall`, so the app must be **non-sandboxed** (or ignore this feature).
- Global hotkeys use Carbon `RegisterEventHotKey` — no extra permission.

## Notes
- All rects are in global AppKit coordinates (origin bottom-left); `CaptureResult.rect` too. Previous area is persisted in `UserDefaults`.
- Own-app windows (Quick Access, overlays) are excluded from captures (`service.excludeOwnApp`).
- Window shadow: `service.includeWindowShadow`; cursor: `service.showsCursor`.
- Scrolling capture: `ScrollingCapture` stops at end of content, at `maxFrames`, or on Esc / `coordinator.stopScrolling()`. Sticky headers/footers may cause imperfect stitches.
- Type-checks cleanly with `swiftc -typecheck -target arm64-apple-macos14.0 *.swift`; not yet exercised at runtime.
