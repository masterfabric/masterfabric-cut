// MasterFabric Cut — Tools module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ConvertFormat: String, CaseIterable, Identifiable {
    case png, jpeg, heic, tiff, webp
    var id: String { rawValue }
    var title: String { self == .jpeg ? "JPG" : rawValue.uppercased() }
    var ext: String { self == .jpeg ? "jpg" : rawValue }
    var uti: String {
        switch self {
        case .png: return UTType.png.identifier
        case .jpeg: return UTType.jpeg.identifier
        case .heic: return UTType.heic.identifier
        case .tiff: return UTType.tiff.identifier
        case .webp: return "org.webmproject.webp"
        }
    }
    var isLossy: Bool { self == .jpeg || self == .heic || self == .webp }

    /// Formats ImageIO can write on this Mac (WebP writing is not available on every macOS).
    static let writable: [ConvertFormat] = {
        let ids = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return allCases.filter { ids.contains($0.uti) }
    }()
}

enum ResizeMode: String, CaseIterable, Identifiable {
    case none, maxDimension, percent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Original size"
        case .maxDimension: return "Max dimension"
        case .percent: return "Percentage"
        }
    }
}

struct ConvertJob: Identifiable, Equatable {
    enum Status: Equatable { case pending, working, done(URL), failed(String) }
    let id = UUID()
    let url: URL
    var pixelSize: CGSize?
    var status: Status = .pending
}

struct ConvertOptions: Sendable {
    var format: ConvertFormat
    var quality: Double
    var resize: ResizeMode
    var maxDimension: Int
    var percent: Double
    var folder: URL?
}

@MainActor
final class ImageConverterModel: ObservableObject {
    @Published var jobs: [ConvertJob] = []
    @Published var format: ConvertFormat = ConvertFormat.writable.contains(.jpeg) ? .jpeg : (ConvertFormat.writable.first ?? .png)
    @Published var quality = 0.85
    @Published var resize: ResizeMode = .none
    @Published var maxDimension = 1920
    @Published var percent = 50.0
    @Published var saveNextToOriginal = true
    @Published var folder: URL?
    @Published var busy = false
    @Published var status: String?

    static let readableTypes: [UTType] = [.image, .heic, .png, .jpeg, .tiff, .gif, .bmp, UTType("org.webmproject.webp")].compactMap { $0 }

    func add(_ urls: [URL]) {
        let known = Set(jobs.map(\.url))
        for u in urls where !known.contains(u) {
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil), CGImageSourceGetCount(src) > 0 else { continue }
            var job = ConvertJob(url: u)
            if let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
                job.pixelSize = CGSize(width: w, height: h)
            }
            jobs.append(job)
        }
        status = nil
    }

    func chooseFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = Self.readableTypes
        p.message = "Choose images to convert"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { add(p.urls) }
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { folder = u; saveNextToOriginal = false }
    }

    func convertAll() {
        guard !jobs.isEmpty, !busy else { return }
        if !saveNextToOriginal && folder == nil { chooseFolder(); if folder == nil { return } }
        let opts = ConvertOptions(format: format, quality: quality, resize: resize, maxDimension: maxDimension,
                                  percent: percent, folder: saveNextToOriginal ? nil : folder)
        busy = true
        status = nil
        for i in jobs.indices { jobs[i].status = .working }
        let work = jobs
        Task.detached(priority: .userInitiated) {
            var results: [UUID: ConvertJob.Status] = [:]
            for job in work {
                do { results[job.id] = .done(try ImageConverter.convert(job.url, options: opts)) }
                catch { results[job.id] = .failed(error.localizedDescription) }
            }
            let finished = results
            await MainActor.run {
                let results = finished
                for i in self.jobs.indices { if let r = results[self.jobs[i].id] { self.jobs[i].status = r } }
                let ok = results.values.filter { if case .done = $0 { return true }; return false }.count
                self.busy = false
                self.status = "Converted \(ok) of \(results.count) image\(results.count == 1 ? "" : "s") to \(opts.format.title)"
                if ok > 0 { Toast.show("Converted \(ok) image\(ok == 1 ? "" : "s")", symbol: "photo.on.rectangle.angled", tint: .teal) }
            }
        }
    }

    func reveal() {
        let urls = jobs.compactMap { if case .done(let u) = $0.status { return u }; return nil }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

enum ImageConverterError: LocalizedError {
    case unreadable, writeFailed(String)
    var errorDescription: String? {
        switch self {
        case .unreadable: return "Couldn't read the image"
        case .writeFailed(let f): return "Couldn't write \(f)"
        }
    }
}

/// ImageIO-only conversion: orientation is applied, animated images use their first frame,
/// JPEG output is flattened on white (no alpha).
enum ImageConverter {
    static func convert(_ url: URL, options o: ConvertOptions) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { throw ImageConverterError.unreadable }
        let longest = max(w, h)
        let target: Int
        switch o.resize {
        case .none: target = longest
        case .maxDimension: target = min(longest, max(1, o.maxDimension))
        case .percent: target = max(1, Int((Double(longest) * o.percent / 100).rounded()))
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else { throw ImageConverterError.unreadable }
        if o.format == .jpeg, let flat = flatten(image) { image = flat }

        let dir = o.folder ?? url.deletingLastPathComponent()
        let out = uniqueURL(dir: dir, base: url.deletingPathExtension().lastPathComponent, ext: o.format.ext, source: url)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, o.format.uti as CFString, 1, nil) else {
            throw ImageConverterError.writeFailed(out.lastPathComponent)
        }
        var destProps: [CFString: Any] = [:]
        if o.format.isLossy { destProps[kCGImageDestinationLossyCompressionQuality] = o.quality }
        if let dpi = props[kCGImagePropertyDPIWidth] { destProps[kCGImagePropertyDPIWidth] = dpi; destProps[kCGImagePropertyDPIHeight] = props[kCGImagePropertyDPIHeight] ?? dpi }
        CGImageDestinationAddImage(dest, image, destProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageConverterError.writeFailed(out.lastPathComponent) }
        return out
    }

    private static func flatten(_ image: CGImage) -> CGImage? {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white); ctx.fill(r)
        ctx.draw(image, in: r)
        return ctx.makeImage()
    }

    private static func uniqueURL(dir: URL, base: String, ext: String, source: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        if !fm.fileExists(atPath: candidate.path) && candidate.standardizedFileURL != source.standardizedFileURL { return candidate }
        candidate = dir.appendingPathComponent("\(base)-converted.\(ext)")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-converted-\(n).\(ext)"); n += 1
        }
        return candidate
    }
}

@MainActor
enum ImageConverterTool {
    static let model = ImageConverterModel()
    static func show() {
        ToolWindows.show("imageConverter", title: "Image Converter", resizable: true) { ImageConverterView(model: model) }
    }
}

struct ImageConverterView: View {
    @ObservedObject var model: ImageConverterModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolHeader(symbol: "photo.on.rectangle.angled", tint: .teal, title: "Image Converter",
                       subtitle: "HEIC, PNG, JPG, TIFF — resize and convert in batches")
            fileList
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Format").foregroundStyle(.secondary)
                    Picker("", selection: $model.format) {
                        ForEach(ConvertFormat.writable) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
                }
                if model.format.isLossy {
                    GridRow {
                        Text("Quality").foregroundStyle(.secondary)
                        HStack {
                            Slider(value: $model.quality, in: 0.3...1).frame(maxWidth: 220)
                            Text("\(Int(model.quality * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                GridRow {
                    Text("Resize").foregroundStyle(.secondary)
                    HStack {
                        Picker("", selection: $model.resize) { ForEach(ResizeMode.allCases) { Text($0.title).tag($0) } }
                            .labelsHidden().frame(width: 150)
                        switch model.resize {
                        case .none: EmptyView()
                        case .maxDimension:
                            TextField("px", value: $model.maxDimension, format: .number).frame(width: 70)
                            Text("px longest side").foregroundStyle(.secondary)
                        case .percent:
                            Slider(value: $model.percent, in: 5...100, step: 5).frame(width: 140)
                            Text("\(Int(model.percent))%").monospacedDigit()
                        }
                    }
                }
                GridRow {
                    Text("Save to").foregroundStyle(.secondary)
                    HStack {
                        Picker("", selection: $model.saveNextToOriginal) {
                            Text("Next to originals").tag(true)
                            Text(model.folder?.lastPathComponent ?? "Folder…").tag(false)
                        }
                        .labelsHidden().frame(width: 170)
                        Button("Choose…") { model.chooseFolder() }
                    }
                }
            }
            .font(.system(size: 12))
            if !ConvertFormat.writable.contains(.webp) {
                Text("WebP files can be opened, but this macOS can't write WebP. Animated images convert to their first frame.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            HStack {
                if let s = model.status { ToolStatus(text: s, isError: false) }
                Spacer()
                Button("Show in Finder") { model.reveal() }
                    .disabled(!model.jobs.contains { if case .done = $0.status { return true }; return false })
                Button { model.convertAll() } label: {
                    Label(model.busy ? "Converting…" : "Convert \(model.jobs.count)", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent).tint(.teal)
                .disabled(model.jobs.isEmpty || model.busy)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(18)
        .frame(minWidth: 560, idealWidth: 580, minHeight: 470, idealHeight: 500)
    }

    private var fileList: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dropTargeted ? Color.teal : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: model.jobs.isEmpty ? [6, 4] : []))
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if model.jobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.stack").font(.system(size: 30)).foregroundStyle(.teal)
                    Text("Drop images here").font(.system(size: 13, weight: .semibold))
                    Button("Choose Images…") { model.chooseFiles() }
                }
            } else {
                VStack(spacing: 0) {
                    List {
                        ForEach(model.jobs) { job in
                            HStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: job.url.path)).resizable().frame(width: 20, height: 20)
                                Text(job.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                if let s = job.pixelSize { Text("\(Int(s.width))×\(Int(s.height))").foregroundStyle(.secondary).monospacedDigit() }
                                Spacer()
                                statusView(job.status)
                            }
                            .font(.system(size: 12))
                        }
                        .onDelete { model.jobs.remove(atOffsets: $0) }
                    }
                    .scrollContentBackground(.hidden)
                    HStack {
                        Button("Add…") { model.chooseFiles() }
                        Button("Clear") { model.jobs.removeAll(); model.status = nil }.disabled(model.busy)
                        Spacer()
                    }
                    .buttonStyle(.borderless).font(.system(size: 11)).padding(8)
                }
            }
        }
        .frame(minHeight: 160)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.add([url]) } }
                }
            }
            return true
        }
    }

    @ViewBuilder private func statusView(_ s: ConvertJob.Status) -> some View {
        switch s {
        case .pending: EmptyView()
        case .working: ProgressView().controlSize(.mini)
        case .done(let u):
            Button { NSWorkspace.shared.activateFileViewerSelecting([u]) } label: {
                Label(u.lastPathComponent, systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless).foregroundStyle(.green).lineLimit(1)
        case .failed(let e): Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1)
        }
    }
}
