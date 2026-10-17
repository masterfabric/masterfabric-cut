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

    @Published public var sourceKind: SourceKind = .display { didSet { if oldValue != sourceKind { retarget() } } }
    @Published public var windows: [StudioWindowInfo] = []
    @Published public var displays: [StudioDisplayInfo] = []
    @Published public var selectedWindowID: CGWindowID? { didSet { if oldValue != selectedWindowID { retarget() } } }
    @Published public var selectedDisplayID: CGDirectDisplayID? { didSet { if oldValue != selectedDisplayID { retarget() } } }

    @Published public var cameras: [AVCaptureDevice] = []
    /// nil = no webcam.
    @Published public var selectedCameraID: String? { didSet { if oldValue != selectedCameraID { Task { await syncBubble() } } } }
    /// Show the floating camera bubble (before and during recording). Off = webcam is not recorded.
    @Published public var bubbleVisible = true { didSet { if oldValue != bubbleVisible { Task { await syncBubble() } } } }
    @Published public private(set) var cameraDenied = false
    /// Live camera session shared with the Studio preview (nil when the bubble is off).
    @Published public private(set) var previewSession: AVCaptureSession?
    @Published public private(set) var previewImage: CGImage?
    /// Bubble frame as fractions of the recorded area (top-left origin), for the preview composite.
    @Published public private(set) var bubbleRect: CGRect?
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
    private var content: SCShareableContent?
    private var studioOpen = false

    public init() {
        let prefs = AppSettings.shared
        countdown = prefs.studioCountdown
        mirrorCamera = prefs.studioMirror
        bubbleShape = CameraBubbleShape(rawValue: prefs.studioShape) ?? .circle
        showClicks = prefs.showClicks
        showKeystrokes = prefs.showKeystrokes
        manager.onFinished = { [weak self] result in
            guard let self else { return }
            self.bubble.chromeEnabled = true
            self.bubble.hide()
            Task { await self.syncBubble() }
            switch result {
            case .success(let r): self.lastResult = r; self.onFinished?(r)
            case .failure(let e): self.report(e)
            }
        }
        bubble.onFrameChange = { [weak self] _ in self?.updateBubbleRect() }
        bubble.onShapeChange = { [weak self] in self?.bubbleShape = $0 }
        bubble.onMirrorChange = { [weak self] in self?.mirrorCamera = $0 }
        bubble.onHideRequested = { [weak self] in self?.bubbleVisible = false }
    }

    // MARK: Bubble + preview

    /// Called when the Studio window opens/closes so the camera only runs while it is useful.
    public func setStudioOpen(_ open: Bool) {
        studioOpen = open
        Task { await syncBubble() }
    }

    private func retarget() {
        guard bubble.isVisible, !manager.state.isActive, let c = containerRect() else { return }
        bubble.apply(preset: layout, in: c)
        updateBubbleRect()
    }

    /// Brings the floating bubble in line with the camera / visibility settings.
    public func syncBubble() async {
        guard !manager.state.isActive, manager.state != .countdown else { return }
        guard studioOpen, let id = selectedCameraID, bubbleVisible else {
            bubble.hide(); previewSession = nil; updateBubbleRect(); return
        }
        guard await CameraBubbleController.requestAccess() else {
            cameraDenied = true; bubble.hide(); previewSession = nil; updateBubbleRect(); return
        }
        cameraDenied = false
        guard let c = containerRect(), selectedCameraID == id, bubbleVisible, studioOpen else { return }
        do {
            if bubble.isVisible {
                if bubble.cameraID != id { try bubble.switchCamera(id) }
            } else {
                bubble.shape = bubbleShape
                bubble.mirrored = mirrorCamera
                bubble.chromeEnabled = true
                try bubble.show(cameraID: id, preset: layout, in: c)
            }
            previewSession = bubble.session
        } catch {
            NSLog("MasterFabric Cut camera error: \(error)")
            errorMessage = "The camera couldn't be started. Try another camera."
            bubble.hide(); previewSession = nil
        }
        updateBubbleRect()
    }

    private func updateBubbleRect() {
        guard let f = bubble.frame, bubble.isVisible, let c = containerRect(), c.width > 0, c.height > 0 else { bubbleRect = nil; return }
        bubbleRect = CGRect(x: (f.minX - c.minX) / c.width, y: (c.maxY - f.maxY) / c.height,
                            width: f.width / c.width, height: f.height / c.height)
    }

    /// One low-res snapshot of the chosen window/display (own windows excluded) for the setup preview.
    public func capturePreview() async {
        guard studioOpen, !manager.state.isActive, PermissionManager.shared.isGranted(.screen), let content else { return }
        let filter: SCContentFilter
        let size: CGSize
        switch sourceKind {
        case .display:
            guard let id = selectedDisplayID, let d = content.displays.first(where: { $0.displayID == id }) else { return }
            let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: d, excludingApplications: own, exceptingWindows: [])
            size = CGSize(width: d.width, height: d.height)
        case .window:
            guard let id = selectedWindowID, let w = content.windows.first(where: { $0.windowID == id }) else { return }
            filter = SCContentFilter(desktopIndependentWindow: w)
            size = w.frame.size
        }
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(1, 900 / max(size.width, size.height))
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int(size.width * scale)); cfg.height = max(1, Int(size.height * scale))
        cfg.showsCursor = false
        if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { previewImage = img }
    }

    // MARK: Sources

    public func refresh() async {
        cameras = CameraBubbleController.videoDevices()
        microphones = RecordingManager.microphones()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            self.content = content
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
            updateBubbleRect()
        } catch {
            report(error)
        }
    }

    /// Friendly error surface: permission problems open the onboarding sheet, the rest become inline text.
    private func report(_ error: Error) {
        if ErrorPresenter.isCancellation(error) { return }
        if ErrorPresenter.isPermission(error) {
            errorMessage = "Screen Recording access is needed to list windows and record."
            PermissionManager.shared.showDenied(.screen) { [weak self] in Task { await self?.refresh() } }
            return
        }
        errorMessage = ErrorPresenter.message(for: error)
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
        cfg.dimOutside = sourceKind == .window && AppSettings.shared.recordDimEnabled
            cfg.dimOpacity = AppSettings.shared.recordDimOpacity

        do {
            if showKeystrokes && !InputOverlayController.hasInputMonitoringAccess {
                InputOverlayController.requestInputMonitoringAccess()
            }
            if selectedCameraID != nil && bubbleVisible {
                guard await CameraBubbleController.requestAccess() else { throw RecordingError.cameraPermissionDenied }
                if !bubble.isVisible { studioOpen = true; await syncBubble() }
                guard bubble.isVisible, let id = bubble.windowID else { throw RecordingError.cameraPermissionDenied }
                bubble.chromeEnabled = false
                cfg.includedWindowIDs = [id]
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            cfg.dimOutside = sourceKind == .window && AppSettings.shared.recordDimEnabled
            cfg.dimOpacity = AppSettings.shared.recordDimOpacity
            try await manager.start(cfg)
        } catch {
            bubble.chromeEnabled = true
            report(error)
        }
    }

    public func stop() async {
        do { try await manager.stop() } catch {
            if ErrorPresenter.isCancellation(error) { bubble.chromeEnabled = true } else { report(error) }
        }
    }

    public func cancel() { manager.cancel(); bubble.chromeEnabled = true; Task { await syncBubble() } }

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

// MARK: - Studio view

public struct RecordingStudioView: View {
    @ObservedObject var studio: RecordingStudio
    public init(studio: RecordingStudio) { self.studio = studio }

    public var body: some View {
        Form {
            Section { BrandHeader(iconSize: 28, font: .headline) }
            Section("Preview") {
                StudioPreview(studio: studio)
                    .help("Exactly what will be recorded, with the camera in its current spot")
            }
            Section("Source") {
                Picker("Record", selection: $studio.sourceKind) {
                    ForEach(RecordingStudio.SourceKind.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).help("Record a single window or an entire display")
                if studio.sourceKind == .window {
                    Picker("Window", selection: $studio.selectedWindowID) {
                        ForEach(studio.windows) { Text($0.label).tag(Optional($0.id)) }
                    }.help("The window to record")
                } else {
                    Picker("Display", selection: $studio.selectedDisplayID) {
                        ForEach(studio.displays) { Text($0.name).tag(Optional($0.id)) }
                    }.help("The display to record")
                }
            }
            Section("Camera") {
                Picker("Webcam", selection: $studio.selectedCameraID) {
                    Text("None").tag(String?.none)
                    ForEach(studio.cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }.help("Show a webcam bubble in the recording")
                if studio.cameraDenied {
                    HStack {
                        Text("Camera access is off for MasterFabric Cut.").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(u) }
                        }.controlSize(.small)
                    }
                }
                if studio.selectedCameraID != nil {
                    Toggle("Show camera bubble", isOn: $studio.bubbleVisible)
                        .help("Show the floating camera bubble. Turn it off to record without the webcam")
                    Picker("Layout", selection: $studio.layout) {
                        ForEach(CameraLayoutPreset.allCases) { Text($0.title).tag($0) }
                    }.help("Where the webcam bubble sits on screen")
                    Picker("Shape", selection: $studio.bubbleShape) {
                        ForEach(CameraBubbleShape.allCases) { Text($0.title).tag($0) }
                    }.help("Shape of the webcam bubble")
                    Toggle("Mirror camera", isOn: $studio.mirrorCamera).help("Flip the webcam image horizontally")
                    Text("Drag the bubble to move it, drag its corner grip to resize, hover for shape / mirror / hide, right-click for sizes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Audio") {
                Picker("Microphone", selection: $studio.selectedMicID) {
                    Text("None").tag(String?.none)
                    ForEach(studio.microphones, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }.help("Record voice narration from this microphone")
                Toggle("System audio", isOn: $studio.systemAudio).help("Include sound playing on your Mac")
            }
            Section("Options") {
                Picker("Countdown", selection: $studio.countdown) {
                    Text("Off").tag(0); Text("3 s").tag(3); Text("5 s").tag(5); Text("10 s").tag(10)
                }.help("Seconds to wait before recording starts")
                Toggle("Show clicks", isOn: $studio.showClicks).help("Highlight mouse clicks in the recording")
                Toggle("Show keystrokes", isOn: $studio.showKeystrokes).help("Display pressed keys in the recording")
            }
            if let e = studio.errorMessage { Text(e).foregroundStyle(.red) }
            HStack {
                Button("Refresh") { Task { await studio.refresh() } }.help("Rescan windows, displays, cameras and microphones")
                Spacer()
                if studio.manager.state.isActive || studio.manager.state == .countdown {
                    Button("Stop") { Task { await studio.stop() } }.help("Stop recording and open the result")
                } else {
                    Button("Start Recording") { Task { await studio.start() } }.help("Start recording after the countdown")
                        .keyboardShortcut(.defaultAction)
                        .disabled(studio.manager.state == .finishing)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 680)
        .task { await studio.refresh() }
    }
}

// MARK: - Live preview

/// Snapshot of the recorded window/display with the live camera composited where the bubble sits.
private struct StudioPreview: View {
    @ObservedObject var studio: RecordingStudio

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.06))
            if let img = studio.previewImage {
                GeometryReader { geo in
                    let aspect = CGFloat(img.width) / CGFloat(max(img.height, 1))
                    let w = min(geo.size.width, geo.size.height * aspect), h = w / aspect
                    ZStack(alignment: .topLeading) {
                        Image(decorative: img, scale: 1).resizable().frame(width: w, height: h)
                        if let r = studio.bubbleRect, let session = studio.previewSession, studio.bubbleVisible {
                            let side = r.width * w
                            let shape: AnyShape = studio.bubbleShape == .circle
                                ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: side * 0.18, style: .continuous))
                            CameraPreviewView(session: session)
                                .scaleEffect(x: studio.mirrorCamera ? -1 : 1, y: 1)
                                .frame(width: side, height: r.height * h)
                                .clipShape(shape)
                                .overlay(shape.stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                                .offset(x: r.minX * w, y: r.minY * h)
                        }
                    }
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .padding(8)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "rectangle.dashed").font(.title2)
                    Text("Preview appears once Screen Recording is allowed").font(.caption)
                }.foregroundStyle(.secondary)
            }
        }
        .frame(height: 210)
        .task {
            while !Task.isCancelled {
                await studio.capturePreview()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }
}

private struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> PreviewHost { PreviewHost(session: session) }
    func updateNSView(_ v: PreviewHost, context: Context) { v.setSession(session) }
}

private final class PreviewHost: NSView {
    private let layerView: AVCaptureVideoPreviewLayer
    init(session: AVCaptureSession) {
        layerView = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layerView.videoGravity = .resizeAspectFill
        layer?.addSublayer(layerView)
        unmirror()
    }
    required init?(coder: NSCoder) { fatalError() }
    func setSession(_ s: AVCaptureSession) { if layerView.session !== s { layerView.session = s }; unmirror() }
    /// Mirroring is applied by SwiftUI so the preview matches the bubble's setting.
    private func unmirror() {
        guard let c = layerView.connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false
    }
    override func layout() { super.layout(); layerView.frame = bounds }
}
