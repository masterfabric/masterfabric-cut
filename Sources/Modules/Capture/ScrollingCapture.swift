// MasterFabric Cut — Capture module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit

/// Auto-scrolling capture: repeatedly scrolls the content under `rect`, grabs frames and stitches them
/// by finding the vertical overlap between consecutive frames. Needs Accessibility (to post scroll events).
@MainActor
public final class ScrollingCapture {
    public var maxFrames = 60
    /// Scroll distance per step in points (kept below the region height so frames overlap).
    public var stepFraction: CGFloat = 0.6
    public var settleDelay: UInt64 = 400_000_000

    private let service: ScreenCaptureService
    private var cancelled = false
    private var monitors: [Any] = []

    public init(service: ScreenCaptureService) { self.service = service }

    /// Stop early (e.g. user pressed Esc); frames captured so far are still stitched.
    public func stop() { cancelled = true }

    public func capture(rect: CGRect) async throws -> CaptureResult {
        guard await PermissionManager.shared.ensure(.accessibility) else { throw CaptureError.cancelled }
        cancelled = false
        installEscMonitor()
        defer { monitors.forEach(NSEvent.removeMonitor); monitors.removeAll() }

        let first = try await service.captureRect(rect)
        let scale = first.scale
        var prevGray = Self.gray(first.image)
        var strips: [CGImage] = [first.image]
        let height = first.image.height

        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: primaryH - rect.midY))
        let stepPoints = max(20, Int(rect.height * stepFraction))

        for _ in 1..<maxFrames {
            if cancelled || Task.isCancelled { break }
            if let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-stepPoints), wheel2: 0, wheel3: 0) {
                ev.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: settleDelay)
            let frame = try await service.captureRect(rect)
            guard frame.image.height == height else { break }
            let gray = Self.gray(frame.image)
            guard let shift = Self.findShift(previous: prevGray, current: gray), shift > 0 else { break } // end reached or no match
            let h = frame.image.height, w = frame.image.width
            if let strip = frame.image.cropping(to: CGRect(x: 0, y: h - shift, width: w, height: shift)) { strips.append(strip) }
            prevGray = gray
        }
        guard let stitched = Self.compose(strips) else { throw CaptureError.scrollingFailed }
        return CaptureResult(image: stitched, scale: scale, rect: rect, mode: .scrolling)
    }

    private func installEscMonitor() {
        let handler: (NSEvent) -> Void = { [weak self] e in if e.keyCode == 53 { Task { @MainActor in self?.stop() } } }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { monitors.append(g) }
    }

    // MARK: Stitching

    struct Gray { let data: [UInt8]; let w: Int; let h: Int }

    static func gray(_ image: CGImage) -> Gray {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h)
        buf.withUnsafeMutableBytes { ptr in
            if let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return Gray(data: buf, w: w, h: h)
    }

    /// Number of new pixel rows at the bottom of `current` relative to `previous`; nil when nothing moved
    /// (end of content) or no reliable overlap was found.
    static func findShift(previous p: Gray, current c: Gray) -> Int? {
        guard p.w == c.w, p.h == c.h else { return nil }
        let w = p.w, h = p.h
        let colStep = max(1, w / 200), rowStep = 3
        func score(_ s: Int, limit: Double) -> Double {
            let overlap = h - s
            var sum = 0, n = 0
            p.data.withUnsafeBufferPointer { pp in c.data.withUnsafeBufferPointer { cp in
                var r = 0
                while r < overlap {
                    let po = (r + s) * w, co = r * w
                    var x = 0
                    while x < w { sum += abs(Int(pp[po + x]) - Int(cp[co + x])); n += 1; x += colStep }
                    r += rowStep
                    if Double(sum) / Double(max(n, 1)) > limit * 4 && n > 2000 { return }
                }
            } }
            return n == 0 ? .infinity : Double(sum) / Double(n)
        }
        if score(0, limit: 2) < 0.6 { return nil } // identical frame → reached the end
        var best = Double.infinity, bestShift = 0
        let minOverlap = max(h / 6, 20)
        for s in 1...(h - minOverlap) {
            let sc = score(s, limit: min(best, 40))
            if sc < best { best = sc; bestShift = s }
        }
        return best < 8 ? bestShift : nil
    }

    static func compose(_ strips: [CGImage]) -> CGImage? {
        guard let first = strips.first else { return nil }
        let w = first.width
        let total = strips.reduce(0) { $0 + $1.height }
        guard let ctx = CGContext(data: nil, width: w, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) ?? CGContext(
                                  data: nil, width: w, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = total
        for s in strips {
            y -= s.height
            ctx.draw(s, in: CGRect(x: 0, y: y, width: w, height: s.height))
        }
        return ctx.makeImage()
    }
}
