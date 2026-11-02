import AppKit
import SwiftUI
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


// MARK: - Brand

/// Full-color MasterFabric app icon, shown next to the product name in UI.
struct BrandIcon: View {
    var size: CGFloat = 24
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable().interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// App icon + "MasterFabric Cut" wordmark.
struct BrandHeader: View {
    var iconSize: CGFloat = 24
    var font: Font = .system(size: 14, weight: .semibold)
    var body: some View {
        HStack(spacing: 8) {
            BrandIcon(size: iconSize)
            Text("MasterFabric Cut").font(font)
        }
    }
}

/// Scissors SF Symbol template image for the menu bar; draws a red dot while recording.
enum MenuBarIcon {
    /// `recording` adds a red dot (top right); `awake` (Keep Awake on) adds a small orange cup (bottom right).
    static func image(recording: Bool, awake: Bool = false) -> NSImage {
        let base = NSImage(systemSymbolName: "scissors", accessibilityDescription: "MasterFabric Cut") ?? NSImage()
        guard recording || awake else {
            base.isTemplate = true
            return base
        }
        // Template images are tinted as a whole, so the badged variants are non-template.
        let size = NSSize(width: base.size.width + (awake ? 4 : 0), height: base.size.height)
        let out = NSImage(size: size, flipped: false) { rect in
            let mark = NSImage(size: base.size, flipped: false) { r in
                base.draw(in: r)
                NSColor.labelColor.set(); r.fill(using: .sourceIn); return true
            }
            mark.draw(in: NSRect(origin: .zero, size: base.size))
            if recording {
                let d: CGFloat = 6
                let dot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
                NSColor.systemRed.setFill(); NSBezierPath(ovalIn: dot).fill()
            }
            if awake, let cup = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .bold)) {
                let c = NSImage(size: cup.size, flipped: false) { r in
                    cup.draw(in: r); NSColor.systemOrange.set(); r.fill(using: .sourceIn); return true
                }
                c.draw(in: NSRect(x: rect.maxX - cup.size.width, y: rect.minY, width: cup.size.width, height: cup.size.height))
            }
            return true
        }
        out.isTemplate = false
        out.accessibilityDescription = recording ? "MasterFabric Cut (recording)" : "MasterFabric Cut (keeping the Mac awake)"
        return out
    }
}
