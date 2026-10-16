import SwiftUI
import AppKit

struct CaptureHistoryView: View {
    @ObservedObject var store: CaptureHistoryStore
    @State private var filter: CaptureHistoryKind?
    @State private var confirmClear = false

    private var filtered: [CaptureHistoryItem] {
        store.items.filter { filter == nil || $0.kind == filter }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    Text("All").tag(CaptureHistoryKind?.none)
                    ForEach(CaptureHistoryKind.allCases) { Text($0.title).tag(CaptureHistoryKind?.some($0)) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Spacer()
                Button("Clear All…") { confirmClear = true }.disabled(store.items.isEmpty)
            }
            .padding(10)
            Divider()
            if filtered.isEmpty {
                Spacer()
                Text("No captures yet").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 12)], spacing: 12) {
                        ForEach(filtered) { item in cell(item) }
                    }
                    .padding(12)
                }
            }
        }
        .confirmationDialog("Delete all capture history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { store.clear() }
        }
    }

    private func cell(_ item: CaptureHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
                if let thumb = store.thumbnail(for: item) {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else if item.kind == .ocr {
                    Text(item.text ?? "").font(.caption).lineLimit(6).padding(8)
                } else {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(item.date, style: .date)
                Text(item.date, style: .time)
                Spacer()
                if item.kind != .screenshot { Text(item.kind.title).foregroundStyle(.secondary) }
            }
            .font(.caption2)
        }
        .contentShape(Rectangle())
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
        window.minSize = NSSize(width: 480, height: 320)
        window.contentView = NSHostingView(rootView: CaptureHistoryView(store: .shared))
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
