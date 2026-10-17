import SwiftUI
import AppKit

struct CaptureHistoryView: View {
    @ObservedObject var store: CaptureHistoryStore
    @State private var filter: CaptureHistoryKind?
    @State private var query = ""
    @State private var hovered: UUID?
    @State private var confirmClear = false
    @State private var durations: [UUID: Double] = [:]

    private var filtered: [CaptureHistoryItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.items.filter { item in
            guard filter == nil || item.kind == filter else { return false }
            guard !q.isEmpty else { return true }
            let hay = [item.text ?? "", item.fileURL?.lastPathComponent ?? "", item.kind.title,
                       item.date.formatted(date: .abbreviated, time: .shortened)].joined(separator: " ").lowercased()
            return hay.contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if filtered.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 20, alignment: .top)], spacing: 20) {
                            ForEach(filtered) { item in card(item) }
                        }
                        .padding(20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("Delete all capture history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { store.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files saved by MasterFabric Cut in its history folder are removed. This can't be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Filter", selection: $filter) {
                Text("All").tag(CaptureHistoryKind?.none)
                ForEach(CaptureHistoryKind.allCases) { Text($0.title).tag(CaptureHistoryKind?.some($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .help("Clear search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minWidth: 120, idealWidth: 220, maxWidth: 220)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
            Button("Clear All…") { confirmClear = true }
                .fixedSize()
                .disabled(store.items.isEmpty)
                .help("Delete every item in the capture history")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: store.items.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass")
                .font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text(store.items.isEmpty ? "No captures yet" : "No matching captures").font(.headline)
            Text(store.items.isEmpty ? "Screenshots, recordings, GIFs and copied text will appear here."
                                     : "Try a different search or filter.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private func card(_ item: CaptureHistoryItem) -> some View {
        let isHover = hovered == item.id
        return VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let thumb = store.thumbnail(for: item) {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).padding(6)
                } else if item.kind == .ocr {
                    Text(item.text ?? "").font(.caption).lineLimit(7).padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Image(systemName: item.kind == .gif ? "photo.stack" : "film")
                        .font(.largeTitle).foregroundStyle(.secondary)
                }
                if isHover, item.kind == .gif, let url = item.fileURL {
                    AnimatedImageView(url: url).padding(6).background(.quaternary)
                }
                if !isHover { playBadge(item) }
                if isHover {
                    Color.black.opacity(0.4)
                    actions(item)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.kind == .recording, let secs = durations[item.id] {
                    Text(MediaDuration.format(secs))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
            }
            .task(id: item.id) {
                if item.kind == .recording, let url = item.fileURL, durations[item.id] == nil {
                    MediaDuration.video(at: url) { durations[item.id] = $0 }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text(title(for: item)).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(item.date, format: .relative(presentation: .named)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.kind.badge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundStyle(Color.accentColor)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(isHover ? 0.2 : 0.06), radius: isHover ? 8 : 3, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
        .animation(.easeOut(duration: 0.12), value: isHover)
        .onTapGesture(count: 2) { open(item) }
        .onDrag { dragProvider(for: item) }
        .contextMenu {
            Button("Open") { open(item) }.disabled(item.fileURL == nil)
            Button("Copy") { copy(item) }
            if item.kind == .screenshot {
                Button("Annotate") { annotate(item) }
                Button("Pin to Screen") { pin(item) }
            }
            if let url = item.fileURL {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
            Button("Delete", role: .destructive) { store.remove(item) }
        }
    }

    @ViewBuilder
    private func playBadge(_ item: CaptureHistoryItem) -> some View {
        if item.kind == .gif || item.kind == .recording {
            Image(systemName: "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                .help(item.kind == .gif ? "Hover to preview, double-click to play" : "Double-click to play")
        }
    }

    private func title(for item: CaptureHistoryItem) -> String {
        if let name = item.fileURL?.lastPathComponent { return name }
        let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Text capture" : String(text.prefix(40))
    }

    private func dragProvider(for item: CaptureHistoryItem) -> NSItemProvider {
        if let url = item.fileURL, let p = NSItemProvider(contentsOf: url) { return p }
        return NSItemProvider(object: (item.text ?? "") as NSString)
    }

    private func actions(_ item: CaptureHistoryItem) -> some View {
        HStack(spacing: 8) {
            if item.fileURL != nil { actionButton("arrow.up.right.square", "Open") { open(item) } }
            actionButton("doc.on.doc", "Copy") { copy(item) }
            if let url = item.fileURL {
                actionButton("folder", "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            if item.kind == .screenshot { actionButton("pin", "Pin to Screen") { pin(item) } }
            actionButton("trash", "Delete") { store.remove(item) }
        }
    }

    private func actionButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func open(_ item: CaptureHistoryItem) {
        guard let url = item.fileURL else { return }
        if item.kind == .gif || item.kind == .recording {
            MediaPlayerWindowController.show(item: item, store: store)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func copy(_ item: CaptureHistoryItem) {
        if let text = item.text {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } else if let img = store.image(for: item) {
            AnnotateImageUtil.copyToPasteboard(img)
        } else if let url = item.fileURL {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        }
    }

    private func annotate(_ item: CaptureHistoryItem) {
        if let img = store.image(for: item) { AnnotationEditorWindowController.open(image: img, sourceURL: item.fileURL) }
    }

    private func pin(_ item: CaptureHistoryItem) {
        if let img = store.image(for: item) { PinnedScreenshotController.shared.pin(image: img) }
    }
}

final class CaptureHistoryWindowController: NSWindowController {
    static let shared = CaptureHistoryWindowController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Capture History"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: CaptureHistoryView(store: .shared))
        // The window owns its size; SwiftUI must not resize it to the content.
        host.sizingOptions = []
        window.contentView = host
        window.contentMinSize = NSSize(width: 860, height: 560)
        window.setContentSize(NSSize(width: 960, height: 640))
        window.setFrameAutosaveName("CaptureHistoryWindow.v2")
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
