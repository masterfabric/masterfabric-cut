import SwiftUI
import AppKit

struct CaptureHistoryView: View {
    @ObservedObject var store: CaptureHistoryStore
    @State private var filter: CaptureHistoryKind?
    @State private var query = ""
    @State private var hovered: UUID?
    @State private var confirmClear = false

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
            toolbar
            Divider()
            ZStack {
                if filtered.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 16)], spacing: 16) {
                            ForEach(filtered) { item in cell(item) }
                        }
                        .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, idealWidth: 780, minHeight: 360, idealHeight: 540)
        .background(.regularMaterial)
        .confirmationDialog("Delete all capture history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { store.clear() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $filter) {
                Text("All").tag(CaptureHistoryKind?.none)
                ForEach(CaptureHistoryKind.allCases) { Text($0.title).tag(CaptureHistoryKind?.some($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(width: 180)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
            Button("Clear All…") { confirmClear = true }
                .disabled(store.items.isEmpty)
                .help("Delete every item in the capture history")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: store.items.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass")
                .font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text(store.items.isEmpty ? "No captures yet" : "No matching captures").font(.headline)
            Text(store.items.isEmpty ? "Screenshots, recordings and copied text will appear here."
                                     : "Try a different search or filter.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private func cell(_ item: CaptureHistoryItem) -> some View {
        let isHover = hovered == item.id
        return VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(Color.primary.opacity(0.08))
                if let thumb = store.thumbnail(for: item) {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else if item.kind == .ocr {
                    Text(item.text ?? "").font(.caption).lineLimit(6).padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                }
                if isHover {
                    Color.black.opacity(0.35)
                    actions(item)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 124)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(isHover ? 0.2 : 0.08), radius: isHover ? 8 : 3, y: 2)
            HStack(spacing: 4) {
                Text(item.date.formatted(date: .abbreviated, time: .shortened)).lineLimit(1)
                Spacer(minLength: 4)
                if item.kind != .screenshot { Text(item.kind.title).foregroundStyle(.secondary) }
            }
            .font(.caption2)
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
        .animation(.easeOut(duration: 0.12), value: isHover)
        .onTapGesture(count: 2) { open(item) }
        .contextMenu {
            Button("Open") { open(item) }
            Button("Copy") { copy(item) }
            if item.kind == .screenshot {
                Button("Annotate") { annotate(item) }
                Button("Pin to Screen") { pin(item) }
            }
            if let url = item.fileURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
            Button("Delete", role: .destructive) { store.remove(item) }
        }
    }

    private func actions(_ item: CaptureHistoryItem) -> some View {
        HStack(spacing: 8) {
            if item.fileURL != nil { actionButton("arrow.up.right.square", "Open") { open(item) } }
            actionButton("doc.on.doc", "Copy") { copy(item) }
            if let url = item.fileURL {
                actionButton("folder", "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            actionButton("trash", "Delete") { store.remove(item) }
        }
    }

    private func actionButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func open(_ item: CaptureHistoryItem) {
        if let url = item.fileURL { NSWorkspace.shared.open(url) }
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Capture History"
        window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: CaptureHistoryView(store: .shared))
        // Keep SwiftUI from resizing the window to its content.
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: 780, height: 540))
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.setFrameAutosaveName("CaptureHistoryWindow")
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
