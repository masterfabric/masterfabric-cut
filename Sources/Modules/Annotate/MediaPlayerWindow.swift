import SwiftUI
import AppKit
import AVFoundation
import AVKit
import ImageIO

// MARK: - Helpers

enum MediaDuration {
    private static let cache = NSCache<NSString, NSNumber>()

    /// Video duration in seconds, cached by path. Calls back on the main thread.
    static func video(at url: URL, completion: @escaping (Double?) -> Void) {
        if let hit = cache.object(forKey: url.path as NSString) { return completion(hit.doubleValue) }
        Task {
            let secs = try? await AVURLAsset(url: url).load(.duration).seconds
            await MainActor.run {
                if let secs, secs.isFinite { cache.setObject(NSNumber(value: secs), forKey: url.path as NSString) }
                completion(secs.flatMap { $0.isFinite ? $0 : nil })
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Decoded frames of an animated GIF.
struct GIFFrames {
    var images: [NSImage] = []
    var delays: [Double] = []
    var duration: Double { delays.reduce(0, +) }

    init(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        for i in 0..<CGImageSourceGetCount(src) {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            images.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double).flatMap { $0 > 0 ? $0 : nil }
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            delays.append(max(0.02, d))
        }
    }
}

/// Self-animating image used for hover previews in the history grid.
struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.animates = true
        v.image = NSImage(contentsOf: url)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {}
}

private struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {}
}

// MARK: - GIF model

final class GIFPlayerModel: ObservableObject {
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = true
    @Published var loops = true

    let frames: GIFFrames
    private var timer: Timer?

    init(url: URL) {
        frames = GIFFrames(url: url)
        scheduleNext()
    }

    deinit { timer?.invalidate() }

    var count: Int { frames.images.count }
    var current: NSImage? { frames.images.indices.contains(index) ? frames.images[index] : nil }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            if !loops, index >= count - 1 { index = 0 }
            isPlaying = true
            scheduleNext()
        }
    }

    func pause() {
        isPlaying = false
        timer?.invalidate()
    }

    func seek(to frame: Int) {
        pause()
        index = min(max(0, frame), max(0, count - 1))
    }

    private func scheduleNext() {
        timer?.invalidate()
        guard isPlaying, count > 1 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: frames.delays[index], repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.index + 1 < self.count {
                self.index += 1
            } else if self.loops {
                self.index = 0
            } else {
                self.isPlaying = false
                return
            }
            self.scheduleNext()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
}

// MARK: - Player view

struct MediaPlayerView: View {
    let item: CaptureHistoryItem
    let url: URL
    let onDelete: () -> Void

    @StateObject private var gif: GIFPlayerModel
    @State private var player: AVPlayer?
    @State private var duration: Double?

    init(item: CaptureHistoryItem, url: URL, onDelete: @escaping () -> Void) {
        self.item = item
        self.url = url
        self.onDelete = onDelete
        _gif = StateObject(wrappedValue: GIFPlayerModel(url: url))
    }

    private var isGIF: Bool { item.kind == .gif }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.85)
                if isGIF {
                    if let img = gif.current {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(8)
                    }
                } else if let player {
                    VideoPlayerView(player: player)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .padding([.horizontal, .top], 16)

            if isGIF { gifControls.padding(.horizontal, 16).padding(.top, 10) }
            actionBar.padding(16)
        }
        .frame(minWidth: 520, minHeight: 400)
        .background(.regularMaterial)
        .onAppear {
            if !isGIF {
                let p = AVPlayer(url: url)
                player = p
                p.play()
            }
        }
        .onDisappear {
            player?.pause()
            gif.pause()
        }
    }

    private var gifControls: some View {
        HStack(spacing: 12) {
            circleButton(gif.isPlaying ? "pause.fill" : "play.fill", gif.isPlaying ? "Pause" : "Play") { gif.togglePlay() }
            Slider(value: Binding(get: { Double(gif.index) },
                                  set: { gif.seek(to: Int($0.rounded())) }),
                   in: 0...Double(max(1, gif.count - 1)))
                .disabled(gif.count < 2)
                .help("Scrub through frames")
            Text("\(gif.index + 1) / \(gif.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
            Toggle(isOn: $gif.loops) { Image(systemName: "repeat") }
                .toggleStyle(.button)
                .help(gif.loops ? "Loop: on" : "Loop: off")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help(isGIF ? "Copy the GIF to the clipboard" : "Copy the video file to the clipboard")
            Button { saveAs() } label: { Label("Save As…", systemImage: "square.and.arrow.down") }
                .help("Save a copy to another location")
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Label("Reveal", systemImage: "folder")
            }
            .help("Reveal in Finder")
            Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
                .help("Delete from capture history")
        }
        .task {
            guard !isGIF else { return }
            MediaDuration.video(at: url) { duration = $0 }
        }
    }

    private var subtitle: String {
        var parts = [item.kind.badge]
        if item.pixelWidth > 0 { parts.append("\(item.pixelWidth)×\(item.pixelHeight)") }
        if isGIF, gif.frames.duration > 0 { parts.append(String(format: "%.1fs", gif.frames.duration)) }
        if let duration { parts.append(MediaDuration.format(duration)) }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private func circleButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
    }
}

// MARK: - Window

final class MediaPlayerWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [UUID: MediaPlayerWindowController] = [:]

    static func show(item: CaptureHistoryItem, store: CaptureHistoryStore) {
        guard let url = item.fileURL else { return }
        if let existing = open[item.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = MediaPlayerWindowController(item: item, url: url, store: store)
        open[item.id] = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let itemID: UUID

    private init(item: CaptureHistoryItem, url: URL, store: CaptureHistoryStore) {
        itemID = item.id
        var size = NSSize(width: 720, height: 560)
        if item.pixelWidth > 0, item.pixelHeight > 0 {
            let w = min(max(CGFloat(item.pixelWidth) / 2, 560), 960)
            let h = min(max(w * CGFloat(item.pixelHeight) / CGFloat(item.pixelWidth) + 130, 420), 720)
            size = NSSize(width: w, height: h)
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = item.kind == .gif ? "GIF Player" : "Video Player"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 400)
        super.init(window: window)
        window.delegate = self
        let view = MediaPlayerView(item: item, url: url) { [weak self] in
            store.remove(item)
            self?.window?.close()
        }
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(size)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        Self.open[itemID] = nil
    }
}
