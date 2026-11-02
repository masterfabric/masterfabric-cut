// MasterFabric Cut — Tools module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// Screen corner a pin snaps to.
enum PinCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
    var symbol: String {
        switch self {
        case .topLeft: return "arrow.up.left"
        case .topRight: return "arrow.up.right"
        case .bottomLeft: return "arrow.down.left"
        case .bottomRight: return "arrow.down.right"
        }
    }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }

    static func nearest(to p: NSPoint, in r: NSRect) -> PinCorner {
        let left = p.x < r.midX, top = p.y > r.midY
        return top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
    }

    /// Window origin that places a window of `size` in this corner of `vf`, `offset` steps diagonally inwards (for stacking).
    func origin(for size: NSSize, in vf: NSRect, margin: CGFloat, offset: CGFloat = 0) -> NSPoint {
        let x = isLeft ? vf.minX + margin + offset : vf.maxX - margin - size.width - offset
        let y = isTop ? vf.maxY - margin - size.height - offset : vf.minY + margin + offset
        return NSPoint(x: x, y: y)
    }
}

/// What a pin shows.
enum PinContent {
    case image(NSImage)
    case pdf(PDFDocument)

    /// height / width of the content.
    var aspect: CGFloat {
        switch self {
        case .image(let i):
            return i.size.width > 1 ? i.size.height / i.size.width : 0.75
        case .pdf(let d):
            guard let p = d.page(at: 0) else { return 1.414 }
            var b = p.bounds(for: .cropBox).size
            if p.rotation % 180 != 0 { b = NSSize(width: b.height, height: b.width) }
            return b.width > 1 ? b.height / b.width : 1.414
        }
    }
    var isPDF: Bool { if case .pdf = self { return true }; return false }
}

/// Row shown in the menu-bar panel's "Pinned" list.
struct PinInfo: Identifiable, Equatable {
    let id: UUID
    let title: String
    let symbol: String
    let clickThrough: Bool
}

// MARK: - Controller

/// Always-on-top pins for images, screenshots and PDFs. Main thread only.
final class PinnedScreenshotController: ObservableObject {
    static let shared = PinnedScreenshotController()
    static let margin: CGFloat = 16
    static let stackStep: CGFloat = 28

    @Published private(set) var pins: [PinInfo] = []
    private var panels: [PinPanel] = []

    var count: Int { panels.count }
    var anyClickThrough: Bool { panels.contains { $0.ignoresMouseEvents } }

    // MARK: Pinning

    /// Pins an image. `origin` (screen coordinates, bottom-left) keeps it where it was captured; otherwise it goes to the remembered corner.
    @discardableResult
    func pin(image: NSImage, at origin: NSPoint? = nil, title: String = "Screenshot") -> NSPanel {
        present(.image(image), title: title, origin: origin)
    }

    /// Pins an image or PDF file. Shows an alert when the file can't be read.
    @discardableResult
    func pin(fileURL url: URL) -> NSPanel? {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true, let doc = PDFDocument(url: url), doc.pageCount > 0 {
            return present(.pdf(doc), title: url.lastPathComponent, origin: nil)
        }
        if let img = NSImage(contentsOf: url), img.isValid {
            return present(.image(img), title: url.lastPathComponent, origin: nil)
        }
        alert("Can't pin “\(url.lastPathComponent)”", "Pick an image (PNG, JPEG, HEIC, GIF, TIFF, WebP…) or a PDF.")
        return nil
    }

    /// Asks for one or more images / PDFs and pins them.
    func pinFromOpenPanel() {
        let p = NSOpenPanel()
        p.title = "Pin Image or PDF"
        p.prompt = "Pin"
        p.message = "Choose images or PDFs to float above your other windows."
        p.allowedContentTypes = [.image, .pdf]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        for url in p.urls { pin(fileURL: url) }
    }

    /// Pins whatever the clipboard holds: copied files, a PDF, or an image. Returns false (with an alert) when there is nothing pinnable.
    @discardableResult
    func pinFromClipboard() -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            var any = false
            for u in urls where pin(fileURL: u) != nil { any = true }
            return any
        }
        if let data = pb.data(forType: .pdf), let doc = PDFDocument(data: data), doc.pageCount > 0 {
            present(.pdf(doc), title: "Clipboard PDF", origin: nil); return true
        }
        if let img = NSImage(pasteboard: pb), img.isValid {
            present(.image(img), title: "Clipboard image", origin: nil); return true
        }
        alert("Nothing to pin", "Copy an image, a PDF or an image/PDF file first, then try again.")
        return false
    }

    /// Pins the latest screenshot from capture history.
    @discardableResult
    func pinLastCapture() -> Bool {
        let store = CaptureHistoryStore.shared
        if let item = store.items.first(where: { $0.kind == .screenshot }),
           let img = store.image(for: item) ?? item.fileURL.flatMap({ NSImage(contentsOf: $0) }) {
            pin(image: img, title: "Last capture")
            return true
        }
        alert("Nothing to pin yet", "Take a screenshot first, then pin it from here.")
        return false
    }

    /// Accepts drag & drop of files (images/PDFs) or raw image data.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { self.pin(fileURL: url) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage else { return }
                    DispatchQueue.main.async { self.pin(image: img, title: "Dropped image") }
                }
            }
        }
        return handled
    }

    static let dropTypes: [UTType] = [.fileURL, .image, .pdf]

    // MARK: Managing

    func closeAll() {
        for p in panels { p.onClose = nil; p.orderOut(nil) }
        panels.removeAll()
        refresh()
    }

    func close(_ id: UUID) { panels.first { $0.pinID == id }?.close() }

    func setClickThrough(_ id: UUID, _ on: Bool) { panels.first { $0.pinID == id }?.setClickThrough(on) }

    /// If any pin ignores the mouse, make them all interactive again; otherwise make them all click-through.
    func toggleClickThroughAll() {
        let target = !anyClickThrough
        for p in panels { p.setClickThrough(target) }
    }

    func reveal(_ id: UUID) { panels.first { $0.pinID == id }?.flash() }

    fileprivate func refresh() {
        pins = panels.map { PinInfo(id: $0.pinID, title: $0.pinTitle, symbol: $0.content.isPDF ? "doc.richtext" : "photo",
                                    clickThrough: $0.ignoresMouseEvents) }
    }

    // MARK: Private

    @discardableResult
    private func present(_ content: PinContent, title: String, origin: NSPoint?) -> NSPanel {
        let s = AppSettings.shared
        let vf = NSScreen.underMouse.visibleFrame
        let aspect = content.aspect
        var w = CGFloat(s.pinWidth)
        if origin != nil, case .image(let img) = content { w = img.size.width }
        w = min(max(w, PinPanel.minWidth), vf.width * 0.9)
        var h = w * aspect
        if h > vf.height * 0.9 { h = vf.height * 0.9; w = h / aspect }
        let size = NSSize(width: w, height: h)
        let corner = s.pinCorner
        let stacked = CGFloat(panels.filter { $0.corner == corner }.count) * Self.stackStep
        let o = origin ?? corner.origin(for: size, in: vf, margin: Self.margin, offset: stacked)

        let panel = PinPanel(content: content, title: title, frame: NSRect(origin: o, size: size))
        panel.corner = origin == nil ? corner : nil
        panel.setOpacity(CGFloat(s.pinOpacity), persist: false)
        panel.onChange = { [weak self] in self?.refresh() }
        panel.onClose = { [weak self, weak panel] in
            self?.panels.removeAll { $0 === panel || panel == nil }
            self?.refresh()
        }
        panels.append(panel)
        refresh()
        let target = panel.alphaValue
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.2; panel.animator().alphaValue = target }
        return panel
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }
}

// MARK: - Panel

final class PinPanel: NSPanel {
    static let minWidth: CGFloat = 160

    let pinID = UUID()
    let pinTitle: String
    let content: PinContent
    /// Corner the pin is snapped to, nil when freely placed.
    var corner: PinCorner?
    var onClose: (() -> Void)?
    var onChange: (() -> Void)?
    let chrome = PinChromeModel()

    init(content: PinContent, title: String, frame: NSRect) {
        self.content = content
        self.pinTitle = title
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentAspectRatio = NSSize(width: 1, height: content.aspect)
        minSize = NSSize(width: Self.minWidth, height: Self.minWidth * content.aspect)
        chrome.title = title
        chrome.isPDF = content.isPDF
        contentView = PinRootView(panel: self)
        NotificationCenter.default.addObserver(self, selector: #selector(didEndLiveResize),
                                               name: NSWindow.didEndLiveResizeNotification, object: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        NotificationCenter.default.removeObserver(self)
        let cb = onClose; onClose = nil
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.15; animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.orderOut(nil) })
        cb?()
    }

    override func cancelOperation(_ sender: Any?) { close() }

    // MARK: Behaviour

    func setOpacity(_ value: CGFloat, persist: Bool) {
        let v = min(max(value, 0.15), 1)
        alphaValue = v
        chrome.opacity = Double(v)
        if persist { AppSettings.shared.pinOpacity = Double(v) }
    }

    func setClickThrough(_ on: Bool) {
        ignoresMouseEvents = on
        chrome.clickThrough = on
        if on { chrome.hovering = false }
        (contentView as? PinRootView)?.updateChrome(animated: true)
        onChange?()
    }

    /// Snaps into `corner` of the screen the pin is on and remembers it for new pins.
    func snap(to c: PinCorner, animated: Bool = true) {
        corner = c
        let vf = (screen ?? NSScreen.underMouse).visibleFrame
        let o = c.origin(for: frame.size, in: vf, margin: PinnedScreenshotController.margin)
        setFrame(NSRect(origin: o, size: frame.size), display: true, animate: animated)
        AppSettings.shared.pinCorner = c
    }

    /// Snaps to whichever corner is nearest to the window centre.
    func snapToNearestCorner() {
        let vf = (screen ?? NSScreen.underMouse).visibleFrame
        snap(to: .nearest(to: NSPoint(x: frame.midX, y: frame.midY), in: vf))
    }

    /// Resizes keeping the aspect ratio; the snapped corner (or the top-left when free) stays put.
    func resize(toWidth width: CGFloat, persist: Bool) {
        let vf = (screen ?? NSScreen.underMouse).visibleFrame
        var w = min(max(width, Self.minWidth), vf.width * 0.95)
        var h = w * content.aspect
        if h > vf.height * 0.95 { h = vf.height * 0.95; w = h / content.aspect }
        let f = frame
        let anchorLeft = corner?.isLeft ?? true, anchorTop = corner?.isTop ?? true
        let x = anchorLeft ? f.minX : f.maxX - w
        let y = anchorTop ? f.maxY - h : f.minY
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        invalidateShadow()
        if persist { AppSettings.shared.pinWidth = Double(w) }
    }

    func zoom(by factor: CGFloat) { resize(toWidth: frame.width * factor, persist: true) }

    @objc private func didEndLiveResize() {
        AppSettings.shared.pinWidth = Double(frame.width)
        if let c = corner { snap(to: c) }
        invalidateShadow()
    }

    // MARK: Dragging

    private var dragStartOrigin: NSPoint?
    private var dragStartMouse: NSPoint = .zero

    func beginDrag() { dragStartOrigin = frame.origin; dragStartMouse = NSEvent.mouseLocation }

    func continueDrag() {
        guard let o = dragStartOrigin else { return }
        let m = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(x: o.x + m.x - dragStartMouse.x, y: o.y + m.y - dragStartMouse.y))
    }

    /// Snaps to the nearest corner unless ⌥ is held (free placement).
    func endDrag() {
        defer { dragStartOrigin = nil }
        guard let o = dragStartOrigin, hypot(frame.origin.x - o.x, frame.origin.y - o.y) > 3 else { return }
        if NSEvent.modifierFlags.contains(.option) { corner = nil } else { snapToNearestCorner() }
    }

    /// Briefly pulses the pin so it can be found from the menu-bar list.
    func flash() {
        orderFrontRegardless()
        let a = alphaValue
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.15; animator().alphaValue = 0.2 }) {
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.25; self.animator().alphaValue = a }
        }
    }
}

// MARK: - Chrome model

final class PinChromeModel: ObservableObject {
    @Published var hovering = false
    @Published var opacity: Double = 1
    @Published var clickThrough = false
    @Published var title = ""
    @Published var isPDF = false
    @Published var page = 1
    @Published var pageCount = 1
}

// MARK: - Root view

/// Hosts the content (image or PDF) plus hover chrome: a top toolbar and a bottom bar.
final class PinRootView: NSView {
    private weak var panel: PinPanel?
    private var contentHost: NSView!
    private var pdfView: PDFView?
    private let topBar: NSHostingView<PinTopBar>
    private let bottomBar: NSHostingView<PinBottomBar>
    private var hideWork: DispatchWorkItem?
    private static let barHeight: CGFloat = 40

    init(panel: PinPanel) {
        self.panel = panel
        let chrome = panel.chrome
        topBar = NSHostingView(rootView: PinTopBar(model: chrome,
            onDragBegin: { [weak panel] in panel?.beginDrag() },
            onDrag: { [weak panel] in panel?.continueDrag() },
            onDragEnd: { [weak panel] in panel?.endDrag() },
            onCorner: { [weak panel] c in panel?.snap(to: c) },
            onClickThrough: { [weak panel] in panel?.setClickThrough(true) },
            onClose: { [weak panel] in panel?.close() }))
        bottomBar = NSHostingView(rootView: PinBottomBar(model: chrome,
            onOpacity: { [weak panel] v, done in panel?.setOpacity(CGFloat(v), persist: done) },
            onPrev: {}, onNext: {},
            onResizeBegin: {}, onResize: { _ in }, onResizeEnd: {}))
        super.init(frame: NSRect(origin: .zero, size: panel.frame.size))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        switch panel.content {
        case .image(let img):
            let iv = PassthroughImageView()
            iv.image = img
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.animates = true
            iv.imageAlignment = .alignCenter
            contentHost = iv
        case .pdf(let doc):
            let pv = PDFView()
            pv.document = doc
            pv.autoScales = true
            pv.displayMode = .singlePageContinuous
            pv.displaysPageBreaks = true
            pv.backgroundColor = NSColor(white: 0.92, alpha: 1)
            pdfView = pv
            contentHost = pv
            chrome.pageCount = doc.pageCount
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pv)
        }
        contentHost.frame = bounds
        contentHost.autoresizingMask = [.width, .height]
        addSubview(contentHost)

        // Bottom-bar callbacks that need the PDF view / resize state.
        var startWidth: CGFloat = 0, startMouse: NSPoint = .zero
        bottomBar.rootView = PinBottomBar(model: chrome,
            onOpacity: { [weak panel] v, done in panel?.setOpacity(CGFloat(v), persist: done) },
            onPrev: { [weak self] in self?.pdfView?.goToPreviousPage(nil) },
            onNext: { [weak self] in self?.pdfView?.goToNextPage(nil) },
            onResizeBegin: { [weak panel] in startWidth = panel?.frame.width ?? 0; startMouse = NSEvent.mouseLocation },
            onResize: { [weak panel] _ in
                guard let panel else { return }
                let m = NSEvent.mouseLocation
                // Dragging away from the anchored corner grows the pin.
                let dx = (panel.corner?.isLeft ?? true) ? m.x - startMouse.x : startMouse.x - m.x
                panel.resize(toWidth: startWidth + dx, persist: false)
            },
            onResizeEnd: { [weak panel] in if let p = panel { AppSettings.shared.pinWidth = Double(p.frame.width) } })

        for bar in [topBar, bottomBar] as [NSView] {
            bar.translatesAutoresizingMaskIntoConstraints = true
            addSubview(bar)
        }
        topBar.frame = NSRect(x: 0, y: bounds.height - Self.barHeight, width: bounds.width, height: Self.barHeight)
        topBar.autoresizingMask = [.width, .minYMargin]
        bottomBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        bottomBar.autoresizingMask = [.width, .maxYMargin]
        updateChrome(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func pageChanged() {
        guard let pv = pdfView, let doc = pv.document, let page = pv.currentPage else { return }
        panel?.chrome.page = doc.index(for: page) + 1
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hideWork?.cancel()
        panel?.chrome.hovering = true
        updateChrome(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        let w = DispatchWorkItem { [weak self] in
            self?.panel?.chrome.hovering = false
            self?.updateChrome(animated: true)
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    /// Bars are hidden (and so don't eat clicks) unless the pointer is over the pin.
    func updateChrome(animated: Bool) {
        let show = (panel?.chrome.hovering ?? false) && !(panel?.chrome.clickThrough ?? false)
        for bar in [topBar, bottomBar] as [NSView] {
            if show { bar.isHidden = false }
            let apply = { bar.alphaValue = show ? 1 : 0 }
            if animated {
                NSAnimationContext.runAnimationGroup({ c in c.duration = 0.18; bar.animator().alphaValue = show ? 1 : 0 },
                                                     completionHandler: { if !show { bar.isHidden = true } })
            } else { apply(); bar.isHidden = !show }
        }
    }

    // MARK: Dragging the image itself

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, case .image(let img)? = panel?.content { panel?.resize(toWidth: img.size.width, persist: true); return }
        panel?.beginDrag()
    }
    override func mouseDragged(with event: NSEvent) { panel?.continueDrag() }
    override func mouseUp(with event: NSEvent) { panel?.endDrag() }

    override func scrollWheel(with event: NSEvent) {
        guard pdfView == nil else { super.scrollWheel(with: event); return }
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        panel?.zoom(by: 1 + dy * (event.hasPreciseScrollingDeltas ? 0.01 : 0.05))
    }

    override func magnify(with event: NSEvent) {
        guard pdfView == nil else { super.magnify(with: event); return }
        panel?.zoom(by: 1 + event.magnification)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: panel?.close()                                   // Esc
        case 123 where pdfView != nil: pdfView?.goToPreviousPage(nil)  // ←
        case 124 where pdfView != nil: pdfView?.goToNextPage(nil)      // →
        default: super.keyDown(with: event)
        }
    }

    // MARK: Context menu (images)

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        if case .image = panel?.content {
            m.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "").target = self
            m.addItem(withTitle: "Save…", action: #selector(saveImage), keyEquivalent: "").target = self
            m.addItem(withTitle: "Annotate", action: #selector(annotate), keyEquivalent: "").target = self
            m.addItem(withTitle: "Actual Size", action: #selector(actualSize), keyEquivalent: "").target = self
            m.addItem(.separator())
        }
        let corners = NSMenu()
        for c in PinCorner.allCases {
            let i = NSMenuItem(title: c.displayName, action: #selector(snapCorner(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = c.rawValue; i.state = panel?.corner == c ? .on : .off
            corners.addItem(i)
        }
        let ci = NSMenuItem(title: "Snap to Corner", action: nil, keyEquivalent: ""); ci.submenu = corners; m.addItem(ci)
        m.addItem(withTitle: "Click-Through", action: #selector(clickThrough), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "").target = self
        m.addItem(withTitle: "Close All Pins", action: #selector(closeAll), keyEquivalent: "").target = self
        return m
    }

    private var image: NSImage? { if case .image(let i)? = panel?.content { return i }; return nil }
    @objc private func copyImage() { if let image { AnnotateImageUtil.copyToPasteboard(image) } }
    @objc private func annotate() { if let image { AnnotationEditorWindowController.open(image: image) } }
    @objc private func actualSize() { if let image { panel?.resize(toWidth: image.size.width, persist: true) } }
    @objc private func closePin() { panel?.close() }
    @objc private func closeAll() { PinnedScreenshotController.shared.closeAll() }
    @objc private func clickThrough() { panel?.setClickThrough(true) }
    @objc private func snapCorner(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let c = PinCorner(rawValue: raw) { panel?.snap(to: c) }
    }

    @objc private func saveImage() {
        guard let image else { return }
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

/// Image view that lets mouse events fall through to `PinRootView` (drag, zoom, context menu).
private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Chrome views

/// Small round icon button used in pin chrome.
private struct PinChromeButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.primary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(active ? Color.accentColor : Color.primary.opacity(hovering ? 0.16 : 0.0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct PinTopBar: View {
    @ObservedObject var model: PinChromeModel
    let onDragBegin: () -> Void
    let onDrag: () -> Void
    let onDragEnd: () -> Void
    let onCorner: (PinCorner) -> Void
    let onClickThrough: () -> Void
    let onClose: () -> Void
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 4) {
            // 2×2 corner grid, laid out like the screen.
            Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                GridRow { corner(.topLeft); corner(.topRight) }
                GridRow { corner(.bottomLeft); corner(.bottomRight) }
            }
            .padding(3)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("Snap to a corner")

            HStack(spacing: 5) {
                Image(systemName: model.isPDF ? "doc.richtext" : "pin.fill").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(model.title).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .help("Drag to move — it snaps to the nearest corner (hold ⌥ to place freely)")
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in if !dragging { dragging = true; onDragBegin() } else { onDrag() } }
                .onEnded { _ in dragging = false; onDragEnd() })

            PinChromeButton(symbol: "cursorarrow.rays", help: "Click-through: let clicks pass to windows underneath (turn off from the menu bar or ⌃⇧⌘U)",
                            action: onClickThrough)
            PinChromeButton(symbol: "xmark", help: "Close pin (Esc)", action: onClose)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5) }
    }

    private func corner(_ c: PinCorner) -> some View {
        Button { onCorner(c) } label: {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(AppSettings.shared.pinCorner == c ? Color.accentColor : Color.primary.opacity(0.35))
                .frame(width: 9, height: 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Snap to \(c.displayName.lowercased())")
    }
}

struct PinBottomBar: View {
    @ObservedObject var model: PinChromeModel
    let onOpacity: (Double, Bool) -> Void
    let onPrev: () -> Void
    let onNext: () -> Void
    let onResizeBegin: () -> Void
    let onResize: (CGFloat) -> Void
    let onResizeEnd: () -> Void
    @State private var resizing = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.lefthalf.filled").font(.system(size: 11)).foregroundStyle(.secondary)
            Slider(value: Binding(get: { model.opacity }, set: { onOpacity($0, false) }), in: 0.15...1,
                   onEditingChanged: { editing in if !editing { onOpacity(model.opacity, true) } })
                .controlSize(.mini)
                .frame(minWidth: 50, maxWidth: 110)
                .help("Opacity \(Int(model.opacity * 100))%")
            Spacer(minLength: 0)
            if model.isPDF {
                PinChromeButton(symbol: "chevron.left", help: "Previous page (←)", action: onPrev)
                Text("\(model.page) / \(model.pageCount)").font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit().foregroundStyle(.secondary).fixedSize()
                PinChromeButton(symbol: "chevron.right", help: "Next page (→)", action: onNext)
            }
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(resizing ? 0.16 : 0.06)))
                .contentShape(Circle())
                .help("Drag to resize (keeps the aspect ratio). Scroll or pinch on an image to zoom.")
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in if !resizing { resizing = true; onResizeBegin() } else { onResize(v.translation.width) } }
                    .onEnded { _ in resizing = false; onResizeEnd() })
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5) }
    }
}
