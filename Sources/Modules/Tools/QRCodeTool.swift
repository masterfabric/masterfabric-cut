// MasterFabric Cut — Tools module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Generator

/// Turns text (usually a link) into a crisp QR code using Core Image's built-in generator.
enum QRCodeGenerator {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Normalizes user input into the payload that gets encoded: trims whitespace and adds
    /// `https://` to bare domains such as `masterfabric.co/cut`.
    static func payload(from input: String) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if text.contains("://") || text.lowercased().hasPrefix("mailto:") || text.lowercased().hasPrefix("tel:") { return text }
        let looksLikeHost = !text.contains(" ") && text.contains(".") && !text.hasPrefix(".")
        return looksLikeHost ? "https://" + text : text
    }

    /// True when `text` is a web link (used to prefill from the clipboard).
    static func isLink(_ text: String) -> Bool {
        let p = payload(from: text)
        guard let url = URL(string: p), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && url.host != nil
    }

    /// Black-on-white QR image whose side is at least `side` pixels, scaled with whole-pixel modules
    /// (no blurring) and surrounded by the standard 4-module quiet zone.
    static func image(for payload: String, side: CGFloat = 1024, correction: String = "M") -> NSImage? {
        guard !payload.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = correction
        guard var output = filter.outputImage else { return nil }
        // CIQRCodeGenerator already adds a 1-module margin; pad to 4 modules on every side.
        let modules = output.extent.width
        let pad: CGFloat = 3
        output = output.transformed(by: CGAffineTransform(translationX: pad, y: pad))
            .composited(over: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: modules + pad * 2, height: modules + pad * 2)))
        let total = modules + pad * 2
        let scale = max(1, (side / total).rounded(.up))
        let scaled = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Model

@MainActor
final class QRCodeToolModel: ObservableObject {
    @Published var input: String = ""
    @Published private(set) var payload: String = ""
    @Published private(set) var image: NSImage?
    @Published var status: String?

    var hasCode: Bool { image != nil }

    func generate() {
        let p = QRCodeGenerator.payload(from: input)
        payload = p
        image = QRCodeGenerator.image(for: p)
        status = image == nil && !p.isEmpty ? "This text is too long for a QR code." : nil
    }

    func prefillFromClipboard() {
        guard input.isEmpty, let s = NSPasteboard.general.string(forType: .string), QRCodeGenerator.isLink(s) else { return }
        input = s.trimmingCharacters(in: .whitespacesAndNewlines)
        generate()
    }

    func copyImage() {
        guard let image else { return }
        FileOutput.copy(image)
        flash("QR code copied")
    }

    func copyLink() {
        guard !payload.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        flash("Link copied")
    }

    func save(from window: NSWindow?) {
        guard let image, let data = image.encoded(as: .png) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = AppSettings.shared.saveDirectory
        panel.nameFieldStringValue = "QR " + (URL(string: payload)?.host ?? "code") + ".png"
        let write: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            do { try data.write(to: url); self?.flash("Saved \(url.lastPathComponent)") } catch { ErrorPresenter.present(error, title: "QR code couldn't be saved") }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: write) } else { write(panel.runModal()) }
    }

    func present() {
        guard let image else { return }
        QRPresentationController.shared.present(image: image, link: payload)
    }

    private func flash(_ text: String) {
        status = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in if self?.status == text { self?.status = nil } }
    }
}

// MARK: - Tool window

struct QRCodeToolView: View {
    @ObservedObject var model: QRCodeToolModel
    var window: () -> NSWindow? = { nil }
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "qrcode").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.teal.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Link to QR Code").font(.system(size: 14, weight: .semibold))
                    Text("Paste a link, generate, then present it full screen").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                TextField("https://masterfabric.co", text: $model.input)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { model.generate() }
                    .help("The link (or any text) to encode")
                Button("Generate") { model.generate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Create the QR code (↩)")
            }

            preview

            HStack(spacing: 8) {
                Button { model.present() } label: { Label("Present", systemImage: "play.rectangle.fill") }
                    .keyboardShortcut("p", modifiers: .command)
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .help("Show the QR code full screen for presentations (⌘P). Esc or click to close.")
                Button { model.copyImage() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copy the QR image to the clipboard (⇧⌘C)")
                Button { model.save(from: window()) } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Save the QR code as a PNG (⌘S)")
                Spacer()
                Button { model.copyLink() } label: { Image(systemName: "link") }
                    .help("Copy the encoded link")
            }
            .disabled(!model.hasCode)
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { model.prefillFromClipboard(); focused = true }
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.quaternary.opacity(0.35))
            if let image = model.image {
                VStack(spacing: 10) {
                    Image(nsImage: image).interpolation(.none).resizable().aspectRatio(1, contentMode: .fit)
                        .frame(width: 240, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                        .onTapGesture(count: 2) { model.present() }
                        .help("Double-click to present")
                        .onDrag { NSItemProvider(object: image) }
                    Text(model.payload).font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                .padding(16)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                    Text("Your QR code appears here").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if let status = model.status {
                VStack {
                    Spacer()
                    Text(status).font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                }
                .transition(.opacity)
            }
        }
        .frame(height: 320)
        .animation(.easeInOut(duration: 0.2), value: model.status)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.payload)
    }
}

@MainActor
final class QRCodeToolWindowController: NSObject, NSWindowDelegate {
    static let shared = QRCodeToolWindowController()
    private var window: NSWindow?
    let model = QRCodeToolModel()

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: QRCodeToolView(model: model, window: { [weak self] in self?.window }))
            let w = NSWindow(contentViewController: host)
            w.isReleasedWhenClosed = false
            w.title = "Link to QR Code"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.delegate = self
            window = w
            w.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        model.prefillFromClipboard()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Presentation mode

/// Full-screen, distraction-free view of a QR code with its link underneath, for showing a link
/// to a room during a talk or meeting. Appears above full-screen apps (Keynote, browsers) on the
/// display under the cursor. Esc, Space, Return or a click closes it.
@MainActor
final class QRPresentationController {
    static let shared = QRPresentationController()
    private var window: NSWindow?
    private var monitor: Any?

    func present(image: NSImage, link: String) {
        dismiss(animated: false)
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let w = PresentationWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.backgroundColor = .white
        w.isOpaque = true
        w.hasShadow = false
        w.alphaValue = 0
        w.contentView = NSHostingView(rootView: QRPresentationView(image: image, link: link) { [weak self] in self?.dismiss() })
        w.setFrame(screen.frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        window = w
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.25; w.animator().alphaValue = 1 }
        NSCursor.setHiddenUntilMouseMoves(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            // Esc, Space, Return, Q
            if [53, 49, 36, 76, 12].contains(Int(e.keyCode)) { self?.dismiss(); return nil }
            return e
        }
    }

    func dismiss(animated: Bool = true) {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard let w = window else { return }
        window = nil
        guard animated else { w.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.18; w.animator().alphaValue = 0 },
                                             completionHandler: { w.orderOut(nil) })
    }
}

private final class PresentationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct QRPresentationView: View {
    let image: NSImage
    let link: String
    let close: () -> Void
    @State private var showHint = true

    private var displayLink: String {
        var s = link
        for p in ["https://", "http://"] where s.lowercased().hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width * 0.7, geo.size.height * 0.68)
            ZStack {
                Color.white
                VStack(spacing: side * 0.06) {
                    Image(nsImage: image).interpolation(.none).resizable().aspectRatio(1, contentMode: .fit)
                        .frame(width: side, height: side)
                    Text(displayLink)
                        .font(.system(size: max(22, min(56, side * 0.075)), weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(white: 0.1))
                        .lineLimit(2).minimumScaleFactor(0.4).multilineTextAlignment(.center)
                        .frame(maxWidth: geo.size.width * 0.85)
                        .textSelection(.enabled)
                }
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        BrandIcon(size: 16)
                        Text("Esc to close").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color(white: 0.45))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color(white: 0.94), in: Capsule())
                    .opacity(showHint ? 1 : 0)
                    .padding(.bottom, 28)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { close() }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .light)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation(.easeOut(duration: 0.6)) { showHint = false } }
        }
    }
}
