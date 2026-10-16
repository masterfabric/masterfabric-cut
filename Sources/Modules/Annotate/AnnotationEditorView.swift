import SwiftUI
import AppKit

struct AnnotationEditorActions {
    var copy: () -> Void = {}
    var save: () -> Void = {}
    var pin: () -> Void = {}
    var done: () -> Void = {}
}

struct AnnotationEditorView: View {
    @ObservedObject var document: AnnotationDocument
    var actions: AnnotationEditorActions

    private let swatches: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                AnnotationCanvasView(document: document)
                Divider()
                sidebar.frame(width: 230)
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            ForEach(AnnotationTool.allCases) { tool in
                ToolbarToggleButton(symbol: tool.symbolName, selected: document.tool == tool,
                                    help: "\(tool.title) tool") { document.tool = tool }
            }
            Divider().frame(height: 20).padding(.horizontal, 6)
            Button { document.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!document.canUndo)
                .help("Undo the last change (⌘Z)")
            Button { document.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!document.canRedo)
                .help("Redo the change (⇧⌘Z)")
            Spacer()
            Button { actions.pin() } label: { Label("Pin", systemImage: "pin") }
                .help("Pin the annotated image to the screen as a floating window")
            Button { actions.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy the annotated image to the clipboard")
            Button { actions.save() } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                .help("Save the annotated image to a file")
            Button { actions.done() } label: { Text("Done") }
                .keyboardShortcut(.defaultAction)
                .help("Copy the image to the clipboard and close the editor")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: Sidebar

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(nsColor: document.color) }, set: { document.setColor(NSColor($0)) })
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Style") {
                    HStack(spacing: 6) {
                        ForEach(0..<swatches.count, id: \.self) { i in
                            Circle()
                                .fill(Color(nsColor: swatches[i]))
                                .overlay(Circle().stroke(Color.primary.opacity(0.3), lineWidth: 1))
                                .frame(width: 18, height: 18)
                                .onTapGesture { document.setColor(swatches[i]) }
                                .onHover { if $0 { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                                .help("Use this color")
                        }
                    }
                    ColorPicker("Color", selection: colorBinding).help("Pick any custom color")
                    slider("Stroke", value: Binding(get: { document.lineWidth },
                                                    set: { document.setLineWidth($0) }), range: 1...20)
                    slider("Text size", value: Binding(get: { document.fontSize },
                                                       set: { document.setFontSize($0) }), range: 12...120)
                    Toggle("Fill shapes", isOn: $document.filledShapes).help("Fill rectangles and ellipses instead of outlining them")
                }

                section("Crop") {
                    Button("Reset Crop") { document.resetCrop() }
                        .disabled(document.cropRect == document.imageBounds)
                        .help("Restore the full image after cropping")
                }

                section("Background") {
                    Picker("Style", selection: $document.background.preset) {
                        ForEach(BackgroundPreset.allCases) { Text($0.title).tag($0) }
                    }.help("Choose a backdrop to place behind the screenshot")
                    slider("Padding", value: $document.background.padding, range: 0...200)
                    slider("Corners", value: $document.background.cornerRadius, range: 0...60)
                    Toggle("Shadow", isOn: $document.background.shadow).help("Add a soft drop shadow behind the image")
                }
            }
            .padding(12)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func slider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption)
            Slider(value: value, in: range).help(title)
        }
    }
}

/// Hosts the editor in a standalone window.
final class AnnotationEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var live: [AnnotationEditorWindowController] = []

    let doc: AnnotationDocument
    let sourceURL: URL?
    /// Called after the user saves the edited image to disk.
    var onSaved: ((URL) -> Void)?

    /// Opens an editor for `image`. Returns nil if the image has no usable bitmap data.
    @discardableResult
    static func open(image: NSImage, sourceURL: URL? = nil,
                     onSaved: ((URL) -> Void)? = nil) -> AnnotationEditorWindowController? {
        guard let doc = AnnotationDocument(image: image) else { return nil }
        let controller = AnnotationEditorWindowController(document: doc, sourceURL: sourceURL)
        controller.onSaved = onSaved
        live.append(controller)
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    private init(document: AnnotationDocument, sourceURL: URL?) {
        self.doc = document
        self.sourceURL = sourceURL

        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let imgW = CGFloat(doc.baseImage.width) / doc.sourceScale
        let imgH = CGFloat(doc.baseImage.height) / doc.sourceScale
        let width = min(max(imgW + 230 + 80, 900), screen.width * 0.9)
        let height = min(max(imgH + 52 + 80, 600), screen.height * 0.9)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = sourceURL?.lastPathComponent ?? "Annotate"
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        var actions = AnnotationEditorActions()
        actions.copy = { [weak self] in self?.copy() }
        actions.save = { [weak self] in self?.save() }
        actions.pin = { [weak self] in self?.pin() }
        actions.done = { [weak self] in self?.copy(); self?.window?.close() }
        window.contentView = NSHostingView(rootView: AnnotationEditorView(document: document, actions: actions))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) {
        Self.live.removeAll { $0 === self }
    }

    private func copy() {
        if let img = doc.renderedImage() { AnnotateImageUtil.copyToPasteboard(img) }
    }

    private func pin() {
        if let img = doc.renderedImage() { PinnedScreenshotController.shared.pin(image: img) }
    }

    private func save() {
        guard let img = doc.renderedImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.directoryURL = sourceURL?.deletingLastPathComponent() ?? AnnotateImageUtil.desktopDirectory
        panel.nameFieldStringValue = AnnotateImageUtil.defaultFileName() + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format = AnnotateOutputFormat.format(forExtension: url.pathExtension)
        guard let data = AnnotateImageUtil.data(from: img, format: format) else { return }
        do {
            try data.write(to: url, options: .atomic)
            onSaved?(url)
        } catch {
            ErrorPresenter.present(error, title: "Couldn't save the image")
        }
    }
}

/// Soft rounded toolbar button with hover + selected states.
struct ToolbarToggleButton: View {
    let symbol: String
    let selected: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.25) : (hovering ? Color.primary.opacity(0.08) : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
