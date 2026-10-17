import AppKit
import Combine

enum AnnotationKind: String {
    case arrow, line, rectangle, ellipse, text, highlighter, pencil, blur, pixelate, step, spotlight
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, text, highlighter, pencil, blur, pixelate, step, spotlight, crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .text: return "Text"
        case .highlighter: return "Highlighter"
        case .pencil: return "Pencil"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .step: return "Numbered Step"
        case .spotlight: return "Spotlight"
        case .crop: return "Crop"
        }
    }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .highlighter: return "highlighter"
        case .pencil: return "pencil"
        case .blur: return "eye.slash"
        case .pixelate: return "square.grid.3x3"
        case .step: return "1.circle"
        case .spotlight: return "flashlight.on.fill"
        case .crop: return "crop"
        }
    }

    var kind: AnnotationKind? {
        AnnotationKind(rawValue: rawValue)
    }
}

/// A single markup item. Coordinates are in source-image pixels, top-left origin.
struct AnnotationItem: Identifiable {
    var id = UUID()
    var kind: AnnotationKind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    /// Stroke width in "units" (multiplied by the scene unit when drawn).
    var lineWidth: CGFloat
    var text: String = ""
    var fontSize: CGFloat = 28
    var number: Int = 0
    var filled: Bool = false

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    mutating func translate(by d: CGSize) {
        start.x += d.width; start.y += d.height
        end.x += d.width; end.y += d.height
        points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
    }
}

enum BackgroundPreset: String, CaseIterable, Identifiable {
    case none, white, black, graphite, ocean, sunset, forest, lavender

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .white: return "White"
        case .black: return "Black"
        case .graphite: return "Graphite"
        case .ocean: return "Ocean"
        case .sunset: return "Sunset"
        case .forest: return "Forest"
        case .lavender: return "Lavender"
        }
    }

    /// One colour = solid, two or more = diagonal gradient.
    var colors: [NSColor] {
        switch self {
        case .none: return []
        case .white: return [.rgb(255, 255, 255)]
        case .black: return [.rgb(18, 18, 20)]
        case .graphite: return [.rgb(72, 76, 86), .rgb(30, 32, 38)]
        case .ocean: return [.rgb(58, 123, 213), .rgb(0, 210, 255)]
        case .sunset: return [.rgb(255, 94, 98), .rgb(255, 195, 113)]
        case .forest: return [.rgb(17, 153, 142), .rgb(56, 239, 125)]
        case .lavender: return [.rgb(142, 45, 226), .rgb(74, 0, 224)]
        }
    }
}

extension NSColor {
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
}

/// macOS-like window chrome placed around the screenshot.
enum WindowFrame: String, CaseIterable, Identifiable {
    case none, macLight, macDark, safari, minimal, glass, terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .macLight: return "Light"
        case .macDark: return "Dark"
        case .safari: return "Browser"
        case .minimal: return "Minimal"
        case .glass: return "Glass"
        case .terminal: return "Terminal"
        }
    }

    var tooltip: String {
        switch self {
        case .none: return "No window: the screenshot on its own backdrop"
        case .macLight: return "macOS light window with traffic lights on a gradient wallpaper"
        case .macDark: return "macOS dark window on a dark gradient"
        case .safari: return "Safari-style browser window with an address bar on a pastel gradient"
        case .minimal: return "Minimal rounded frame with a large soft shadow on a solid color"
        case .glass: return "Frosted glass window on a vibrant mesh gradient"
        case .terminal: return "Terminal-style dark window"
        }
    }

    /// Title bar height in units.
    var titleBarHeight: CGFloat {
        switch self {
        case .none, .minimal: return 0
        case .macLight, .macDark, .glass: return 34
        case .safari: return 52
        case .terminal: return 30
        }
    }

    /// Border between the window edge and the screenshot, in units.
    var inset: CGFloat { self == .glass ? 10 : 0 }

    /// Settings applied when the style is chosen.
    var defaults: BackgroundSettings {
        var s = BackgroundSettings()
        s.frame = self
        switch self {
        case .none:
            s.padding = 0; s.cornerRadius = 0
        case .macLight:
            s.colors = [.rgb(120, 119, 255), .rgb(255, 128, 190)]
            s.padding = 60; s.cornerRadius = 12; s.shadowAmount = 0.6; s.title = "Untitled"
        case .macDark:
            s.colors = [.rgb(52, 52, 96), .rgb(12, 12, 24)]
            s.padding = 60; s.cornerRadius = 12; s.shadowAmount = 0.7; s.title = "Untitled"
        case .safari:
            s.colors = [.rgb(253, 203, 241), .rgb(166, 193, 238)]
            s.padding = 60; s.cornerRadius = 12; s.shadowAmount = 0.5; s.title = "masterfabric.co"
        case .minimal:
            s.colors = [.rgb(232, 236, 244)]
            s.padding = 80; s.cornerRadius = 16; s.shadowAmount = 1.0
        case .glass:
            s.colors = [.rgb(255, 64, 129), .rgb(124, 77, 255), .rgb(0, 200, 255), .rgb(255, 171, 64)]
            s.mesh = true
            s.padding = 70; s.cornerRadius = 18; s.shadowAmount = 0.5; s.title = "Glass"
        case .terminal:
            s.colors = [.rgb(44, 44, 58), .rgb(14, 14, 20)]
            s.padding = 60; s.cornerRadius = 10; s.shadowAmount = 0.7; s.title = "zsh — 80×24"
        }
        return s
    }
}

struct BackgroundSettings {
    var frame: WindowFrame = .none
    /// One colour = solid, two = diagonal gradient, more (with `mesh`) = mesh gradient. Empty = transparent.
    var colors: [NSColor] = []
    var mesh = false
    /// Padding around the window/image, in units.
    var padding: CGFloat = 0
    var cornerRadius: CGFloat = 0
    var shadow: Bool = true
    /// 0...1 strength/size of the shadow.
    var shadowAmount: CGFloat = 0.5
    var title = ""
}

/// Immutable description of what to render.
struct AnnotationScene {
    var base: CGImage
    var annotations: [AnnotationItem]
    var cropRect: CGRect
    var background: BackgroundSettings
    /// Scale factor applied to line widths, fonts and padding so markup looks the same on any resolution.
    var unit: CGFloat

    var padding: CGFloat { background.padding * unit }
    var titleBar: CGFloat { background.frame.titleBarHeight * unit }
    var inset: CGFloat { background.frame.inset * unit }
    /// The window (or bare image) including chrome, excluding padding.
    var windowSize: CGSize {
        CGSize(width: cropRect.width + 2 * inset, height: cropRect.height + titleBar + 2 * inset)
    }
    var windowRect: CGRect { CGRect(origin: CGPoint(x: padding, y: padding), size: windowSize) }
    /// Where the cropped screenshot's top-left lands in the output.
    var contentOrigin: CGPoint { CGPoint(x: padding + inset, y: padding + titleBar + inset) }
    var outputSize: CGSize {
        CGSize(width: windowSize.width + 2 * padding, height: windowSize.height + 2 * padding)
    }
}

/// Observable editing state for one image.
final class AnnotationDocument: ObservableObject {
    let baseImage: CGImage
    let sourceScale: CGFloat

    @Published var annotations: [AnnotationItem] = []
    @Published var cropRect: CGRect
    @Published var background = BackgroundSettings()
    @Published var tool: AnnotationTool = .arrow
    @Published var color: NSColor = .systemRed
    @Published var lineWidth: CGFloat = 4
    @Published var fontSize: CGFloat = 28
    @Published var filledShapes = false
    @Published var selectedID: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private struct State {
        var annotations: [AnnotationItem]
        var cropRect: CGRect
    }
    private var undoStack: [State] = []
    private var redoStack: [State] = []

    init?(image: NSImage) {
        guard let cg = AnnotateImageUtil.cgImage(from: image) else { return nil }
        baseImage = cg
        sourceScale = AnnotateImageUtil.scale(of: image, cg: cg)
        cropRect = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
    }

    var imageBounds: CGRect { CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height) }
    var unit: CGFloat { max(1, CGFloat(baseImage.width) / 1000) }

    var scene: AnnotationScene {
        AnnotationScene(base: baseImage, annotations: annotations, cropRect: cropRect,
                        background: background, unit: unit)
    }

    /// Applies a window frame style together with its default backdrop, padding, radius and shadow.
    func applyFrame(_ frame: WindowFrame) {
        guard frame != background.frame else { return }
        // Replace wholesale so no stale colours, mesh flag or title leak from the previous style.
        background = frame.defaults
    }

    private var thumbnailCache: [String: NSImage] = [:]

    /// Small live preview of the current crop inside `frame` (annotations omitted), cached per crop.
    func frameThumbnail(_ frame: WindowFrame) -> NSImage? {
        let key = "\(frame.rawValue)|\(cropRect)"
        if let hit = thumbnailCache[key] { return hit }
        guard let cropped = baseImage.cropping(to: cropRect) else { return nil }
        let targetW = 320.0
        let k = min(1, targetW / CGFloat(cropped.width))
        let w = max(1, Int(CGFloat(cropped.width) * k)), h = max(1, Int(CGFloat(cropped.height) * k))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let scene = AnnotationScene(base: small, annotations: [],
                                    cropRect: CGRect(x: 0, y: 0, width: w, height: h),
                                    background: frame.defaults, unit: unit * k)
        guard let out = AnnotationRenderer.render(scene: scene) else { return nil }
        let img = NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
        thumbnailCache[key] = img
        return img
    }

    var nextStepNumber: Int {
        (annotations.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1
    }

    var selectedIndex: Int? {
        guard let id = selectedID else { return nil }
        return annotations.firstIndex { $0.id == id }
    }

    // MARK: Undo

    func registerUndo() {
        undoStack.append(State(annotations: annotations, cropRect: cropRect))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateFlags()
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(State(annotations: annotations, cropRect: cropRect))
        annotations = s.annotations
        cropRect = s.cropRect
        selectedID = nil
        updateFlags()
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(State(annotations: annotations, cropRect: cropRect))
        annotations = s.annotations
        cropRect = s.cropRect
        selectedID = nil
        updateFlags()
    }

    private func updateFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Mutations

    func makeItem(_ kind: AnnotationKind, at p: CGPoint) -> AnnotationItem {
        var item = AnnotationItem(kind: kind, start: p, end: p, color: color, lineWidth: lineWidth)
        item.fontSize = fontSize
        item.filled = filledShapes
        if kind == .pencil || kind == .highlighter { item.points = [p] }
        if kind == .step { item.number = nextStepNumber }
        return item
    }

    func add(_ item: AnnotationItem) {
        registerUndo()
        annotations.append(item)
        selectedID = item.id
    }

    func update(_ item: AnnotationItem) {
        guard let i = annotations.firstIndex(where: { $0.id == item.id }) else { return }
        registerUndo()
        annotations[i] = item
    }

    func deleteSelected() {
        guard let i = selectedIndex else { return }
        registerUndo()
        annotations.remove(at: i)
        selectedID = nil
    }

    func moveSelected(by d: CGSize) {
        guard let i = selectedIndex else { return }
        annotations[i].translate(by: d)
    }

    func setCrop(_ rect: CGRect) {
        let r = rect.intersection(imageBounds).integral
        guard r.width >= 8, r.height >= 8, r != cropRect else { return }
        registerUndo()
        cropRect = r
    }

    func resetCrop() {
        guard cropRect != imageBounds else { return }
        registerUndo()
        cropRect = imageBounds
    }

    func setColor(_ c: NSColor) {
        color = c
        if let i = selectedIndex {
            registerUndo()
            annotations[i].color = c
        }
    }

    func setLineWidth(_ w: CGFloat) {
        lineWidth = w
        if let i = selectedIndex { annotations[i].lineWidth = w }
    }

    func setFontSize(_ s: CGFloat) {
        fontSize = s
        if let i = selectedIndex, annotations[i].kind == .text { annotations[i].fontSize = s }
    }

    // MARK: Output

    func renderedCGImage() -> CGImage? {
        AnnotationRenderer.render(scene: scene)
    }

    func renderedImage() -> NSImage? {
        guard let cg = renderedCGImage() else { return nil }
        return AnnotateImageUtil.nsImage(from: cg, scale: sourceScale)
    }
}
