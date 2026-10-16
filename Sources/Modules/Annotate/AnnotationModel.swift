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
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
        }
        switch self {
        case .none: return []
        case .white: return [c(255, 255, 255)]
        case .black: return [c(18, 18, 20)]
        case .graphite: return [c(72, 76, 86), c(30, 32, 38)]
        case .ocean: return [c(58, 123, 213), c(0, 210, 255)]
        case .sunset: return [c(255, 94, 98), c(255, 195, 113)]
        case .forest: return [c(17, 153, 142), c(56, 239, 125)]
        case .lavender: return [c(142, 45, 226), c(74, 0, 224)]
        }
    }
}

struct BackgroundSettings {
    var preset: BackgroundPreset = .none
    /// Padding around the image, in units.
    var padding: CGFloat = 0
    var cornerRadius: CGFloat = 0
    var shadow: Bool = true
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
    var outputSize: CGSize {
        CGSize(width: cropRect.width + 2 * padding, height: cropRect.height + 2 * padding)
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
