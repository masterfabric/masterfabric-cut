import AppKit
import UniformTypeIdentifiers

/// Output formats supported by the Annotate module when encoding images.
enum AnnotateOutputFormat: String, CaseIterable, Identifiable {
    case png, jpeg, tiff

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        }
    }

    var fileType: NSBitmapImageRep.FileType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        }
    }

    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        }
    }

    static func format(forExtension ext: String) -> AnnotateOutputFormat {
        switch ext.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "tif", "tiff": return .tiff
        default: return .png
        }
    }
}

/// Shared image helpers (conversion, encoding, pasteboard, file naming).
enum AnnotateImageUtil {
    /// Best-resolution CGImage for an NSImage.
    static func cgImage(from image: NSImage) -> CGImage? {
        var best: CGImage?
        var bestPixels = 0
        for rep in image.representations {
            if let bitmap = rep as? NSBitmapImageRep, let cg = bitmap.cgImage, cg.width * cg.height > bestPixels {
                best = cg
                bestPixels = cg.width * cg.height
            }
        }
        if let best { return best }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Pixels per point of the source image.
    static func scale(of image: NSImage, cg: CGImage) -> CGFloat {
        guard image.size.width > 0 else { return 1 }
        return max(1, CGFloat(cg.width) / image.size.width)
    }

    static func nsImage(from cg: CGImage, scale: CGFloat = 1) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }

    static func data(from cg: CGImage, format: AnnotateOutputFormat, quality: CGFloat = 0.9) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cg)
        var props: [NSBitmapImageRep.PropertyKey: Any] = [:]
        if format == .jpeg { props[.compressionFactor] = quality }
        return rep.representation(using: format.fileType, properties: props)
    }

    static func data(from image: NSImage, format: AnnotateOutputFormat, quality: CGFloat = 0.9) -> Data? {
        guard let cg = cgImage(from: image) else { return nil }
        return data(from: cg, format: format, quality: quality)
    }

    static func copyToPasteboard(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = data(from: image, format: .png) {
            pb.setData(png, forType: .png)
        }
        if let tiff = image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    static func defaultFileName(prefix: String = "MasterFabric Cut") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(f.string(from: Date()))"
    }

    static func uniqueURL(in directory: URL, baseName: String, ext: String) -> URL {
        var url = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(baseName) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    /// Encodes and writes `image` into `directory` with a timestamped, unique name.
    @discardableResult
    static func write(_ image: NSImage, to directory: URL, format: AnnotateOutputFormat = .png,
                      prefix: String = "MasterFabric Cut") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = data(from: image, format: format) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = uniqueURL(in: directory, baseName: defaultFileName(prefix: prefix), ext: format.fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    static var desktopDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }
}
