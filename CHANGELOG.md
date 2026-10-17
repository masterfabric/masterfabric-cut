# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Capture History media player: GIF cards animate on hover and show a play badge, recordings show a play badge and duration. Double-click or Open launches a soft material player window: GIFs get play/pause, loop toggle, a frame scrubber and frame/size info; videos use the standard AVKit controls. Both have Copy, Save As…, Reveal in Finder and Delete.
- Annotation editor "Window Frame" row of live thumbnail swatches (your screenshot inside each style, with hover tooltips): macOS Light, macOS Dark, Safari-style browser with address bar, Minimal rounded frame, frosted Glass on a mesh gradient, and Terminal. Each style sets a matching backdrop, and every one has adjustable padding, corner radius, shadow size, background color/gradient and optional window title text.
- Custom backdrop colors: color pickers with a gradient toggle next to the preset chips.

### Fixed
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
