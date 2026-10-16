import AppKit
import AVFoundation
import SQLite3

enum CaptureHistoryKind: String, Codable, CaseIterable, Identifiable {
    case screenshot, recording, gif, ocr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshot: return "Screenshots"
        case .recording: return "Recordings"
        case .gif: return "GIFs"
        case .ocr: return "Text"
        }
    }
}

struct CaptureHistoryItem: Identifiable, Codable, Hashable {
    var id: UUID
    var date: Date
    var kind: CaptureHistoryKind
    /// Absolute path of the media file (empty for OCR text items).
    var filePath: String
    var thumbnailFileName: String?
    var pixelWidth: Int
    var pixelHeight: Int
    var text: String?

    var fileURL: URL? { filePath.isEmpty ? nil : URL(fileURLWithPath: filePath) }
}

/// Persistent capture history stored in Application Support. Call from the main thread.
final class CaptureHistoryStore: ObservableObject {
    static let shared = CaptureHistoryStore()

    @Published private(set) var items: [CaptureHistoryItem] = []
    /// Oldest entries beyond this count are dropped.
    var maxItems = 200 { didSet { trim() } }

    let directory: URL
    private var itemsDirectory: URL { directory.appendingPathComponent("Items", isDirectory: true) }
    private var thumbsDirectory: URL { directory.appendingPathComponent("Thumbnails", isDirectory: true) }
    private var legacyIndexURL: URL { directory.appendingPathComponent("index.json") }
    private let db = Database.shared
    private let thumbCache = NSCache<NSString, NSImage>()

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("MasterFabric Cut/History", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbsDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: Adding

    /// Stores a copy of the screenshot in the history folder.
    @discardableResult
    func addScreenshot(_ image: NSImage, format: AnnotateOutputFormat = .png) -> CaptureHistoryItem? {
        guard let cg = AnnotateImageUtil.cgImage(from: image),
              let data = AnnotateImageUtil.data(from: cg, format: format) else { return nil }
        let id = UUID()
        let url = itemsDirectory.appendingPathComponent("\(id.uuidString).\(format.fileExtension)")
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        let item = CaptureHistoryItem(id: id, date: Date(), kind: .screenshot, filePath: url.path,
                                      thumbnailFileName: writeThumbnail(cg, id: id),
                                      pixelWidth: cg.width, pixelHeight: cg.height, text: nil)
        insert(item)
        return item
    }

    /// Registers an existing file (video or GIF) without copying it.
    func addFile(at url: URL, kind: CaptureHistoryKind) {
        let id = UUID()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cg = Self.makeThumbnailSource(for: url, kind: kind)
            DispatchQueue.main.async {
                guard let self else { return }
                let item = CaptureHistoryItem(id: id, date: Date(), kind: kind, filePath: url.path,
                                              thumbnailFileName: cg.flatMap { self.writeThumbnail($0, id: id) },
                                              pixelWidth: cg?.width ?? 0, pixelHeight: cg?.height ?? 0, text: nil)
                self.insert(item)
            }
        }
    }

    func addOCRText(_ text: String) {
        insert(CaptureHistoryItem(id: UUID(), date: Date(), kind: .ocr, filePath: "", thumbnailFileName: nil,
                                  pixelWidth: 0, pixelHeight: 0, text: text))
    }

    // MARK: Removing

    func remove(_ item: CaptureHistoryItem) {
        delete(item)
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.forEach(delete)
        items.removeAll()
        save()
    }

    // MARK: Lookup

    func thumbnail(for item: CaptureHistoryItem) -> NSImage? {
        guard let name = item.thumbnailFileName else { return nil }
        if let cached = thumbCache.object(forKey: name as NSString) { return cached }
        guard let img = NSImage(contentsOf: thumbsDirectory.appendingPathComponent(name)) else { return nil }
        thumbCache.setObject(img, forKey: name as NSString)
        return img
    }

    func image(for item: CaptureHistoryItem) -> NSImage? {
        guard item.kind == .screenshot || item.kind == .gif, let url = item.fileURL else { return nil }
        return NSImage(contentsOf: url)
    }

    // MARK: Internals

    private func insert(_ item: CaptureHistoryItem) {
        items.insert(item, at: 0)
        trim()
        save()
    }

    private func trim() {
        guard items.count > maxItems else { return }
        items[maxItems...].forEach(delete)
        items.removeLast(items.count - maxItems)
        save()
    }

    private func isManaged(_ item: CaptureHistoryItem) -> Bool {
        item.filePath.hasPrefix(itemsDirectory.path)
    }

    private func delete(_ item: CaptureHistoryItem) {
        if isManaged(item) { try? FileManager.default.removeItem(atPath: item.filePath) }
        if let t = item.thumbnailFileName {
            thumbCache.removeObject(forKey: t as NSString)
            try? FileManager.default.removeItem(at: thumbsDirectory.appendingPathComponent(t))
        }
    }

    private func load() {
        importLegacyIndexIfNeeded()
        var loaded: [CaptureHistoryItem] = []
        db.run("SELECT id, date, kind, file_path, thumbnail_path, width, height, text FROM history ORDER BY date DESC") { s in
            guard let id = Database.text(s, 0).flatMap(UUID.init(uuidString:)),
                  let kind = Database.text(s, 2).flatMap(CaptureHistoryKind.init(rawValue:)) else { return }
            loaded.append(CaptureHistoryItem(
                id: id, date: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)), kind: kind,
                filePath: Database.text(s, 3) ?? "",
                thumbnailFileName: Database.text(s, 4).map { ($0 as NSString).lastPathComponent },
                pixelWidth: Int(sqlite3_column_int(s, 5)), pixelHeight: Int(sqlite3_column_int(s, 6)),
                text: Database.text(s, 7)))
        }
        items = loaded.filter { $0.kind == .ocr || FileManager.default.fileExists(atPath: $0.filePath) }
        let gone = loaded.filter { l in !items.contains { $0.id == l.id } }
        gone.forEach { db.run("DELETE FROM history WHERE id = ?1", [.text($0.id.uuidString)]) }
    }

    /// One-time import of the old `index.json` into SQLite; the JSON is renamed afterwards.
    private func importLegacyIndexIfNeeded() {
        guard let data = try? Data(contentsOf: legacyIndexURL),
              let old = try? JSONDecoder().decode([CaptureHistoryItem].self, from: data) else { return }
        db.transaction { old.forEach(upsert) }
        try? FileManager.default.moveItem(at: legacyIndexURL, to: directory.appendingPathComponent("index.json.migrated"))
    }

    private func upsert(_ i: CaptureHistoryItem) {
        db.run("""
            INSERT OR REPLACE INTO history(id, date, kind, file_path, thumbnail_path, width, height, text)
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            """, [.text(i.id.uuidString), .double(i.date.timeIntervalSince1970), .text(i.kind.rawValue), .text(i.filePath),
                  i.thumbnailFileName.map { .text(thumbsDirectory.appendingPathComponent($0).path) } ?? .null,
                  .int(Int64(i.pixelWidth)), .int(Int64(i.pixelHeight)), i.text.map { .text($0) } ?? .null])
    }

    private func save() {
        db.transaction {
            db.run("DELETE FROM history")
            items.forEach(upsert)
        }
    }

    private func writeThumbnail(_ cg: CGImage, id: UUID) -> String? {
        let maxSide: CGFloat = 400
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let w = max(1, Int(CGFloat(cg.width) * scale)), h = max(1, Int(CGFloat(cg.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage(),
              let data = AnnotateImageUtil.data(from: small, format: .jpeg, quality: 0.8) else { return nil }
        let name = "\(id.uuidString).jpg"
        do { try data.write(to: thumbsDirectory.appendingPathComponent(name), options: .atomic) } catch { return nil }
        return name
    }

    private static func makeThumbnailSource(for url: URL, kind: CaptureHistoryKind) -> CGImage? {
        switch kind {
        case .recording:
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 800, height: 800)
            return try? gen.copyCGImage(at: .zero, actualTime: nil)
        case .gif, .screenshot:
            return NSImage(contentsOf: url).flatMap { AnnotateImageUtil.cgImage(from: $0) }
        case .ocr:
            return nil
        }
    }
}
