import AppKit
import CoreImage

/// Draws an `AnnotationScene` into a CGContext using a top-left origin (flipped) coordinate space.
enum AnnotationRenderer {
    static let ciContext = CIContext(options: nil)

    static func render(scene: AnnotationScene) -> CGImage? {
        let size = scene.outputSize
        let w = max(1, Int(ceil(size.width)))
        let h = max(1, Int(ceil(size.height)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(scene: scene, in: ctx)
        return ctx.makeImage()
    }

    /// `ctx` must already be flipped so that (0,0) is the top-left of the output.
    static func draw(scene: AnnotationScene, in ctx: CGContext) {
        let size = scene.outputSize
        let pad = scene.padding
        let crop = scene.cropRect

        drawBackground(scene.background, size: size, in: ctx)

        let content = CGRect(x: pad, y: pad, width: crop.width, height: crop.height)
        let radius = min(scene.background.cornerRadius * scene.unit, min(content.width, content.height) / 2)
        let path = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if scene.background.shadow && pad > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -pad * 0.18), blur: pad * 0.4,
                          color: CGColor(gray: 0, alpha: 0.45))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.translateBy(x: content.minX - crop.minX, y: content.minY - crop.minY)
        drawContent(scene: scene, in: ctx)
        ctx.restoreGState()
    }

    /// Draws base image + annotations in image-pixel space.
    static func drawContent(scene: AnnotationScene, in ctx: CGContext) {
        let base = scene.base
        let imgRect = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        ctx.interpolationQuality = .high
        drawFlipped(base, in: imgRect, ctx: ctx)

        for a in scene.annotations where a.kind == .blur || a.kind == .pixelate {
            if let region = filteredRegion(base: base, rect: a.rect, kind: a.kind, unit: scene.unit) {
                drawFlipped(region.image, in: region.rect, ctx: ctx)
            }
        }

        let spots = scene.annotations.filter { $0.kind == .spotlight }
        if !spots.isEmpty {
            ctx.saveGState()
            let p = CGMutablePath()
            p.addRect(imgRect.insetBy(dx: -4, dy: -4))
            for s in spots {
                let r = s.rect
                let rad = min(12 * scene.unit, min(r.width, r.height) / 2)
                p.addRoundedRect(in: r, cornerWidth: rad, cornerHeight: rad)
            }
            ctx.addPath(p)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }

        for a in scene.annotations {
            switch a.kind {
            case .blur, .pixelate, .spotlight: continue
            default: drawAnnotation(a, unit: scene.unit, in: ctx)
            }
        }
    }

    // MARK: Background

    private static func drawBackground(_ bg: BackgroundSettings, size: CGSize, in ctx: CGContext) {
        let colors = bg.preset.colors
        guard !colors.isEmpty else { return }
        let full = CGRect(origin: .zero, size: size)
        if colors.count == 1 {
            ctx.setFillColor(colors[0].cgColor)
            ctx.fill(full)
        } else if let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let g = CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: nil) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
    }

    // MARK: Annotations

    static func drawAnnotation(_ a: AnnotationItem, unit: CGFloat, in ctx: CGContext) {
        let lw = a.lineWidth * unit
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.kind {
        case .arrow:
            let dx = a.end.x - a.start.x, dy = a.end.y - a.start.y
            let len = hypot(dx, dy)
            guard len > 1 else { return }
            let ux = dx / len, uy = dy / len
            let head = min(lw * 4.5 + 6 * unit, len)
            let baseX = a.end.x - ux * head * 0.8
            let baseY = a.end.y - uy * head * 0.8
            ctx.move(to: a.start)
            ctx.addLine(to: CGPoint(x: baseX, y: baseY))
            ctx.strokePath()
            let hw = head * 0.42
            ctx.move(to: a.end)
            ctx.addLine(to: CGPoint(x: a.end.x - ux * head - uy * hw, y: a.end.y - uy * head + ux * hw))
            ctx.addLine(to: CGPoint(x: a.end.x - ux * head + uy * hw, y: a.end.y - uy * head - ux * hw))
            ctx.closePath()
            ctx.fillPath()
        case .line:
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()
        case .rectangle:
            let r = a.rect
            if a.filled { ctx.fill(r) } else { ctx.stroke(r) }
        case .ellipse:
            let r = a.rect
            if a.filled { ctx.fillEllipse(in: r) } else { ctx.strokeEllipse(in: r) }
        case .pencil:
            strokePoints(a.points, in: ctx)
        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setAlpha(0.45)
            ctx.setLineWidth(lw * 4)
            ctx.setLineCap(.butt)
            strokePoints(a.points, in: ctx)
        case .text:
            let str = attributedText(a, unit: unit)
            let size = str.boundingRect(with: CGSize(width: 10_000, height: 10_000),
                                        options: [.usesLineFragmentOrigin]).size
            withFlippedGraphics(ctx) {
                str.draw(with: CGRect(origin: a.start, size: CGSize(width: size.width + 2, height: size.height + 2)),
                         options: [.usesLineFragmentOrigin])
            }
        case .step:
            let r = stepRadius(a, unit: unit)
            ctx.fillEllipse(in: CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2))
            let str = NSAttributedString(string: "\(a.number)", attributes: [
                .font: NSFont.systemFont(ofSize: r * 1.15, weight: .bold),
                .foregroundColor: contrastColor(for: a.color)
            ])
            let s = str.size()
            withFlippedGraphics(ctx) {
                str.draw(at: CGPoint(x: a.start.x - s.width / 2, y: a.start.y - s.height / 2))
            }
        case .blur, .pixelate, .spotlight:
            break
        }
    }

    private static func strokePoints(_ pts: [CGPoint], in ctx: CGContext) {
        guard let first = pts.first else { return }
        if pts.count == 1 {
            ctx.move(to: first)
            ctx.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
        } else {
            ctx.move(to: first)
            for p in pts.dropFirst() { ctx.addLine(to: p) }
        }
        ctx.strokePath()
    }

    private static func withFlippedGraphics(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func attributedText(_ a: AnnotationItem, unit: CGFloat) -> NSAttributedString {
        NSAttributedString(string: a.text, attributes: [
            .font: NSFont.systemFont(ofSize: a.fontSize * unit, weight: .semibold),
            .foregroundColor: a.color
        ])
    }

    private static func stepRadius(_ a: AnnotationItem, unit: CGFloat) -> CGFloat {
        (10 + a.lineWidth * 2) * unit
    }

    private static func contrastColor(for color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return .white }
        let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return lum > 0.7 ? .black : .white
    }

    // MARK: Geometry

    /// Bounding box in image space, used for hit testing and selection UI.
    static func bounds(of a: AnnotationItem, unit: CGFloat) -> CGRect {
        let lw = a.lineWidth * unit
        switch a.kind {
        case .arrow, .line:
            return a.rect.insetBy(dx: -(lw + 6 * unit), dy: -(lw + 6 * unit))
        case .rectangle, .ellipse:
            return a.rect.insetBy(dx: -lw / 2, dy: -lw / 2)
        case .blur, .pixelate, .spotlight:
            return a.rect
        case .pencil, .highlighter:
            let xs = a.points.map(\.x), ys = a.points.map(\.y)
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
            let pad = a.kind == .highlighter ? lw * 2 : lw / 2
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).insetBy(dx: -pad, dy: -pad)
        case .text:
            let s = attributedText(a, unit: unit).boundingRect(
                with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin]).size
            return CGRect(origin: a.start, size: s)
        case .step:
            let r = stepRadius(a, unit: unit)
            return CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
        }
    }

    // MARK: Blur / pixelate

    private static func filteredRegion(base: CGImage, rect: CGRect, kind: AnnotationKind,
                                       unit: CGFloat) -> (image: CGImage, rect: CGRect)? {
        let imgRect = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let r = rect.intersection(imgRect).integral
        guard r.width >= 2, r.height >= 2 else { return nil }
        let ciRect = CGRect(x: r.minX, y: CGFloat(base.height) - r.maxY, width: r.width, height: r.height)
        let source = CIImage(cgImage: base)
        let out: CIImage?
        if kind == .pixelate {
            let f = CIFilter(name: "CIPixellate")
            f?.setValue(source.cropped(to: ciRect), forKey: kCIInputImageKey)
            f?.setValue(max(6, 10 * unit), forKey: kCIInputScaleKey)
            f?.setValue(CIVector(x: ciRect.minX, y: ciRect.minY), forKey: kCIInputCenterKey)
            out = f?.outputImage
        } else {
            let f = CIFilter(name: "CIGaussianBlur")
            f?.setValue(source.cropped(to: ciRect).clampedToExtent(), forKey: kCIInputImageKey)
            f?.setValue(14 * unit, forKey: kCIInputRadiusKey)
            out = f?.outputImage
        }
        guard let result = out,
              let cg = ciContext.createCGImage(result.cropped(to: ciRect), from: ciRect) else { return nil }
        return (cg, r)
    }

    private static func drawFlipped(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }
}
