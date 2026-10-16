import AppKit
@preconcurrency import AVFoundation

public enum CameraBubbleShape: String, CaseIterable, Identifiable {
    case circle, roundedSquare
    public var id: String { rawValue }
    public var title: String { self == .circle ? "Circle" : "Rounded Square" }
}

/// Webcam layout presets: anchor inside the recorded area plus a size relative to its height.
public enum CameraLayoutPreset: String, CaseIterable, Identifiable {
    case bottomRight, bottomLeft, topRight, topLeft, bottomCenter, largeRight

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .bottomRight: return "Bottom Right"
        case .bottomLeft: return "Bottom Left"
        case .topRight: return "Top Right"
        case .topLeft: return "Top Left"
        case .bottomCenter: return "Bottom Center"
        case .largeRight: return "Large (Right)"
        }
    }

    var heightFraction: CGFloat { self == .largeRight ? 0.42 : (self == .bottomCenter ? 0.26 : 0.2) }

    /// Frame in Cocoa screen coordinates inside `container`.
    public func frame(in container: CGRect) -> CGRect {
        let d = min(max(container.height * heightFraction, 100), 600)
        let m: CGFloat = 24
        let x: CGFloat, y: CGFloat
        switch self {
        case .bottomRight: x = container.maxX - d - m; y = container.minY + m
        case .bottomLeft: x = container.minX + m; y = container.minY + m
        case .topRight: x = container.maxX - d - m; y = container.maxY - d - m
        case .topLeft: x = container.minX + m; y = container.maxY - d - m
        case .bottomCenter: x = container.midX - d / 2; y = container.minY + m
        case .largeRight: x = container.maxX - d - m; y = container.midY - d / 2
        }
        return CGRect(x: x, y: y, width: d, height: d)
    }
}

/// Floating, draggable and resizable webcam bubble. Resize with scroll wheel, pinch, or the right-click menu.
@MainActor
public final class CameraBubbleController {
    public private(set) var windowID: CGWindowID?
    public var isVisible: Bool { panel?.isVisible ?? false }

    public var shape: CameraBubbleShape = .circle { didSet { bubbleView?.applyShape(shape) } }
    public var mirrored: Bool = true { didSet { bubbleView?.applyMirror(mirrored) } }

    private var panel: NSPanel?
    private var bubbleView: BubbleView?
    private var session: AVCaptureSession?

    public init() {}

    public static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
    }

    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Starts the camera and shows the bubble placed by `preset` inside `container` (Cocoa screen coordinates).
    public func show(cameraID: String?, preset: CameraLayoutPreset, in container: CGRect) throws {
        hide()
        guard let device = cameraID.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .video) else {
            throw RecordingError.cameraPermissionDenied
        }
        let s = AVCaptureSession()
        s.sessionPreset = .high
        let input = try AVCaptureDeviceInput(device: device)
        guard s.canAddInput(input) else { throw RecordingError.cameraPermissionDenied }
        s.addInput(input)

        let frame = preset.frame(in: container)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = BubbleView(frame: CGRect(origin: .zero, size: frame.size), session: s)
        v.applyShape(shape)
        v.applyMirror(mirrored)
        v.onPreset = { [weak self] size in self?.resize(to: size) }
        v.onShape = { [weak self] sh in self?.shape = sh }
        p.contentView = v
        p.orderFrontRegardless()

        panel = p; bubbleView = v; session = s
        windowID = CGWindowID(p.windowNumber)
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    /// Moves/resizes the bubble to a preset.
    public func apply(preset: CameraLayoutPreset, in container: CGRect) {
        panel?.setFrame(preset.frame(in: container), display: true, animate: true)
        bubbleView?.needsLayout = true
    }

    public func resize(to diameter: CGFloat) {
        guard let p = panel else { return }
        let d = min(max(diameter, 100), 700)
        let c = CGPoint(x: p.frame.midX, y: p.frame.midY)
        p.setFrame(CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d), display: true)
    }

    public func hide() {
        let s = session
        DispatchQueue.global(qos: .utility).async { s?.stopRunning() }
        panel?.orderOut(nil)
        panel = nil; bubbleView = nil; session = nil; windowID = nil
    }
}

private final class BubbleView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    var onPreset: ((CGFloat) -> Void)?
    var onShape: ((CameraBubbleShape) -> Void)?
    private var shape: CameraBubbleShape = .circle

    init(frame: NSRect, session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        preview.frame = bounds
        applyShape(shape)
    }

    func applyShape(_ s: CameraBubbleShape) {
        shape = s
        layer?.cornerRadius = s == .circle ? min(bounds.width, bounds.height) / 2 : bounds.width * 0.18
        layer?.borderWidth = 3
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
    }

    func applyMirror(_ on: Bool) {
        guard let c = preview.connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        c.isVideoMirrored = on
    }

    override func scrollWheel(with event: NSEvent) {
        guard let w = window else { return }
        onPreset?(w.frame.width + event.scrollingDeltaY * 4)
    }

    override func magnify(with event: NSEvent) {
        guard let w = window else { return }
        onPreset?(w.frame.width * (1 + event.magnification))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        for (title, d) in [("Small", 140), ("Medium", 220), ("Large", 340), ("Extra Large", 480)] as [(String, CGFloat)] {
            let i = NSMenuItem(title: title, action: #selector(pickSize(_:)), keyEquivalent: "")
            i.target = self; i.tag = Int(d); m.addItem(i)
        }
        m.addItem(.separator())
        for s in CameraBubbleShape.allCases {
            let i = NSMenuItem(title: s.title, action: #selector(pickShape(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = s.rawValue
            i.state = s == shape ? .on : .off
            m.addItem(i)
        }
        return m
    }

    @objc private func pickSize(_ i: NSMenuItem) { onPreset?(CGFloat(i.tag)) }
    @objc private func pickShape(_ i: NSMenuItem) {
        if let r = i.representedObject as? String, let s = CameraBubbleShape(rawValue: r) { onShape?(s) }
    }
}
