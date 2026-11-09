# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Media Studio** (menu bar › Record, Utilities grid, floating palette › Record): on-device batch media processing without uploading files.
  - **Batch export** with shared trim / silence / portrait / platform profile settings applied to every queued file; originals are never overwritten.
  - **Silence removal** with adjustable threshold, min duration and padding, timeline preview, then a new export.
  - **Portrait reframe** samples Vision face boxes over time and animates the crop between those centers (AVFoundation interpolates transforms); manual fallback when no face is found. Not speaker diarization.
  - **Export profiles** for Original, YouTube, X/Twitter, LinkedIn, TikTok, Instagram Reel/Feed, plus Custom size, quality and optional target MB guidance.
  - **Captions**: Speech framework file transcription with locale availability reporting (Turkish when on-device assets exist), editable cues, SRT/VTT export; refuses cloud Speech.
  - **Processing queue** with per-job progress, cancel (without aborting siblings), retry failed, and reveal-in-Finder on success.
  - DEBUG `MFC_VALIDATE_DIR` harness generates synthetic fixtures and runs encode/queue checks into that folder.

## [0.1.3] - 2026-11-09

### Added
- General tools (menu-bar panel › Utilities grid, the floating button's palette › Tools section, and the radial menu's new **Tools** bubble; every tool has a rebindable shortcut in Settings › Shortcuts):
  - **Color Picker** (`⌃⇧⌘C`): system magnifier loupe; a click copies the color as HEX, RGB or HSL (Settings › Tools) with a swatch toast. The tool window shows every format with copy buttons and the last 16 colors.
  - **Screen Ruler**: full-screen overlay on the display under the cursor; drag to measure width, height and diagonal in points (and pixels on Retina), ⇧ snaps to horizontal/vertical, arrow keys nudge, ⌘C copies the measurement, Esc or right-click exits.
  - **OCR Translate** (TR ⇄ EN): select an area, the text is recognized on-device and translated with Apple's Translation framework (macOS 15+, offline once the language pack is installed). The direction is detected automatically or can be forced. On macOS 14 it falls back to showing the recognized text with a note.
  - **Clipboard History** (`⌃⇧⌘V`): the last 50 copied texts and images, with a searchable picker (↩ pastes into the frontmost app when Accessibility is allowed, otherwise copies; ⌥↩ copies; ⌘1–9 quick pick; ⌘⌫ removes; Esc closes). Passwords and other concealed or transient pasteboard items are never recorded. On by default; optional persistence across restarts and Clear History in Settings › Tools.
  - **Quick Notes**: small always-on-top sticky notes in six colors that save as you type and come back after a restart.
  - **Countdown Timer**: an always-on-top pill with 5/10/15/30-minute presets or a custom time, pause/resume/reset, a red warning near the end (last minute or 20%) and an optional sound when time is up.
  - **Keep Awake** (`⌃⇧⌘K`): stops the Mac (and optionally the display) from sleeping indefinitely, for 1 or 2 hours, or until the countdown ends. A small orange cup on the menu-bar icon shows it is on; the panel has quick Off/∞/1h/2h/Timer chips.
  - **Image Converter**: drop images to convert to PNG, JPG (with quality), HEIC or TIFF, optionally resized by percent or a maximum side, saved next to the originals (or a chosen folder) without overwriting. Reads WebP, GIF, BMP, TIFF, HEIC and more.
  - **Text Tools**: JSON pretty/minify/validate, Base64 encode/decode (URL-safe input accepted), URL encode/decode and case conversion (UPPER, lower, Title, camelCase, snake_case, kebab-case), all local.
- Settings › Tools pane: color copy format, clipboard history on/off, persistence and Clear History, countdown sound, Keep Awake display mode.
- Quick Help button: a floating brand squircle (on by default; toggle in the menu-bar panel › Help or Settings › General › Appearance). Hover for 2 seconds (a ring fills while you wait) or click to open a semicircular radial menu — Screenshot Area, Scrolling Capture, Record, Link to QR, Pin Image / PDF, Settings — whose arc points away from the nearest screen edge. Hover highlights a bubble, click runs it; moving away, clicking elsewhere or Esc closes it with a spring animation. Drag the button to move it; it snaps to the nearest screen edge and remembers its position. Drop an image or PDF on it to pin the file.
- Pin Image / PDF (Tools section, launcher, `⌃⇧⌘P`, drag a file onto the launcher, or Pin Clipboard): float any image (PNG, JPG, HEIC, GIF…) or PDF in a screen corner, always on top, on every Space and over full-screen apps. Hover for controls: snap to any of the four corners (or drag; it snaps to the nearest one, hold ⌥ to place freely), resize with the grip keeping the aspect ratio, opacity slider, PDF page navigation with scrolling, click-through and close. Pins stack, are listed in the menu-bar panel (reveal, click-through toggle, close, Close All) and remember the last corner, size and opacity. `⌃⇧⌘U` toggles click-through on all pins.
- Link to QR Code tool (Tools section, launcher, `⌃⇧⌘L`): paste a link (bare domains get `https://`), generate a crisp Core Image QR code, then Present it full screen — a clean white view with the QR and the link underneath, above full-screen apps on the display under the cursor; Esc, Space, Return or a click closes it. Copy image, Save PNG and Copy link included; a link on the clipboard is prefilled.
- Settings › Capture › Scrolling capture speed: Gentle (default), Normal, Fast.

### Changed
- The floating button's palette is grouped into Capture, Record, Pin & History and Tools sections (three columns), and includes Settings. The radial menu's Settings bubble became **Tools**, which opens the palette filtered to the tools (still 7 bubbles).
- The menu-bar panel grows to fit the screen (up to 780 pt) before scrolling.
- One floating button instead of two: the old circular launcher and the Quick Help squircle are merged into a single app-icon squircle. Click opens the action palette (every launcher action, as before), hovering 2 s opens the radial menu (now with an **All Actions** bubble, 7 items), dropping an image/PDF pins it, and it snaps to screen edges and remembers its position (the old launcher position is carried over). Settings › General › Appearance and the menu-bar panel have a single "Show floating button" toggle, on if either old toggle was on.
- Pinned screenshots (Quick Access, history, editor, launcher "Pin Last") now use the new pin windows with corner snapping, opacity and click-through.
- Scrolling capture is slower and smoother: each step scrolls 35% of the region as an eased stream of small continuous scroll events (~0.55 s) instead of one 60% jump, then waits until the page stops changing before grabbing the frame, giving cleaner stitches with lazy-loaded content.

### Fixed
- Permissions no longer nag on every launch: Screen Recording and Accessibility are checked silently (no prompt) and cached, the system prompt only appears after an explicit action, and onboarding is skipped when the app is already allowed. After an update macOS can keep the switch ON while ignoring the new build (ad-hoc signatures change on every build); the app now spots this and the permission sheet and Settings › Permissions offer **Reset & Ask Again**, which clears the stale entry (`tccutil reset`) and asks once more, falling back to remove/re-add instructions.
- `scripts/make-dmg.sh [tag]` builds a Release DMG and signs with `MFC_SIGN_IDENTITY` when set (a stable Apple Development / Developer ID identity keeps permissions across updates).

## [0.1.2] - 2026-10-17

### Added
- Screen recording focus dim: while recording an area or window, everything outside the recorded frame is darkened with a subtle border around it. Adjustable strength and an on/off toggle in Settings › Recording (default on); no dim for full-screen recording. The overlay is click-through, on all Spaces, and excluded from the capture.
- Recording controls pill (red dot, mm:ss timer, Pause/Resume, Stop, Restart, Cancel with tooltips) now appears for every recording, centered directly below the notch on notched displays or below the menu bar otherwise, on the screen being recorded, and is excluded from the video.
- Capture History media player: GIF cards animate on hover and show a play badge, recordings show a play badge and duration. Double-click or Open launches a soft material player window: GIFs get play/pause, loop toggle, a frame scrubber and frame/size info; videos use the standard AVKit controls. Both have Copy, Save As…, Reveal in Finder and Delete.
- Annotation editor "Window Frame" row of live thumbnail swatches (your screenshot inside each style, with hover tooltips): macOS Light, macOS Dark, Safari-style browser with address bar, Minimal rounded frame, frosted Glass on a mesh gradient, and Terminal. Each style sets a matching backdrop, and every one has adjustable padding, corner radius, shadow size, background color/gradient and optional window title text.
- Custom backdrop colors: color pickers with a gradient toggle next to the preset chips.

### Fixed
- Pausing a recording now shifts later video and audio by the exact time paused (host clock), so there is no frozen gap and audio resumes immediately even when the screen is static.
- Applying a background style distorted the layout: the preview shadow ignored the canvas scale and flip, so it differed from the exported/copied image. Shadows, backdrops and frames now render through one code path, so preview and output match.
- Annotation hit-testing and overlays stay aligned with the image after style, padding or frame changes.
- Annotation editor: choosing a window frame/background style no longer strips the toolbar, tool palette and inspector backgrounds (chrome now keeps explicit system materials; the canvas is clipped), and switching between styles, including back to None, resets cleanly, re-centers and cross-fades.

## [0.1.1] - 2026-10-17

### Changed
- Capture History window rebuilt: minimum size 860x560 and resizable, header with a native segmented filter (All, Screenshots, Recordings, GIFs, Text), search and a "Clear All…" button with confirmation.
- History grid uses adaptive 200pt cards with 12pt rounded corners, aspect-fit thumbnails, filename, relative date and a type badge; hover overlay with Open, Copy, Reveal in Finder, Pin and Delete (with tooltips), double-click to open, context menu and drag-out to other apps.
- Menu bar status item keeps the scissors SF Symbol as a template image (adapts to light/dark menu bars) with a red dot while recording.
- The full-color MasterFabric app icon now appears next to the "MasterFabric Cut" name in the menu bar panel, onboarding, Settings sidebar and About, launcher button and palette, Quick Access cards, Recording Studio and permission sheets.

### Fixed
- Capture History window content was clipped on the left edge (filter, thumbnails and dates cut off) with a large empty area.

## [0.1.0] - 2026-10-17

First public release.

### Added
- Menu bar app with a custom SwiftUI dropdown panel, configurable global hotkeys and a floating launcher with an action palette.
- Screenshot capture: area, window, fullscreen and previous area, with crosshair, magnifier and live dimensions; self-timer; scrolling capture; OCR text capture (Vision); option to hide desktop icons.
- Annotation editor: arrows, shapes, text, highlighter, blur/pixelate, numbered steps, crop, background/padding and spotlight.
- Quick Access overlay: stacked rounded cards with spring animations, Copy/Save/Annotate/Pin/Close actions, drag-out, context menu and auto-dismiss; pinned screenshots.
- Capture History window with a rounded thumbnail grid, hover actions and search, backed by a SQLite storage layer.
- Screen recording to MP4 or GIF with microphone and system audio, click and keystroke overlays, pause/resume and a trim editor.
- Recording Studio: window/display capture with a live webcam bubble, layouts, microphone selection, countdown and export.
- First-launch onboarding window and a permission onboarding flow for Screen Recording.
- Redesigned Settings window with a sidebar layout, grouped forms, live permission status and a storage pane.
- MasterFabric app icon (full macOS asset catalog), also shown in About and onboarding.
- Tooltips across the menu bar, editor, Recording Studio, trim editor and Settings.

### Changed
- Permissions are unified in a single `PermissionManager`.
- Quick Access cards are larger.
- Bundle identifier is now `com.masterfabric.cut`.

### Fixed
- Over-release crash (`EXC_BAD_ACCESS`) when closing capture overlay, timer HUD and app windows.
- Raw error alerts replaced with friendly messages; ScreenCaptureKit "user declined" (-3801) is handled as a permission problem.
- Screen Recording permission was requested on every capture attempt; it is now requested once, with polling and an automatic retry after the grant.
- Capture History window sizing.
- Live camera bubble and preview in Recording Studio.
- Duplicate `CGRect.area` extension collision between modules.

### Known issues
- Builds are ad-hoc signed and not notarized; macOS may reset the Screen Recording grant after an update.
