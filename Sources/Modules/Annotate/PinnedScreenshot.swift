import AppKit

/// Manages always-on-top floating screenshot windows.
final class PinnedScreenshotController {
    static let shared = PinnedScreenshotController()

    private var panels: [PinnedPanel] = []

    var count: Int { panels.count }

    /// Pins `image` as a floating window. `origin` is in screen coordinates (bottom-left of the window);
    /// when nil the window is centred on the screen under the mouse.
    @discardableResult
    func pin(image: NSImage, at origin: NSPoint? = nil) -> NSPanel {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var size = image.size
        if size.width < 1 || size.height < 1 { size = NSSize(width: 300, height: 200) }
        let maxW = visible.width * 0.6, maxH = visible.height * 0.6
        let fit = min(1, maxW / size.width, maxH / size.height)
        size = NSSize(width: size.width * fit, height: size.height * fit)

        let o = origin ?? NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        let panel = PinnedPanel(image: image, frame: NSRect(origin: o, size: size))
        panel.onClose = { [weak self, weak panel] in
            guard let panel else { return }
            self?.panels.removeAll { $0 === panel }
        }
        panels.append(panel)
        panel.orderFrontRegardless()
        return panel
    }

    func closeAll() {
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
    }
}

final class PinnedPanel: NSPanel {
    var onClose: (() -> Void)?
    let image: NSImage

    init(image: NSImage, frame: NSRect) {
        self.image = image
        super.init(contentRect: frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = frame.size
        minSize = NSSize(width: 60, height: 60 * frame.height / max(frame.width, 1))
        contentView = PinnedImageView(image: image)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        orderOut(nil)
        onClose?()
        onClose = nil
    }

    /// Scales the window about its centre, keeping the aspect ratio.
    func zoom(by factor: CGFloat) {
        let aspect = image.size.height / max(image.size.width, 1)
        let screenW = (screen ?? NSScreen.main)?.frame.width ?? 3000
        let newW = min(max(frame.width * factor, 60), screenW * 4)
        resize(toWidth: newW, aspect: aspect)
    }

    func setScale(_ scale: CGFloat) {
        let aspect = image.size.height / max(image.size.width, 1)
        resize(toWidth: max(60, image.size.width * scale), aspect: aspect)
    }

    private func resize(toWidth w: CGFloat, aspect: CGFloat) {
        let h = w * aspect
        let c = NSPoint(x: frame.midX, y: frame.midY)
        setFrame(NSRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), display: true)
    }
}

final class PinnedImageView: NSView {
    private let image: NSImage

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private var panel: PinnedPanel? { window as? PinnedPanel }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.05
        panel?.zoom(by: 1 + dy * step)
    }

    override func magnify(with event: NSEvent) {
        panel?.zoom(by: 1 + event.magnification)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { panel?.setScale(1); return }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { panel?.close() } else { super.keyDown(with: event) }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "").target = self
        m.addItem(withTitle: "Save…", action: #selector(saveImage), keyEquivalent: "").target = self
        m.addItem(withTitle: "Annotate", action: #selector(annotate), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Actual Size", action: #selector(actualSize), keyEquivalent: "").target = self
        let opacity = NSMenu()
        for pct in [100, 80, 60, 40, 20] {
            let item = NSMenuItem(title: "\(pct)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = pct
            item.state = Int((window?.alphaValue ?? 1) * 100 + 0.5) == pct ? .on : .off
            opacity.addItem(item)
        }
        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacity
        m.addItem(opacityItem)
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "").target = self
        m.addItem(withTitle: "Close All Pins", action: #selector(closeAll), keyEquivalent: "").target = self
        return m
    }

    @objc private func copyImage() { AnnotateImageUtil.copyToPasteboard(image) }
    @objc private func annotate() { AnnotationEditorWindowController.open(image: image) }
    @objc private func actualSize() { panel?.setScale(1) }
    @objc private func closePin() { panel?.close() }
    @objc private func closeAll() { PinnedScreenshotController.shared.closeAll() }
    @objc private func setOpacity(_ sender: NSMenuItem) { window?.alphaValue = CGFloat(sender.tag) / 100 }

    @objc private func saveImage() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.png, .jpeg]
        p.directoryURL = AnnotateImageUtil.desktopDirectory
        p.nameFieldStringValue = AnnotateImageUtil.defaultFileName() + ".png"
        guard p.runModal() == .OK, let url = p.url,
              let data = AnnotateImageUtil.data(from: image, format: .format(forExtension: url.pathExtension))
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
