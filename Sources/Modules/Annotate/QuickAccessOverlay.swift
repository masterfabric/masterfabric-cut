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

/// Floating thumbnail stack shown after a capture. Call from the main thread.
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

    private let thumbWidth: CGFloat = 200
    private let inset: CGFloat = 10
    private let spacing: CGFloat = 8

    // MARK: Public API

    @discardableResult
    func show(image: NSImage, fileURL: URL? = nil) -> QuickAccessItem {
        let item = QuickAccessItem(image: image, fileURL: fileURL)
        let size = panelSize(for: image)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let id = item.id
        let actions = QuickAccessActions(
            copy: { [weak self] in self?.copy(id) },
            save: { [weak self] in self?.save(id) },
            annotate: { [weak self] in self?.annotate(id) },
            pin: { [weak self] in self?.pin(id) },
            close: { [weak self] in self?.dismiss(id) },
            hover: { [weak self] hovering in self?.setHovering(hovering, id: id) })
        let thumbSize = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
        panel.contentView = NSHostingView(rootView: QuickAccessItemView(item: item, thumbSize: thumbSize, actions: actions))

        entries.insert(Entry(item: item, panel: panel, timer: nil), at: 0)
        layout(animated: false)
        panel.orderFrontRegardless()
        scheduleAutoClose(id)
        return item
    }

    func dismiss(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.item.id == id }) else { return }
        entries[i].timer?.invalidate()
        let entry = entries.remove(at: i)
        entry.panel.orderOut(nil)
        if entry.item.isTemporary, let url = entry.item.fileURL {
            // Keep the file for a while: a drag may still be reading it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { try? FileManager.default.removeItem(at: url) }
        }
        layout(animated: true)
    }

    func dismissAll() {
        for id in entries.map({ $0.item.id }) { dismiss(id) }
    }

    // MARK: Layout

    private func panelSize(for image: NSImage) -> NSSize {
        let aspect = image.size.width > 0 ? image.size.height / image.size.width : 0.6
        let h = min(max(thumbWidth * aspect, 70), 170)
        return NSSize(width: thumbWidth + inset * 2, height: h + inset * 2)
    }

    private func layout(animated: Bool) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pos = configuration.position
        let atTop = pos == .topLeft || pos == .topRight
        let atLeft = pos == .bottomLeft || pos == .topLeft
        var cursor = atTop ? area.maxY : area.minY
        for e in entries {
            let size = e.panel.frame.size
            let x = atLeft ? area.minX + 8 : area.maxX - size.width - 8
            let y = atTop ? cursor - size.height : cursor
            e.panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height),
                             display: true, animate: animated)
            cursor += (atTop ? -1 : 1) * (size.height + spacing)
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
        guard configuration.closeAfterAction else { return }
        let id = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.dismiss(id) }
    }
}

// MARK: - View

struct QuickAccessItemView: View {
    @ObservedObject var item: QuickAccessItem
    let thumbSize: CGSize
    let actions: QuickAccessActions
    @State private var hovering = false

    var body: some View {
        ZStack {
            Image(nsImage: item.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: thumbSize.width, height: thumbSize.height)
                .clipped()

            if hovering || item.flash != nil {
                Color.black.opacity(0.5)
            }

            if let flash = item.flash {
                Text(flash).font(.headline).foregroundStyle(.white)
            } else if hovering {
                VStack(spacing: 6) {
                    pill("Copy", actions.copy)
                    pill("Save", actions.save)
                }
                cornerButton("xmark", .topLeading, "Close", actions.close)
                cornerButton("pin.fill", .topTrailing, "Pin to screen", actions.pin)
                cornerButton("pencil.tip.crop.circle", .bottomLeading, "Annotate", actions.annotate)
            }
        }
        .frame(width: thumbSize.width, height: thumbSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .padding(10)
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            actions.hover(h)
        }
        .onDrag {
            if let url = item.ensureFile() {
                let provider = NSItemProvider(object: url as NSURL)
                provider.suggestedName = url.deletingPathExtension().lastPathComponent
                return provider
            }
            return NSItemProvider(object: item.image)
        }
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 74, height: 24)
                .background(Capsule().fill(Color.white))
                .foregroundColor(.black)
        }
        .buttonStyle(.plain)
    }

    private func cornerButton(_ symbol: String, _ alignment: Alignment, _ help: String,
                              _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.9)))
                .foregroundColor(.black)
        }
        .buttonStyle(.plain)
        .help(help)
        .padding(6)
        .frame(width: thumbSize.width, height: thumbSize.height, alignment: alignment)
    }
}
