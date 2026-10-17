import AppKit
import SwiftUI
import Combine

/// Interactive canvas that renders the scene and handles drawing, selection and crop gestures.
final class AnnotationCanvasNSView: NSView {
    private(set) var document: AnnotationDocument
    private var cancellable: AnyCancellable?
    private var draft: AnnotationItem?
    private var cropDraft: CGRect?
    private var dragStart: CGPoint = .zero
    private var dragLast: CGPoint?
    private let margin: CGFloat = 24

    init(document: AnnotationDocument) {
        self.document = document
        super.init(frame: .zero)
        cancellable = document.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
            }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: document.tool == .select ? .arrow : .crosshair)
    }

    // MARK: Layout

    private func layoutInfo() -> (scale: CGFloat, offset: CGPoint) {
        let size = document.scene.outputSize
        guard size.width > 0, size.height > 0 else { return (1, .zero) }
        let avail = bounds.insetBy(dx: margin, dy: margin)
        let scale = max(0.01, min(avail.width / size.width, avail.height / size.height, 2))
        let offset = CGPoint(x: (bounds.width - size.width * scale) / 2,
                             y: (bounds.height - size.height * scale) / 2)
        return (scale, offset)
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let v = convert(event.locationInWindow, from: nil)
        let (scale, offset) = layoutInfo()
        let scene = document.scene
        let cx = (v.x - offset.x) / scale, cy = (v.y - offset.y) / scale
        return CGPoint(x: cx - scene.contentOrigin.x + scene.cropRect.minX,
                       y: cy - scene.contentOrigin.y + scene.cropRect.minY)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(white: 0.14, alpha: 1).setFill()
        bounds.fill()

        let (scale, offset) = layoutInfo()
        var scene = document.scene
        if let d = draft { scene.annotations.append(d) }

        ctx.saveGState()
        ctx.translateBy(x: offset.x, y: offset.y)
        ctx.scaleBy(x: scale, y: scale)
        AnnotationRenderer.draw(scene: scene, in: ctx)

        // Editing overlays live in image space.
        ctx.translateBy(x: scene.contentOrigin.x - scene.cropRect.minX, y: scene.contentOrigin.y - scene.cropRect.minY)
        let hairline = 1 / scale

        if let id = document.selectedID, let a = scene.annotations.first(where: { $0.id == id }) {
            let r = AnnotationRenderer.bounds(of: a, unit: scene.unit).insetBy(dx: -3 / scale, dy: -3 / scale)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5 * hairline)
            ctx.setLineDash(phase: 0, lengths: [5 * hairline, 3 * hairline])
            ctx.stroke(r)
        }

        if let c = cropDraft {
            let p = CGMutablePath()
            p.addRect(document.imageBounds)
            p.addRect(c)
            ctx.addPath(p)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(1.5 * hairline)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.stroke(c)
            drawBadge("\(Int(c.width)) × \(Int(c.height))", near: c, scale: scale)
        }
        ctx.restoreGState()
    }

    private func drawBadge(_ text: String, near rect: CGRect, scale: CGFloat) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12 / scale, weight: .medium)
        let str = NSAttributedString(string: " \(text) ", attributes: [
            .font: font, .foregroundColor: NSColor.white, .backgroundColor: NSColor(white: 0, alpha: 0.7)
        ])
        str.draw(at: CGPoint(x: rect.minX, y: rect.maxY + 4 / scale))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = imagePoint(event)
        dragStart = p
        dragLast = nil
        switch document.tool {
        case .select:
            if let hit = annotationAt(p) {
                if event.clickCount == 2, hit.kind == .text {
                    editText(hit)
                    return
                }
                document.selectedID = hit.id
                document.registerUndo()
                dragLast = p
            } else {
                document.selectedID = nil
            }
        case .text:
            promptText(initial: "") { [weak self] text in
                guard let self else { return }
                var item = self.document.makeItem(.text, at: p)
                item.text = text
                self.document.add(item)
            }
        case .step:
            document.add(document.makeItem(.step, at: p))
        case .crop:
            cropDraft = CGRect(origin: p, size: .zero)
        default:
            if let kind = document.tool.kind {
                document.selectedID = nil
                draft = document.makeItem(kind, at: p)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = imagePoint(event)
        let shift = event.modifierFlags.contains(.shift)
        if document.tool == .select {
            if let last = dragLast {
                document.moveSelected(by: CGSize(width: raw.x - last.x, height: raw.y - last.y))
                dragLast = raw
            }
            return
        }
        if document.tool == .crop {
            let p = clamp(shift ? constrain(raw, from: dragStart, square: true) : raw)
            cropDraft = rectFrom(dragStart, p)
            needsDisplay = true
            return
        }
        guard var d = draft else { return }
        switch d.kind {
        case .pencil, .highlighter:
            d.points.append(raw)
            d.end = raw
        default:
            d.end = shift ? constrain(raw, from: d.start, square: d.kind != .arrow && d.kind != .line) : raw
        }
        draft = d
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { draft = nil; dragLast = nil; needsDisplay = true }
        if document.tool == .crop {
            if let c = cropDraft { document.setCrop(c) }
            cropDraft = nil
            return
        }
        guard let d = draft else { return }
        let dist = hypot(d.end.x - d.start.x, d.end.y - d.start.y)
        switch d.kind {
        case .pencil, .highlighter:
            if d.points.count > 1 { document.add(d) }
        case .arrow, .line:
            if dist > 4 { document.add(d) }
        default:
            if d.rect.width > 4 && d.rect.height > 4 { document.add(d) }
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        if cmd, event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) { document.redo() } else { document.undo() }
            return
        }
        switch event.keyCode {
        case 51, 117: document.deleteSelected()
        case 53:
            document.selectedID = nil
            draft = nil
            cropDraft = nil
            needsDisplay = true
        default: super.keyDown(with: event)
        }
    }

    // MARK: Helpers

    private func annotationAt(_ p: CGPoint) -> AnnotationItem? {
        let unit = document.unit
        let slop = 4 * unit
        return document.annotations.last {
            AnnotationRenderer.bounds(of: $0, unit: unit).insetBy(dx: -slop, dy: -slop).contains(p)
        }
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        let b = document.imageBounds
        return CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }

    private func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func constrain(_ p: CGPoint, from s: CGPoint, square: Bool) -> CGPoint {
        let dx = p.x - s.x, dy = p.y - s.y
        if square {
            let m = max(abs(dx), abs(dy))
            return CGPoint(x: s.x + (dx < 0 ? -m : m), y: s.y + (dy < 0 ? -m : m))
        }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        let len = hypot(dx, dy)
        return CGPoint(x: s.x + cos(angle) * len, y: s.y + sin(angle) * len)
    }

    private func editText(_ item: AnnotationItem) {
        promptText(initial: item.text) { [weak self] text in
            var updated = item
            updated.text = text
            self?.document.update(updated)
        }
    }

    private func promptText(initial: String, completion: (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Text"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { completion(text) }
    }
}

struct AnnotationCanvasView: NSViewRepresentable {
    @ObservedObject var document: AnnotationDocument

    func makeNSView(context: Context) -> AnnotationCanvasNSView {
        AnnotationCanvasNSView(document: document)
    }

    func updateNSView(_ nsView: AnnotationCanvasNSView, context: Context) {
        nsView.needsDisplay = true
    }
}
