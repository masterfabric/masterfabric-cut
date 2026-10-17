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
        let bg = scene.background
        let unit = scene.unit
        let win = scene.windowRect
        let radius = max(0, min(bg.cornerRadius * unit, min(win.width, win.height) / 2))
        let winPath = CGPath(roundedRect: win, cornerWidth: radius, cornerHeight: radius, transform: nil)

        drawBackground(bg, size: scene.outputSize, in: ctx)

        if bg.shadow && scene.padding > 0 {
            drawShadow(around: win, radius: radius, amount: bg.shadowAmount, unit: unit, in: ctx)
        }

        // Window body + chrome.
        ctx.saveGState()
        ctx.addPath(winPath)
        ctx.clip()
        drawChrome(frame: bg.frame, title: bg.title, window: win, titleBar: scene.titleBar, unit: unit, in: ctx)
        ctx.restoreGState()

        // Screenshot content.
        let origin = scene.contentOrigin
        let content = CGRect(origin: origin, size: scene.cropRect.size)
        ctx.saveGState()
        if bg.frame == .none || bg.frame == .minimal {
            ctx.addPath(winPath)
        } else if bg.frame == .glass {
            let r = max(0, radius - scene.inset)
            ctx.addPath(CGPath(roundedRect: content, cornerWidth: r, cornerHeight: r, transform: nil))
        } else {
            ctx.addRect(content.intersection(win))
        }
        ctx.clip()
        ctx.translateBy(x: content.minX - scene.cropRect.minX, y: content.minY - scene.cropRect.minY)
        drawContent(scene: scene, in: ctx)
        ctx.restoreGState()

        if bg.frame == .glass { drawGlassRim(window: win, radius: radius, unit: unit, in: ctx) }
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
        let colors = bg.colors
        guard !colors.isEmpty, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let full = CGRect(origin: .zero, size: size)
        if colors.count == 1 {
            ctx.setFillColor(colors[0].cgColor)
            ctx.fill(full)
            return
        }
        if let g = CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: nil) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        guard bg.mesh else { return }
        // Mesh: soft radial blobs, one per colour.
        let spots: [CGPoint] = [CGPoint(x: 0.12, y: 0.15), CGPoint(x: 0.88, y: 0.2),
                                CGPoint(x: 0.75, y: 0.92), CGPoint(x: 0.1, y: 0.85), CGPoint(x: 0.5, y: 0.5)]
        let reach = max(size.width, size.height) * 0.75
        ctx.saveGState()
        ctx.clip(to: full)
        for (i, c) in colors.enumerated() {
            let center = CGPoint(x: spots[i % spots.count].x * size.width, y: spots[i % spots.count].y * size.height)
            let clear = c.withAlphaComponent(0).cgColor
            if let g = CGGradient(colorsSpace: space, colors: [c.cgColor, clear] as CFArray, locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: reach, options: [])
            }
        }
        ctx.restoreGState()
    }

    /// Soft shadow built from stacked translucent rounded rects. Unlike `CGContext.setShadow`, the result is
    /// expressed in user space, so the live preview (scaled, flipped) and exported output match exactly.
    private static func drawShadow(around rect: CGRect, radius: CGFloat, amount: CGFloat, unit: CGFloat,
                                   in ctx: CGContext) {
        let amt = min(max(amount, 0), 1)
        guard amt > 0 else { return }
        let blur = (16 + 56 * amt) * unit
        let dy = blur * 0.32
        let peak = 0.16 + 0.38 * amt
        let steps = 28
        let layerAlpha = 1 - pow(1 - peak, 1 / CGFloat(steps))
        ctx.saveGState()
        // Keep the shadow out from under the (possibly translucent) window.
        let clipPath = CGMutablePath()
        clipPath.addRect(rect.insetBy(dx: -blur * 3, dy: -blur * 3).offsetBy(dx: 0, dy: dy))
        clipPath.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.addPath(clipPath)
        ctx.clip(using: .evenOdd)
        ctx.setFillColor(CGColor(gray: 0, alpha: layerAlpha))
        for k in 0..<steps {
            let t = CGFloat(k) / CGFloat(steps)
            let grow = blur * (1 - t) * 0.9 - blur * 0.35
            let r = rect.offsetBy(dx: 0, dy: dy).insetBy(dx: -grow, dy: -grow)
            guard r.width > 0, r.height > 0 else { continue }
            let rad = max(0, min(radius + grow, min(r.width, r.height) / 2))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    // MARK: Window chrome

    private static func drawChrome(frame: WindowFrame, title: String, window w: CGRect, titleBar: CGFloat,
                                   unit u: CGFloat, in ctx: CGContext) {
        let bar = CGRect(x: w.minX, y: w.minY, width: w.width, height: titleBar)
        switch frame {
        case .none:
            return
        case .minimal:
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(w)
        case .macLight:
            ctx.setFillColor(NSColor.rgb(246, 246, 247).cgColor); ctx.fill(w)
            divider(bar, color: CGColor(gray: 0, alpha: 0.12), unit: u, in: ctx)
            trafficLights(in: bar, unit: u, ctx: ctx)
            centeredTitle(title, in: bar, color: NSColor(white: 0.25, alpha: 1), unit: u, mono: false, ctx: ctx)
        case .macDark:
            ctx.setFillColor(NSColor.rgb(30, 30, 33).cgColor); ctx.fill(w)
            ctx.setFillColor(NSColor.rgb(44, 44, 48).cgColor); ctx.fill(bar)
            divider(bar, color: CGColor(gray: 0, alpha: 0.5), unit: u, in: ctx)
            trafficLights(in: bar, unit: u, ctx: ctx)
            centeredTitle(title, in: bar, color: NSColor(white: 0.85, alpha: 1), unit: u, mono: false, ctx: ctx)
        case .terminal:
            ctx.setFillColor(NSColor.rgb(18, 18, 20).cgColor); ctx.fill(w)
            ctx.setFillColor(NSColor.rgb(52, 52, 56).cgColor); ctx.fill(bar)
            divider(bar, color: CGColor(gray: 0, alpha: 0.6), unit: u, in: ctx)
            trafficLights(in: bar, unit: u, ctx: ctx)
            centeredTitle(title, in: bar, color: NSColor(white: 0.72, alpha: 1), unit: u, mono: true, ctx: ctx)
        case .safari:
            ctx.setFillColor(NSColor.rgb(250, 250, 251).cgColor); ctx.fill(w)
            ctx.setFillColor(NSColor.rgb(236, 236, 238).cgColor); ctx.fill(bar)
            divider(bar, color: CGColor(gray: 0, alpha: 0.14), unit: u, in: ctx)
            trafficLights(in: bar, unit: u, ctx: ctx)
            // Back / forward chevrons.
            ctx.saveGState()
            ctx.setStrokeColor(CGColor(gray: 0.45, alpha: 1))
            ctx.setLineWidth(1.8 * u); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            let cy = bar.midY
            for (i, dir) in [CGFloat(-1), 1].enumerated() {
                let x = bar.minX + (96 + CGFloat(i) * 26) * u
                ctx.move(to: CGPoint(x: x - dir * 3.5 * u, y: cy - 6 * u))
                ctx.addLine(to: CGPoint(x: x + dir * 3.5 * u, y: cy))
                ctx.addLine(to: CGPoint(x: x - dir * 3.5 * u, y: cy + 6 * u))
                ctx.strokePath()
            }
            ctx.restoreGState()
            // Address bar.
            let barW = min(w.width * 0.5, 460 * u)
            let field = CGRect(x: bar.midX - barW / 2, y: bar.midY - 14 * u, width: barW, height: 28 * u)
            if field.minX > bar.minX + 150 * u {
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.07))
                ctx.addPath(CGPath(roundedRect: field, cornerWidth: 8 * u, cornerHeight: 8 * u, transform: nil))
                ctx.fillPath()
                centeredTitle(title, in: field, color: NSColor(white: 0.3, alpha: 1), unit: u, mono: false, ctx: ctx)
            }
        case .glass:
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.26)); ctx.fill(w)
            let sheen = [CGColor(gray: 1, alpha: 0.32), CGColor(gray: 1, alpha: 0.04)] as CFArray
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let g = CGGradient(colorsSpace: space, colors: sheen, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: w.minX, y: w.minY),
                                       end: CGPoint(x: w.maxX, y: w.maxY), options: [])
            }
            trafficLights(in: bar, unit: u, ctx: ctx)
            centeredTitle(title, in: bar, color: NSColor(white: 1, alpha: 0.92), unit: u, mono: false, ctx: ctx)
        }
    }

    private static func drawGlassRim(window w: CGRect, radius: CGFloat, unit u: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
        ctx.setLineWidth(1.2 * u)
        let r = w.insetBy(dx: 0.6 * u, dy: 0.6 * u)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: max(0, radius - 0.6 * u),
                           cornerHeight: max(0, radius - 0.6 * u), transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func divider(_ bar: CGRect, color: CGColor, unit u: CGFloat, in ctx: CGContext) {
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: bar.minX, y: bar.maxY - max(1, u), width: bar.width, height: max(1, u)))
    }

    private static func trafficLights(in bar: CGRect, unit u: CGFloat, ctx: CGContext) {
        let colors = [NSColor.rgb(255, 95, 86), .rgb(255, 189, 46), .rgb(39, 201, 63)]
        let d = 12 * u
        for (i, c) in colors.enumerated() {
            let r = CGRect(x: bar.minX + 14 * u + CGFloat(i) * 20 * u, y: bar.midY - d / 2, width: d, height: d)
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.14))
            ctx.setLineWidth(max(0.5, 0.75 * u))
            ctx.strokeEllipse(in: r.insetBy(dx: 0.4 * u, dy: 0.4 * u))
        }
    }

    private static func centeredTitle(_ text: String, in rect: CGRect, color: NSColor, unit u: CGFloat,
                                      mono: Bool, ctx: CGContext) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let size = 13 * u
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                        : NSFont.systemFont(ofSize: size, weight: .medium)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let str = NSAttributedString(string: t, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: para
        ])
        let h = str.size().height
        let inset = 110 * u
        let box = CGRect(x: rect.minX + inset, y: rect.midY - h / 2, width: max(0, rect.width - 2 * inset), height: h)
        guard box.width > 10 * u else { return }
        withFlippedGraphics(ctx) { str.draw(in: box) }
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
