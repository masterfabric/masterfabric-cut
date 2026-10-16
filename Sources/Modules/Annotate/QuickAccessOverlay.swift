import AppKit
import SwiftUI

enum QuickAccessPosition: String, CaseIterable, Identifiable {
    case bottomLeft, bottomRight, topLeft, topRight
    var id: String { rawValue }
}

struct QuickAccessConfiguration {
    var position: QuickAccessPosition = .bottomLeft
    /// Seconds before an overlay disappears on its own. 0 disables auto-close.
    var autoCloseDelay: TimeInterval = 8
    var saveDirectory: URL = AnnotateImageUtil.desktopDirectory
    var format: AnnotateOutputFormat = .png
    var filenamePrefix: String = "MasterFabric Cut"
    /// Close the overlay after copy / save.
    var closeAfterAction: Bool = true
}

/// One screenshot shown in the Quick Access stack.
final class QuickAccessItem: ObservableObject, Identifiable {
    let id = UUID()
    let image: NSImage
    @Published var fileURL: URL?
    @Published var flash: String?
    /// Drives the slide-in / slide-out animation of the card.
    @Published var isPresented = false
    /// True when `fileURL` is a temp file we created for drag-out.
    var isTemporary = false

    init(image: NSImage, fileURL: URL?) {
        self.image = image
        self.fileURL = fileURL
    }

    /// File URL suitable for dragging; writes a temp PNG if the image was never saved.
    func ensureFile() -> URL? {
        if let url = fileURL, FileManager.default.fileExists(atPath: url.path) { return url }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MasterFabricCut", isDirectory: true)
        guard let url = try? AnnotateImageUtil.write(image, to: dir, format: .png) else { return nil }
        fileURL = url
        isTemporary = true
        return url
    }
}

struct QuickAccessActions {
    var copy: () -> Void
    var save: () -> Void
    var annotate: () -> Void
    var pin: () -> Void
    var close: () -> Void
    var hover: (Bool) -> Void
}

/// Hosting view that reacts to the first click even though the panel never becomes key.
private final class QuickAccessHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Floating thumbnail stack shown after a capture (CleanShot X-style Quick Access). Call from the main thread.
final class QuickAccessOverlayController {
    static let shared = QuickAccessOverlayController()

    var configuration = QuickAccessConfiguration()
    /// Called after an item is written to disk via the Save button.
    var onSaved: ((URL) -> Void)?
    /// Called after the Copy button; useful for analytics / history.
    var onCopied: ((NSImage) -> Void)?

    private struct Entry {
        let item: QuickAccessItem
        let panel: NSPanel
        var timer: Timer?
    }
    private var entries: [Entry] = []

    /// Card size; the panel is larger by `pad` on each side so the soft shadow isn't clipped.
    private let cardWidth: CGFloat = 320
    private let pad: CGFloat = 24
    private let margin: CGFloat = 14
    private let spacing: CGFloat = 10
    private let maxEntries = 5

    // MARK: Public API

    @discardableResult
    func show(image: NSImage, fileURL: URL? = nil) -> QuickAccessItem {
        let item = QuickAccessItem(image: image, fileURL: fileURL)
        let card = cardSize(for: image)
        let size = NSSize(width: card.width + pad * 2, height: card.height + pad * 2)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let id = item.id
        let actions = QuickAccessActions(
            copy: { [weak self] in self?.copy(id) },
            save: { [weak self] in self?.save(id) },
            annotate: { [weak self] in self?.annotate(id) },
            pin: { [weak self] in self?.pin(id) },
            close: { [weak self] in self?.dismiss(id) },
            hover: { [weak self] hovering in self?.setHovering(hovering, id: id) })
        let host = QuickAccessHostingView(rootView: QuickAccessItemView(item: item, cardSize: card, pad: pad,
                                                                         fromLeft: configuration.position == .bottomLeft || configuration.position == .topLeft,
                                                                         actions: actions))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        entries.insert(Entry(item: item, panel: panel, timer: nil), at: 0)
        // Trim the oldest cards when the stack gets too tall.
        while entries.count > maxEntries, let last = entries.last { dismiss(last.item.id) }
        layout(animated: false, only: panel)
        panel.orderFrontRegardless()
        layout(animated: true)
        DispatchQueue.main.async { item.isPresented = true }
        scheduleAutoClose(id)
        return item
    }

    func dismiss(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.item.id == id }) else { return }
        entries[i].timer?.invalidate()
        let entry = entries.remove(at: i)
        entry.item.isPresented = false // plays the slide-out
        if entry.item.isTemporary, let url = entry.item.fileURL {
            // Keep the file for a while: a drag may still be reading it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { try? FileManager.default.removeItem(at: url) }
        }
        // Retain the panel until the animation ends and never tear it down inside its own event handler.
        let panel = entry.panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        layout(animated: true)
    }

    func dismissAll() {
        for id in entries.map({ $0.item.id }) { dismiss(id) }
    }

    // MARK: Layout

    private func cardSize(for image: NSImage) -> NSSize {
        let aspect = image.size.width > 0 ? image.size.height / image.size.width : 0.6
        let h = min(max(cardWidth * aspect, 140), 280)
        return NSSize(width: cardWidth, height: h)
    }

    private func layout(animated: Bool, only: NSPanel? = nil) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pos = configuration.position
        let atTop = pos == .topLeft || pos == .topRight
        let atLeft = pos == .bottomLeft || pos == .topLeft
        var cursor = (atTop ? area.maxY - margin : area.minY + margin) + (atTop ? pad : -pad)
        for e in entries {
            let size = e.panel.frame.size
            let x = atLeft ? area.minX + margin - pad : area.maxX - margin + pad - size.width
            let y = atTop ? cursor - size.height : cursor
            let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            if only == nil || only === e.panel {
                if animated && only == nil {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.35
                        ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
                        e.panel.animator().setFrame(frame, display: true)
                    }
                } else {
                    e.panel.setFrame(frame, display: true)
                }
            }
            cursor += (atTop ? -1 : 1) * (size.height - pad * 2 + spacing)
        }
    }

    // MARK: Timers

    private func scheduleAutoClose(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.item.id == id }) else { return }
        entries[i].timer?.invalidate()
        entries[i].timer = nil
        guard configuration.autoCloseDelay > 0 else { return }
        entries[i].timer = Timer.scheduledTimer(withTimeInterval: configuration.autoCloseDelay, repeats: false) {
            [weak self] _ in self?.dismiss(id)
        }
    }

    private func setHovering(_ hovering: Bool, id: UUID) {
        guard let i = entries.firstIndex(where: { $0.item.id == id }) else { return }
        if hovering {
            entries[i].timer?.invalidate()
            entries[i].timer = nil
        } else {
            scheduleAutoClose(id)
        }
    }

    // MARK: Actions

    private func item(_ id: UUID) -> QuickAccessItem? {
        entries.first { $0.item.id == id }?.item
    }

    private func copy(_ id: UUID) {
        guard let item = item(id) else { return }
        AnnotateImageUtil.copyToPasteboard(item.image)
        onCopied?(item.image)
        finish(item, message: "Copied")
    }

    private func save(_ id: UUID) {
        guard let item = item(id) else { return }
        do {
            let url = try AnnotateImageUtil.write(item.image, to: configuration.saveDirectory,
                                                  format: configuration.format, prefix: configuration.filenamePrefix)
            item.fileURL = url
            item.isTemporary = false
            onSaved?(url)
            finish(item, message: "Saved")
        } catch {
            item.flash = "Save failed"
        }
    }

    private func annotate(_ id: UUID) {
        guard let item = item(id) else { return }
        AnnotationEditorWindowController.open(image: item.image, sourceURL: item.isTemporary ? nil : item.fileURL,
                                              onSaved: onSaved)
        dismiss(id)
    }

    private func pin(_ id: UUID) {
        guard let item = item(id) else { return }
        PinnedScreenshotController.shared.pin(image: item.image)
        dismiss(id)
    }

    private func finish(_ item: QuickAccessItem, message: String) {
        item.flash = message
        let id = item.id
        guard configuration.closeAfterAction else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak item] in item?.flash = nil }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.dismiss(id) }
    }
}

// MARK: - View

struct QuickAccessItemView: View {
    @ObservedObject var item: QuickAccessItem
    let cardSize: CGSize
    let pad: CGFloat
    let fromLeft: Bool
    let actions: QuickAccessActions
    @State private var hovering = false
    @State private var hint: String?

    private let radius: CGFloat = 26

    var body: some View {
        ZStack {
            Image(nsImage: item.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: cardSize.width, height: cardSize.height)
                .clipped()

            // Soft scrim + controls on hover.
            LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.15), .black.opacity(0.5)],
                           startPoint: .top, endPoint: .bottom)
                .opacity(hovering || item.flash != nil ? 1 : 0)

            if let flash = item.flash {
                Label(flash, systemImage: flash == "Save failed" ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else if hovering {
                VStack(spacing: 12) {
                    pill("Copy", "doc.on.doc", "Copy to clipboard", actions.copy)
                    pill("Save", "square.and.arrow.down", "Save to disk", actions.save)
                }
                .transition(.scale(scale: 0.92).combined(with: .opacity))
                corner("xmark", .topLeading, "Close (dismiss this capture)", actions.close)
                corner("pin.fill", .topTrailing, "Pin to screen as a floating window", actions.pin)
                corner("pencil.tip.crop.circle", .bottomLeading, "Annotate in the editor", actions.annotate)
                Text(hint ?? "Drag to drop the image anywhere")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 12).padding(.horizontal, 56)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.28), radius: 20, y: 8)
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .scaleEffect(hovering ? 1.025 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: item.flash)
        .padding(pad)
        // Slide in from the screen edge with a spring; slide back out on dismiss.
        .offset(x: item.isPresented ? 0 : (fromLeft ? -(cardSize.width + pad) : (cardSize.width + pad)))
        .opacity(item.isPresented ? 1 : 0)
        .scaleEffect(item.isPresented ? 1 : 0.9)
        .animation(item.isPresented
                   ? .spring(response: 0.5, dampingFraction: 0.72)
                   : .easeIn(duration: 0.25), value: item.isPresented)
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            if !h { hint = nil }
            actions.hover(h)
        }
        .onDrag {
            if let url = item.ensureFile() {
                let provider = NSItemProvider(object: url as NSURL)
                provider.suggestedName = url.deletingPathExtension().lastPathComponent
                return provider
            }
            return NSItemProvider(object: item.image)
        } preview: {
            Image(nsImage: item.image).resizable().aspectRatio(contentMode: .fit)
                .frame(width: 220).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .contextMenu {
            Button { actions.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
            Button { actions.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
            Button { actions.annotate() } label: { Label("Annotate…", systemImage: "pencil.tip.crop.circle") }
            Button { actions.pin() } label: { Label("Pin to Screen", systemImage: "pin") }
            Divider()
            Button { actions.close() } label: { Label("Close", systemImage: "xmark") }
        }
    }

    private func pill(_ title: String, _ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        QuickAccessPill(title: title, symbol: symbol, help: help, action: action) { hint = $0 }
    }

    private func corner(_ symbol: String, _ alignment: Alignment, _ help: String,
                        _ action: @escaping () -> Void) -> some View {
        QuickAccessRoundButton(symbol: symbol, help: help, action: action) { hint = $0 }
            .padding(13)
            .frame(width: cardSize.width, height: cardSize.height, alignment: alignment)
    }
}

private struct QuickAccessPill: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void
    let onHint: (String?) -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 132, height: 40)
                .foregroundColor(.black.opacity(0.85))
                .background(Capsule(style: .continuous).fill(Color.white.opacity(over ? 1 : 0.88)))
                .shadow(color: .black.opacity(0.2), radius: over ? 6 : 3, y: 1)
                .scaleEffect(over ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { over = $0; onHint($0 ? help : nil) }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: over)
    }
}

private struct QuickAccessRoundButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    let onHint: (String?) -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .frame(width: 38, height: 38)
                .foregroundColor(.black.opacity(0.8))
                .background(Circle().fill(Color.white.opacity(over ? 1 : 0.88)))
                .shadow(color: .black.opacity(0.2), radius: over ? 5 : 2, y: 1)
                .scaleEffect(over ? 1.15 : 1)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { over = $0; onHint($0 ? help : nil) }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: over)
    }
}
