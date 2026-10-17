# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
