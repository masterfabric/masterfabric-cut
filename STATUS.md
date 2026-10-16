# STATUS

Build: `xcodegen generate && xcodebuild -project MasterFabricCut.xcodeproj -scheme MasterFabricCut -configuration Debug -derivedDataPath build build` — **succeeds** (Xcode 26.4, macOS 14 target). The app launches as a menu bar item.

## Implemented (compiles; wired in `AppCoordinator`)
- Menu bar app (LSUIElement; custom SwiftUI dropdown panel, see below), configurable global hotkeys (Carbon), Preferences (General, Shortcuts, Output, Format, Quick Access, Recording), About window with author credit, Info.plist copyright/usage strings, entitlements.
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

## Capture errors & permissions (fix round)
Unified log for the app showed no app-level errors (only system AppIntents/XPC noise); the user-visible failures were code-path ones:
- **Screen Recording not granted → raw "Screen Recording permission is required…" alert** (area/window/fullscreen/scrolling/OCR), repeated every attempt, and `CGRequestScreenCaptureAccess` was fired on every hotkey. Same raw text in Recording Studio (`refresh()` swallowed any error into the permission string) and recording start.
- `SCShareableContent` throwing `SCStreamError.userDeclined` (-3801) surfaced as a raw NSError.
- Raw `localizedDescription` / `NSAlert(error:)` leaked from Studio, Trim editor, annotation Save.
Fixes: `Sources/Shared/PermissionOnboarding.swift` — `ErrorPresenter` (maps every error to friendly copy, logs the raw one, ignores cancellation) and a `PermissionOnboarding` window (3 steps, opens the Screen Recording pane, calls `CGRequestScreenCaptureAccess` once on button press, polls for the grant, auto-retries the last capture/recording, "Restart App" fallback). Shown at launch when access is missing. SCK -3801 is mapped to `permissionDenied`.
- **Signing / TCC:** no code-signing identity exists on this machine (`security find-identity -v -p codesigning` → 0), so debug builds are ad-hoc signed and macOS drops the Screen Recording grant after every rebuild. Workarounds: create a free "Apple Development" certificate in Xcode (Settings › Accounts) and set `CODE_SIGN_IDENTITY`/`DEVELOPMENT_TEAM` in `project.yml`, or after a rebuild run `tccutil reset ScreenCapture com.masterfabric.cut` and re-grant via the onboarding window.
- Not verified end-to-end in this sandbox: actual capture after grant (needs the permission + UI input). Build + launch verified.

## Menu bar dropdown redesign
`Sources/App/MenuBarPanel.swift`: borderless rounded (r=22) material panel under the status item replacing `NSMenu`: header (app name, REC badge), sections Capture / Record / Tools / History, tinted SF Symbol tiles, title + gray description, right-aligned shortcut hints, recent-captures thumbnail row (opens the file), hover highlight, Preferences/About/Quit footer, Esc/outside-click dismiss, live Stop/Pause rows while recording.

## Onboarding + floating launcher
- `Sources/App/OnboardingWindow.swift`: material window (680x560), spring page transitions, page dots. Steps: Welcome (app name + author credit) → Permissions (Screen Recording, Camera, Microphone, Accessibility; live status badges polled every 1s; "Grant" first, then "Open System Settings" deep links) → 5 Tips & Tricks pages (shortcuts, Quick Access, Annotate, Pin, Recording Studio) → "Get Started". Completion persisted as `onboardingCompleted`; shown on first launch, reopen via menu bar "Welcome & Permissions". The older Screen Recording-only window now only auto-shows at launch after onboarding is complete.
- `Sources/App/FloatingLauncher.swift`: always-on-top, all-Spaces circular button, default bottom-right, draggable (position persisted, click vs drag threshold 4pt), toggle in Preferences › General ("Show floating launcher button"). Click opens a rounded material palette (2-column grid: Capture Area/Window/Fullscreen/Scrolling, OCR Text, Record Screen/GIF, Recording Studio, Pin Last, History) with icon tile, title, description, shortcut hint, hover highlight; Esc/outside click dismisses; action runs 0.15s after dismissal.
- Not verified visually (screenshots blocked in sandbox): build + launch only. Accessibility/Screen Recording report only granted/not-granted (no "denied" state from macOS), so their button goes Grant → Open System Settings.
