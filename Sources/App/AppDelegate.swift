import AppKit
import Combine
import PDFKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var prefsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private let panel = MenuBarPanelController()
    private var awakeSub: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        AppCoordinator.shared.start()
        QuickHelpButton.shared.refresh()
        ClipboardHistory.shared.applySettings()
        QuickNotes.shared.restore()
        // Already trusted (e.g. after an update with a stable signature): no onboarding, no prompts.
        if !AppSettings.shared.onboardingCompleted, PermissionManager.shared.isGranted(.screen) {
            AppSettings.shared.onboardingCompleted = true
        }
        if !AppSettings.shared.onboardingCompleted { OnboardingWindow.shared.show() }
        AppCoordinator.shared.onRecordingStateChange = { [weak self] in self?.rebuildMenu() }
        awakeSub = KeepAwake.shared.$isActive.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuildMenu() }
        #if DEBUG
        // Dev/screenshot hook: MFC_DEMO_QR=<link> opens the QR tool prefilled; MFC_DEMO_QR_PRESENT=1 also presents it.
        let env = ProcessInfo.processInfo.environment
        if let link = env["MFC_DEMO_QR"] {
            let tool = QRCodeToolWindowController.shared
            tool.model.input = link; tool.model.generate(); tool.show()
            if env["MFC_DEMO_QR_PRESENT"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tool.model.present() } }
            // MFC_DEMO_SNAPSHOT_DIR=<dir>: write PNG snapshots of the tool and presentation windows (no Screen Recording needed).
            if let dir = env["MFC_DEMO_SNAPSHOT_DIR"] {
                func snap(_ w: NSWindow?, _ name: String) {
                    guard let v = w?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    snap(NSApp.windows.first { $0.title == "Link to QR Code" }, "qr-tool.png")
                    tool.model.present()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        snap(NSApp.windows.first { $0.level == .statusBar && $0.styleMask == [.borderless] && $0.frame.width > 400 }, "qr-present.png")
                    }
                }
            }
        }
        // MFC_DEMO_PIN=<file>[:<file>…] pins files with the hover chrome shown; with MFC_DEMO_SNAPSHOT_DIR writes pin-1.png, pin-2.png….
        if let files = env["MFC_DEMO_PIN"] {
            let pins = files.split(separator: ":").compactMap { PinnedScreenshotController.shared.pin(fileURL: URL(fileURLWithPath: String($0))) }
            for case let p as PinPanel in pins { p.chrome.hovering = true; (p.contentView as? PinRootView)?.updateChrome(animated: false) }
            if let dir = env["MFC_DEMO_SNAPSHOT_DIR"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    for (i, w) in pins.enumerated() {
                        guard let v = w.contentView, let layer = v.layer else { continue }
                        // CALayer render (not cacheDisplay) so PDFView's tiled page layers are captured too.
                        let scale = w.backingScaleFactor, size = v.bounds.size
                        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                        ctx.scaleBy(x: scale, y: scale)
                        // PDFKit tiles render asynchronously and aren't captured by layer.render: draw the current page first (debug snapshot only).
                        func findPDF(_ v: NSView) -> PDFView? { (v as? PDFView) ?? v.subviews.lazy.compactMap(findPDF).first }
                        var hidden: PDFView?
                        if let pdf = findPDF(v), let page = pdf.currentPage {
                            let r = pdf.convert(pdf.bounds, to: v)
                            ctx.setFillColor(.white); ctx.fill(r)
                            let box = page.bounds(for: .mediaBox), k = min(r.width / box.width, r.height / box.height)
                            ctx.saveGState()
                            ctx.translateBy(x: r.minX + (r.width - box.width * k) / 2, y: r.maxY - box.height * k)
                            ctx.scaleBy(x: k, y: k)
                            page.draw(with: .mediaBox, to: ctx)
                            ctx.restoreGState()
                            pdf.isHidden = true; hidden = pdf
                        }
                        layer.render(in: ctx)
                        hidden?.isHidden = false
                        guard let cg = ctx.makeImage() else { continue }
                        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("pin-\(i + 1).png"))
                    }
                }
            }
        }
        // MFC_DEMO_QUICKHELP=1 opens the Quick Help radial menu with one bubble hovered; with MFC_DEMO_SNAPSHOT_DIR writes quick-help.png.
        if env["MFC_DEMO_QUICKHELP"] == "1" {
            let qh = QuickHelpButton.shared
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { qh.openMenu(autoClose: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { qh.model.hovered = env["MFC_DEMO_QUICKHELP_HOVER"] ?? "qr" }
            if let dir = env["MFC_DEMO_SNAPSHOT_DIR"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                    guard let v = qh.debugMenuView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    // Flatten onto a dark desktop-like backdrop so the transparent panel reads in the PNG.
                    let img = NSImage(size: v.bounds.size, flipped: false) { r in
                        NSGradient(starting: NSColor(white: 0.30, alpha: 1), ending: NSColor(white: 0.16, alpha: 1))?.draw(in: r, angle: -90)
                        rep.draw(in: r)
                        return true
                    }
                    if let tiff = img.tiffRepresentation, let out = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? out.write(to: URL(fileURLWithPath: dir).appendingPathComponent(env["MFC_DEMO_SNAPSHOT_NAME"] ?? "quick-help.png"))
                    }
                }
            }
        }
        // MFC_DEMO_TOOL=<name> opens a tool with in-memory sample data (nothing is saved); with MFC_DEMO_SNAPSHOT_DIR
        // writes <name>.png. Names: tools-panel, menu-bar, color-picker, text-tools, ocr-translate, clipboard-history,
        // countdown, image-converter, screen-ruler, media-studio.
        if let tool = env["MFC_DEMO_TOOL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Self.openDemoTool(tool) }
            if let dir = env["MFC_DEMO_SNAPSHOT_DIR"] {
                let delay: Double = tool == "media-studio" ? 1.4 : 2.6
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.snapshotDemoTool(tool, dir: dir) }
            }
        }
        #endif
    }

    #if DEBUG
    private static var demoWindow: NSWindow?

    private static func openDemoTool(_ name: String) {
        switch name {
        case "tools-panel": QuickHelpButton.shared.openPalette()
        case "menu-bar":
            let host = NSHostingView(rootView: MenuBarView(actions: MenuBarActions()))
            host.setFrameSize(host.fittingSize)
            let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: 0), size: host.fittingSize),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host; w.isReleasedWhenClosed = false; w.orderFrontRegardless()
            demoWindow = w
        case "color-picker": ColorPickerTool.shared.loadDemoColors(); ColorPickerTool.shared.showWindow()
        case "text-tools":
            let m = TextToolsWindow.model
            m.input = #"{"app":"MasterFabric Cut","version":"0.1.3","tools":["color","ruler","ocr","clipboard"],"free":true}"#
            TextToolsWindow.show(); m.run(.jsonPretty)
        case "ocr-translate":
            OCRTranslateTool.shared.show(text: "Ekran görüntüsünü al, metni seç ve tek tıkla çevir. Toplantı Perşembe saat 14:00'te.")
        case "clipboard-history": ClipboardHistory.shared.loadDemoItems(); ClipboardPicker.shared.show()
        case "countdown": CountdownTimer.shared.start(minutes: 25)
        case "image-converter": ImageConverterTool.show()
        case "screen-ruler": ScreenRuler.shared.start()
        case "media-studio": BatchMediaStudio.show()
        default: break
        }
    }

    /// Writes the frontmost visible window of this app (largest if several) onto a dark backdrop.
    private static func snapshotDemoTool(_ name: String, dir: String) {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.frame.width > 150 && $0.frame.height > 100
            && !String(describing: type(of: $0)).contains("StatusBar") && $0 !== QuickHelpButton.shared.debugButtonWindow }
        guard let w = (name == "menu-bar" ? demoWindow : candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let v = w.contentView?.superview ?? w.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size, flipped: false) { r in
            NSGradient(starting: NSColor(white: 0.30, alpha: 1), ending: NSColor(white: 0.16, alpha: 1))?.draw(in: r, angle: -90)
            rep.draw(in: r); return true
        }
        if let tiff = img.tiffRepresentation, let out = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? out.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
    #endif

    // MARK: Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image(recording: false)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        // The dropdown is a custom SwiftUI panel (MenuBarPanel.swift); it observes state itself.
        statusItem?.button?.image = MenuBarIcon.image(recording: AppCoordinator.shared.recorder.state.isActive,
                                                      awake: KeepAwake.shared.isActive)
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button else { return }
        var acts = MenuBarActions()
        acts.perform = { AppCoordinator.shared.perform($0) }
        acts.selfTimer = { AppCoordinator.shared.selfTimerCapture() }
        acts.pinClipboard = { AppCoordinator.shared.pinClipboardImage() }
        acts.preferences = { [weak self] in self?.showPreferences() }
        acts.welcome = { OnboardingWindow.shared.show() }
        acts.about = { [weak self] in self?.showAbout() }
        acts.openItem = { item in
            if let url = item.fileURL { NSWorkspace.shared.open(url) } else { AnnotateModule.shared.showHistory() }
        }
        panel.toggle(relativeTo: button, actions: acts)
    }

    // MARK: Windows

    @objc func showPreferences() {
        if prefsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView()))
            w.isReleasedWhenClosed = false; w.title = "Settings"; w.styleMask = [.titled, .closable, .fullSizeContentView]; w.titlebarAppearsTransparent = true
            prefsWindow = w
        }
        present(prefsWindow!)
    }

    @objc func showAbout() {
        if aboutWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            w.isReleasedWhenClosed = false; w.title = "About MasterFabric Cut"; w.styleMask = [.titled, .closable]
            aboutWindow = w
        }
        present(aboutWindow!)
    }

    private func present(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.center(); w.makeKeyAndOrderFront(nil)
    }
}
