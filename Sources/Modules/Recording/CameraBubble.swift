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

/// Floating, always-on-top, draggable and resizable webcam bubble.
/// Drag to move, drag the corner grip (or scroll / pinch / right-click) to resize; hover for shape, mirror and hide buttons.
@MainActor
public final class CameraBubbleController {
    public private(set) var windowID: CGWindowID?
    public var isVisible: Bool { panel?.isVisible ?? false }
    public var frame: CGRect? { panel?.frame }
    public private(set) var cameraID: String?
    public private(set) var session: AVCaptureSession?

    public var shape: CameraBubbleShape = .circle { didSet { bubbleView?.applyShape(shape) } }
    public var mirrored: Bool = true { didSet { bubbleView?.applyMirror(mirrored) } }
    /// Hover buttons and resize grip. Turned off while recording so they never appear in the video.
    public var chromeEnabled = true { didSet { bubbleView?.chromeEnabled = chromeEnabled } }

    /// Fired when the user changes something through the bubble's own controls.
    public var onFrameChange: ((CGRect) -> Void)?
    public var onShapeChange: ((CameraBubbleShape) -> Void)?
    public var onMirrorChange: ((Bool) -> Void)?
    public var onHideRequested: (() -> Void)?

    private var panel: NSPanel?
    private var bubbleView: BubbleView?
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
    }

    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    private static func input(for cameraID: String?) throws -> AVCaptureDeviceInput {
        guard let device = cameraID.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .video) else {
            throw RecordingError.cameraPermissionDenied
        }
        return try AVCaptureDeviceInput(device: device)
    }

    /// Starts the camera and shows the bubble placed by `preset` inside `container` (Cocoa screen coordinates).
    public func show(cameraID: String?, preset: CameraLayoutPreset, in container: CGRect) throws {
        hide()
        let s = AVCaptureSession()
        s.sessionPreset = .high
        let input = try Self.input(for: cameraID)
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
        v.chromeEnabled = chromeEnabled
        v.onResize = { [weak self] size, anchorTop in self?.resize(to: size, anchoredTop: anchorTop) }
        v.onShape = { [weak self] sh in self?.shape = sh; self?.onShapeChange?(sh) }
        v.onMirror = { [weak self] m in self?.mirrored = m; self?.onMirrorChange?(m) }
        v.onHide = { [weak self] in self?.onHideRequested?() }
        p.contentView = v
        p.orderFrontRegardless()

        let nc = NotificationCenter.default
        observers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
            nc.addObserver(forName: name, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let f = self?.panel?.frame { self?.onFrameChange?(f) } }
            }
        }
        panel = p; bubbleView = v; session = s; self.cameraID = cameraID
        windowID = CGWindowID(p.windowNumber)
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    /// Swaps the camera device without recreating the bubble.
    public func switchCamera(_ cameraID: String?) throws {
        guard let s = session else { return }
        let input = try Self.input(for: cameraID)
        s.beginConfiguration()
        s.inputs.forEach { s.removeInput($0) }
        guard s.canAddInput(input) else { s.commitConfiguration(); throw RecordingError.cameraPermissionDenied }
        s.addInput(input)
        s.commitConfiguration()
        self.cameraID = cameraID
        bubbleView?.applyMirror(mirrored)
    }

    /// Moves/resizes the bubble to a preset.
    public func apply(preset: CameraLayoutPreset, in container: CGRect) {
        panel?.setFrame(preset.frame(in: container), display: true, animate: true)
        bubbleView?.needsLayout = true
    }

    public func resize(to diameter: CGFloat, anchoredTop: Bool = false) {
        guard let p = panel else { return }
        let d = min(max(diameter, 120), 700)
        let f = p.frame
        let origin = anchoredTop
            ? CGPoint(x: f.minX, y: f.maxY - d)
            : CGPoint(x: f.midX - d / 2, y: f.midY - d / 2)
        p.setFrame(CGRect(origin: origin, size: CGSize(width: d, height: d)), display: true)
    }

    public func hide() {
        let s = session
        DispatchQueue.global(qos: .utility).async { s?.stopRunning() }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        panel?.orderOut(nil)
        panel = nil; bubbleView = nil; session = nil; windowID = nil; cameraID = nil
    }
}

private final class BubbleView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    var onResize: ((CGFloat, Bool) -> Void)?
    var onShape: ((CameraBubbleShape) -> Void)?
    var onMirror: ((Bool) -> Void)?
    var onHide: (() -> Void)?
    var chromeEnabled = true { didSet { pill.isHidden = !chromeEnabled; grip.isHidden = !chromeEnabled; if !chromeEnabled { setChrome(visible: false) } } }
    private var shape: CameraBubbleShape = .circle
    private var mirrored = true
    private let pill = NSVisualEffectView()
    private let grip = GripView()
    private var shapeButton: NSButton!
    private var mirrorButton: NSButton!

    init(frame: NSRect, session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
        buildChrome()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    // MARK: Chrome (hover controls)

    private func symbolButton(_ name: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: tip) ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.contentTintColor = .labelColor
        b.toolTip = tip
        b.frame = NSRect(x: 0, y: 0, width: 28, height: 24)
        return b
    }

    private func buildChrome() {
        pill.material = .hudWindow
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 13
        pill.layer?.masksToBounds = true
        pill.frame = NSRect(x: 0, y: 0, width: 96, height: 26)
        shapeButton = symbolButton("circle", tip: "Switch between circle and rounded square", action: #selector(toggleShape))
        mirrorButton = symbolButton("arrow.left.and.right.righttriangle.left.righttriangle.right", tip: "Mirror the camera image", action: #selector(toggleMirror))
        let hide = symbolButton("eye.slash", tip: "Hide the camera bubble (turn it back on in Recording Studio)", action: #selector(hideTapped))
        for (i, b) in [shapeButton!, mirrorButton!, hide].enumerated() {
            b.frame.origin = NSPoint(x: 6 + CGFloat(i) * 28, y: 1)
            pill.addSubview(b)
        }
        pill.alphaValue = 0
        addSubview(pill)
        grip.toolTip = "Drag to resize"
        grip.onDrag = { [weak self] delta in self?.gripDragged(delta) }
        grip.alphaValue = 0
        addSubview(grip)
    }

    private var gripStartWidth: CGFloat = 0
    private func gripDragged(_ delta: GripView.Delta) {
        switch delta {
        case .began: gripStartWidth = window?.frame.width ?? bounds.width
        case .moved(let dx, let dy): onResize?(gripStartWidth + (dx - dy) * 0.7, true)
        }
    }

    private func setChrome(visible: Bool) {
        let v = visible && chromeEnabled
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            pill.animator().alphaValue = v ? 1 : 0
            grip.animator().alphaValue = v ? 1 : 0
        }
    }

    override func mouseEntered(with event: NSEvent) { setChrome(visible: true) }
    override func mouseExited(with event: NSEvent) { setChrome(visible: false) }

    @objc private func toggleShape() { onShape?(shape == .circle ? .roundedSquare : .circle) }
    @objc private func toggleMirror() { onMirror?(!mirrored) }
    @objc private func hideTapped() { onHide?() }

    // MARK: Layout / appearance

    override func layout() {
        super.layout()
        preview.frame = bounds
        applyShape(shape)
        pill.frame.origin = NSPoint(x: bounds.midX - pill.frame.width / 2, y: bounds.height * 0.12)
        let r = min(bounds.width, bounds.height) / 2
        // Circle: sit the grip on the 45° point of the rim; square: tuck it into the corner.
        let off = shape == .circle ? r * 0.707 * 0.9 : r - 18
        let g = NSPoint(x: bounds.midX + off, y: bounds.midY - off)
        grip.frame = NSRect(x: g.x - 12, y: g.y - 12, width: 24, height: 24)
    }

    func applyShape(_ s: CameraBubbleShape) {
        shape = s
        layer?.cornerRadius = s == .circle ? min(bounds.width, bounds.height) / 2 : bounds.width * 0.18
        layer?.borderWidth = 3
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        shapeButton?.image = NSImage(systemSymbolName: s == .circle ? "circle" : "square", accessibilityDescription: nil)
        needsLayout = true
    }

    func applyMirror(_ on: Bool) {
        mirrored = on
        guard let c = preview.connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        c.isVideoMirrored = on
    }

    override func scrollWheel(with event: NSEvent) {
        guard let w = window else { return }
        onResize?(w.frame.width + event.scrollingDeltaY * 4, false)
    }

    override func magnify(with event: NSEvent) {
        guard let w = window else { return }
        onResize?(w.frame.width * (1 + event.magnification), false)
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
        m.addItem(.separator())
        let mi = NSMenuItem(title: "Mirror", action: #selector(toggleMirror), keyEquivalent: "")
        mi.target = self; mi.state = mirrored ? .on : .off; m.addItem(mi)
        let hi = NSMenuItem(title: "Hide Bubble", action: #selector(hideTapped), keyEquivalent: "")
        hi.target = self; m.addItem(hi)
        return m
    }

    @objc private func pickSize(_ i: NSMenuItem) { onResize?(CGFloat(i.tag), false) }
    @objc private func pickShape(_ i: NSMenuItem) {
        if let r = i.representedObject as? String, let s = CameraBubbleShape(rawValue: r) { onShape?(s) }
    }
}

/// Small round resize handle; handles its own mouse events so the panel doesn't drag instead.
private final class GripView: NSView {
    enum Delta { case began, moved(CGFloat, CGFloat) }
    var onDrag: ((Delta) -> Void)?
    private var start: NSPoint = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        let iv = NSImageView(image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Resize") ?? NSImage())
        iv.contentTintColor = .white
        iv.frame = NSRect(x: 5, y: 5, width: 14, height: 14)
        addSubview(iv)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) { start = NSEvent.mouseLocation; onDrag?(.began) }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        onDrag?(.moved(p.x - start.x, p.y - start.y))
    }
}
