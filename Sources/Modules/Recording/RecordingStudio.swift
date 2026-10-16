import SwiftUI
import AppKit
import AVFoundation
import ScreenCaptureKit

public struct StudioWindowInfo: Identifiable, Hashable {
    public let id: CGWindowID
    public let title: String
    public let app: String
    /// Global frame, top-left origin.
    public let frame: CGRect
    public var label: String { title.isEmpty ? app : "\(app) — \(title)" }
}

public struct StudioDisplayInfo: Identifiable, Hashable {
    public let id: CGDirectDisplayID
    public let name: String
    public let size: CGSize
}

/// Recording Studio: pick window/display, optional webcam bubble, mic, countdown, pause/resume, export.
@MainActor
public final class RecordingStudio: ObservableObject {
    public enum SourceKind: String, CaseIterable, Identifiable {
        case window = "Window", display = "Display"
        public var id: String { rawValue }
    }

    public let manager = RecordingManager()
    public let bubble = CameraBubbleController()

    @Published public var sourceKind: SourceKind = .display
    @Published public var windows: [StudioWindowInfo] = []
    @Published public var displays: [StudioDisplayInfo] = []
    @Published public var selectedWindowID: CGWindowID?
    @Published public var selectedDisplayID: CGDirectDisplayID?

    @Published public var cameras: [AVCaptureDevice] = []
    /// nil = no webcam.
    @Published public var selectedCameraID: String?
    @Published public var microphones: [AVCaptureDevice] = []
    /// nil = no microphone.
    @Published public var selectedMicID: String?
    @Published public var systemAudio = false
    @Published public var layout: CameraLayoutPreset = .bottomRight {
        didSet { if bubble.isVisible, let c = containerRect() { bubble.apply(preset: layout, in: c) } }
    }
    @Published public var bubbleShape: CameraBubbleShape = .circle { didSet { bubble.shape = bubbleShape } }
    @Published public var mirrorCamera = true { didSet { bubble.mirrored = mirrorCamera } }
    @Published public var countdown = 3
    @Published public var showClicks = true
    @Published public var showKeystrokes = false
    @Published public var errorMessage: String?
    @Published public private(set) var lastResult: RecordingResult?

    /// Called when a recording finishes (e.g. open the trim editor / Quick Access).
    public var onFinished: ((RecordingResult) -> Void)?
    public let hud = RecordingHUDController()

    public init() {
        manager.onFinished = { [weak self] result in
            guard let self else { return }
            self.bubble.hide()
            self.hud.hide()
            switch result {
            case .success(let r): self.lastResult = r; self.onFinished?(r)
            case .failure(let e): if case RecordingError.cancelled = e {} else { self.errorMessage = e.localizedDescription }
            }
        }
    }

    // MARK: Sources

    public func refresh() async {
        cameras = CameraBubbleController.videoDevices()
        microphones = RecordingManager.microphones()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let me = Bundle.main.bundleIdentifier
            windows = content.windows
                .filter { $0.windowLayer == 0 && $0.frame.width > 120 && $0.frame.height > 80
                    && $0.owningApplication?.bundleIdentifier != me }
                .map { StudioWindowInfo(id: $0.windowID, title: $0.title ?? "",
                                        app: $0.owningApplication?.applicationName ?? "App", frame: $0.frame) }
            displays = content.displays.map {
                StudioDisplayInfo(id: $0.displayID, name: Self.name(of: $0.displayID),
                                  size: CGSize(width: $0.width, height: $0.height))
            }
            if selectedWindowID == nil || !windows.contains(where: { $0.id == selectedWindowID }) { selectedWindowID = windows.first?.id }
            if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) { selectedDisplayID = displays.first?.id }
        } catch {
            errorMessage = RecordingError.screenPermissionDenied.localizedDescription
        }
    }

    // MARK: Session

    public func start() async {
        errorMessage = nil
        guard let target = currentTarget() else { errorMessage = "Choose a window or display."; return }
        var cfg = RecordingConfig(target: target)
        cfg.format = .mp4
        cfg.systemAudio = systemAudio
        cfg.microphone = selectedMicID != nil
        cfg.microphoneDeviceID = selectedMicID
        cfg.showClicks = showClicks
        cfg.showKeystrokes = showKeystrokes
        cfg.countdown = countdown
        cfg.excludedWindowIDs = hud.windowID.map { [$0] } ?? []

        do {
            if showKeystrokes && !InputOverlayController.hasInputMonitoringAccess {
                InputOverlayController.requestInputMonitoringAccess()
            }
            if selectedCameraID != nil {
                guard await CameraBubbleController.requestAccess() else { throw RecordingError.cameraPermissionDenied }
                guard let c = containerRect() else { throw RecordingError.targetNotFound }
                bubble.shape = bubbleShape
                bubble.mirrored = mirrorCamera
                try bubble.show(cameraID: selectedCameraID, preset: layout, in: c)
                if let id = bubble.windowID { cfg.includedWindowIDs = [id] }
                try? await Task.sleep(nanoseconds: 400_000_000) // let the camera warm up
            }
            hud.show(manager: manager)
            cfg.excludedWindowIDs = hud.windowID.map { [$0] } ?? []
            try await manager.start(cfg)
        } catch {
            bubble.hide(); hud.hide()
            if case RecordingError.cancelled = error { return }
            errorMessage = error.localizedDescription
        }
    }

    public func stop() async {
        do { try await manager.stop() } catch {
            if case RecordingError.cancelled = error { bubble.hide(); hud.hide() }
            else { errorMessage = error.localizedDescription }
        }
    }

    public func cancel() { manager.cancel(); bubble.hide(); hud.hide() }

    // MARK: Geometry

    private func currentTarget() -> RecordingTarget? {
        switch sourceKind {
        case .window: return selectedWindowID.map { .window($0) }
        case .display: return selectedDisplayID.map { .display($0) }
        }
    }

    /// Recorded region in Cocoa (bottom-left origin) screen coordinates.
    private func containerRect() -> CGRect? {
        switch sourceKind {
        case .display:
            guard let id = selectedDisplayID else { return nil }
            return Self.screen(for: id)?.frame
        case .window:
            guard let w = windows.first(where: { $0.id == selectedWindowID }) else { return nil }
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(x: w.frame.minX, y: primaryH - w.frame.maxY, width: w.frame.width, height: w.frame.height)
        }
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    static func name(of id: CGDirectDisplayID) -> String {
        screen(for: id)?.localizedName ?? "Display \(id)"
    }
}

// MARK: - HUD (excluded from capture)

/// Small floating Pause/Stop control with timer. Hidden from screen capture.
@MainActor
public final class RecordingHUDController {
    private var panel: NSPanel?
    public var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    public init() {}

    public func show(manager: RecordingManager) {
        hide()
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 240, height: 48),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.sharingType = .none
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: RecordingControlsView(manager: manager))
        if let s = NSScreen.main {
            p.setFrameOrigin(CGPoint(x: s.visibleFrame.midX - 120, y: s.visibleFrame.maxY - 70))
        }
        p.orderFrontRegardless()
        panel = p
    }

    public func hide() { panel?.orderOut(nil); panel = nil }
}

/// Timer + pause/resume + stop. Usable standalone (e.g. in the menu bar popover).
public struct RecordingControlsView: View {
    @ObservedObject var manager: RecordingManager
    public init(manager: RecordingManager) { self.manager = manager }

    public var body: some View {
        HStack(spacing: 12) {
            Circle().fill(manager.state == .paused ? Color.orange : Color.red).frame(width: 10, height: 10)
            Text(time(manager.elapsed)).font(.system(.body, design: .monospaced)).foregroundStyle(.white)
            Spacer()
            Button { manager.togglePause() } label: {
                Image(systemName: manager.state == .paused ? "play.fill" : "pause.fill")
            }.buttonStyle(.plain).foregroundStyle(.white)
            Button { Task { try? await manager.stop() } } label: {
                Image(systemName: "stop.fill")
            }.buttonStyle(.plain).foregroundStyle(.red)
        }
        .padding(.horizontal, 16)
        .frame(width: 240, height: 48)
        .background(Capsule().fill(Color.black.opacity(0.85)))
    }

    private func time(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: - Studio view

public struct RecordingStudioView: View {
    @ObservedObject var studio: RecordingStudio
    public init(studio: RecordingStudio) { self.studio = studio }

    public var body: some View {
        Form {
            Section("Source") {
                Picker("Record", selection: $studio.sourceKind) {
                    ForEach(RecordingStudio.SourceKind.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                if studio.sourceKind == .window {
                    Picker("Window", selection: $studio.selectedWindowID) {
                        ForEach(studio.windows) { Text($0.label).tag(Optional($0.id)) }
                    }
                } else {
                    Picker("Display", selection: $studio.selectedDisplayID) {
                        ForEach(studio.displays) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            }
            Section("Camera") {
                Picker("Webcam", selection: $studio.selectedCameraID) {
                    Text("None").tag(String?.none)
                    ForEach(studio.cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
                if studio.selectedCameraID != nil {
                    Picker("Layout", selection: $studio.layout) {
                        ForEach(CameraLayoutPreset.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Shape", selection: $studio.bubbleShape) {
                        ForEach(CameraBubbleShape.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Mirror camera", isOn: $studio.mirrorCamera)
                    Text("Drag the bubble to move it; scroll or pinch on it to resize; right-click for sizes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Audio") {
                Picker("Microphone", selection: $studio.selectedMicID) {
                    Text("None").tag(String?.none)
                    ForEach(studio.microphones, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
                Toggle("System audio", isOn: $studio.systemAudio)
            }
            Section("Options") {
                Picker("Countdown", selection: $studio.countdown) {
                    Text("Off").tag(0); Text("3 s").tag(3); Text("5 s").tag(5); Text("10 s").tag(10)
                }
                Toggle("Show clicks", isOn: $studio.showClicks)
                Toggle("Show keystrokes", isOn: $studio.showKeystrokes)
            }
            if let e = studio.errorMessage { Text(e).foregroundStyle(.red) }
            HStack {
                Button("Refresh") { Task { await studio.refresh() } }
                Spacer()
                if studio.manager.state.isActive || studio.manager.state == .countdown {
                    Button("Stop") { Task { await studio.stop() } }
                } else {
                    Button("Start Recording") { Task { await studio.start() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(studio.manager.state == .finishing)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 520)
        .task { await studio.refresh() }
    }
}
