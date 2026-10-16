import AppKit
import UniformTypeIdentifiers

extension NSImage {
    /// Encoded data in the user's preferred format.
    func encoded(as format: ImageFormat, quality: Double = 0.9) -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpg: return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        case .tiff: return rep.representation(using: .tiff, properties: [:])
        }
    }
}

enum FileOutput {
    /// Saves an image to the configured folder; returns the file URL.
    @discardableResult
    static func save(_ image: NSImage, settings: AppSettings = .shared) -> URL? {
        guard let data = image.encoded(as: settings.imageFormat, quality: settings.jpegQuality) else { return nil }
        let url = settings.saveDirectory.appendingPathComponent(settings.makeFilename(ext: settings.imageFormat.fileExtension))
        do { try data.write(to: url); return url } catch { NSLog("Save failed: \(error)"); return nil }
    }

    static func copy(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}

enum DesktopIcons {
    static func setHidden(_ hidden: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["write", "com.apple.finder", "CreateDesktop", "-bool", hidden ? "false" : "true"]
        try? p.run(); p.waitUntilExit()
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        k.arguments = ["Finder"]
        try? k.run()
        AppSettings.shared.hideDesktopIcons = hidden
    }
}
