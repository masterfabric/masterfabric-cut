import SwiftUI
import AVKit
import AppKit

@MainActor
final class TrimModel: ObservableObject {
    let url: URL
    let player: AVPlayer
    @Published var duration: Double = 0
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    @Published var exportProgress: Double?
    @Published var errorMessage: String?
    private var observer: Any?

    init(url: URL) {
        self.url = url
        player = AVPlayer(url: url)
        Task {
            let d = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            duration = d; end = d
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.playhead = t.seconds
                if self.isPlaying && t.seconds >= self.end { self.player.pause(); self.isPlaying = false; self.seek(self.start) }
            }
        }
    }

    deinit { if let o = observer { player.removeTimeObserver(o) } }

    func seek(_ s: Double) {
        player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if isPlaying { player.pause() } else {
            if playhead < start || playhead >= end - 0.05 { seek(start) }
            player.play()
        }
        isPlaying.toggle()
    }

    var range: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600))
    }

    func export(as format: RecordingFormat, to dest: URL, done: @escaping (URL) -> Void) {
        player.pause(); isPlaying = false
        exportProgress = 0
        let src = url, r = range
        Task {
            do {
                let p: @Sendable (Double) -> Void = { v in Task { @MainActor in self.exportProgress = v } }
                switch format {
                case .mp4: try await MediaExporter.exportMP4(source: src, range: r, destination: dest, progress: p)
                case .gif: try await MediaExporter.exportGIF(source: src, range: r, destination: dest, progress: p)
                }
                exportProgress = nil
                done(dest)
            } catch {
                exportProgress = nil
                errorMessage = ErrorPresenter.message(for: error)
            }
        }
    }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {}
}

private struct RangeSlider: View {
    @Binding var start: Double
    @Binding var end: Double
    let playhead: Double
    let duration: Double
    var onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let f: (Double) -> CGFloat = { duration > 0 ? CGFloat($0 / duration) * w : 0 }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.25))
                RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.45))
                    .frame(width: max(0, f(end) - f(start))).offset(x: f(start))
                Rectangle().fill(Color.white).frame(width: 2).offset(x: f(playhead))
                handle.offset(x: f(start) - 5)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        let t = Double(g.location.x / w) * duration
                        start = min(max(0, t), end - 0.1); onScrub(start)
                    })
                handle.offset(x: f(end) - 5)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        let t = Double(g.location.x / w) * duration
                        end = max(min(duration, t), start + 0.1); onScrub(end)
                    })
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onScrub(min(max(0, Double(g.location.x / w) * duration), duration))
            })
        }
        .frame(height: 44)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.yellow).frame(width: 10, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.4)))
    }
}

/// Simple trim editor: preview, drag the yellow handles, export trimmed MP4 or GIF.
public struct TrimEditorView: View {
    @StateObject private var model: TrimModel
    private let onExported: (URL) -> Void
    private let onClose: () -> Void

    public init(url: URL, onExported: @escaping (URL) -> Void = { _ in }, onClose: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: TrimModel(url: url))
        self.onExported = onExported
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 12) {
            PlayerLayerView(player: model.player)
                .frame(minHeight: 260)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            RangeSlider(start: $model.start, end: $model.end, playhead: model.playhead,
                        duration: model.duration, onScrub: model.seek)
            HStack {
                Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }
                    .keyboardShortcut(.space, modifiers: [])
                    .help(model.isPlaying ? "Pause (Space)" : "Play the trimmed range (Space)")
                Text("\(fmt(model.start)) – \(fmt(model.end))  (\(fmt(model.end - model.start)))")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if let p = model.exportProgress {
                    ProgressView(value: p).frame(width: 120)
                } else {
                    Button("Export GIF…") { save(.gif) }.help("Export the trimmed range as an animated GIF")
                    Button("Export MP4…") { save(.mp4) }.keyboardShortcut(.defaultAction).help("Export the trimmed range as an MP4 video")
                }
                Button("Close") { onClose() }.help("Close the trim editor")
            }
            if let e = model.errorMessage { Text(e).foregroundStyle(.red).font(.caption) }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 440)
    }

    private func save(_ format: RecordingFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .mp4 ? .mpeg4Movie : .gif]
        let base = model.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(base) (trimmed).\(format.fileExtension)"
        panel.directoryURL = model.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        model.export(as: format, to: dest, done: onExported)
    }

    private func fmt(_ s: Double) -> String {
        let t = max(0, s)
        return String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}

/// Opens the trim editor in its own window.
@MainActor
public final class TrimEditorWindowController {
    private static var open: [NSWindow] = []

    public static func present(url: URL, onExported: @escaping (URL) -> Void = { _ in }) {
        var window: NSWindow!
        let view = TrimEditorView(url: url, onExported: onExported, onClose: { window?.close() })
        window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Trim — \(url.lastPathComponent)"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 520))
        window.center()
        open.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated { open.removeAll { $0 === window } }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
