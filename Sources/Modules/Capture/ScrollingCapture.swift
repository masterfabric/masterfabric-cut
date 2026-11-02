// MasterFabric Cut — Capture module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit

/// How fast `ScrollingCapture` moves through the content. Slower speeds scroll in smaller, eased
/// increments and wait longer for the page to settle, which gives smoother, more reliable stitches.
public enum ScrollingCaptureSpeed: String, CaseIterable, Identifiable, Sendable {
    case gentle, normal, fast
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .gentle: return "Gentle (slow & smooth)"
        case .normal: return "Normal"
        case .fast: return "Fast"
        }
    }

    /// Scroll distance per frame as a fraction of the region height (smaller = more overlap between frames).
    var stepFraction: CGFloat { switch self { case .gentle: return 0.35; case .normal: return 0.5; case .fast: return 0.6 } }
    /// Duration of the eased scroll animation for one step.
    var stepDuration: Double { switch self { case .gentle: return 0.55; case .normal: return 0.35; case .fast: return 0.12 } }
    /// Minimum pause after a step before checking that the page has stopped moving.
    var settleDelay: Double { switch self { case .gentle: return 0.35; case .normal: return 0.25; case .fast: return 0.15 } }
}

/// Auto-scrolling capture: repeatedly scrolls the content under `rect`, grabs frames and stitches them
/// by finding the vertical overlap between consecutive frames. Needs Accessibility (to post scroll events).
///
/// Each step is posted as a series of small, continuous (trackpad-like) scroll events following an
/// ease-in-out curve instead of a single jump, then the capture waits until two consecutive frames are
/// identical (render / momentum settled) before grabbing the frame used for stitching.
@MainActor
public final class ScrollingCapture {
    public var speed: ScrollingCaptureSpeed = .gentle
    /// Upper bound on the total scrolled distance, in multiples of the region height.
    public var maxPages: CGFloat = 36
    /// Hard cap on the number of stitched frames.
    public var maxFrames = 150
    /// Longest time to wait for a frame to stop changing after a step.
    public var maxSettleTime: Double = 1.2

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
        let stepPoints = max(20, Int(rect.height * speed.stepFraction))
        let frameLimit = min(maxFrames, Int((maxPages / speed.stepFraction).rounded(.up)) + 1)

        for _ in 1..<frameLimit {
            if cancelled || Task.isCancelled { break }
            await smoothScroll(by: stepPoints, duration: speed.stepDuration)
            if cancelled || Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: UInt64(speed.settleDelay * 1_000_000_000))
            guard let frame = try await settledFrame(rect) else { break }
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

    /// Scrolls `points` downwards as many small continuous wheel events spread over `duration`
    /// with an ease-in-out profile, so the page glides instead of jumping.
    private func smoothScroll(by points: Int, duration: Double) async {
        let tick = 1.0 / 60.0
        let ticks = max(1, Int((duration / tick).rounded()))
        var sent = 0
        for i in 1...ticks {
            if cancelled { return }
            let t = Double(i) / Double(ticks)
            let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2   // easeInOutCubic
            let target = Int((Double(points) * eased).rounded())
            let delta = target - sent
            if delta != 0, let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                            wheel1: Int32(-delta), wheel2: 0, wheel3: 0) {
                ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                ev.post(tap: .cghidEventTap)
                sent = target
            }
            if i < ticks { try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000)) }
        }
    }

    /// Captures until two consecutive frames match (no more scrolling momentum, lazy content or
    /// animations in flight) or `maxSettleTime` passes; returns the last frame.
    private func settledFrame(_ rect: CGRect) async throws -> (image: CGImage, scale: CGFloat)? {
        var last = try await service.captureRect(rect)
        var lastGray = Self.gray(last.image)
        let deadline = Date().addingTimeInterval(maxSettleTime)
        while Date() < deadline, !cancelled {
            try? await Task.sleep(nanoseconds: 90_000_000)
            let next = try await service.captureRect(rect)
            let g = Self.gray(next.image)
            let same = Self.isSame(lastGray, g)
            last = next; lastGray = g
            if same { break }
        }
        return (last.image, last.scale)
    }

    static func isSame(_ a: Gray, _ b: Gray) -> Bool {
        guard a.w == b.w, a.h == b.h else { return false }
        var sum = 0, n = 0
        let step = max(1, a.data.count / 40_000)
        a.data.withUnsafeBufferPointer { pa in b.data.withUnsafeBufferPointer { pb in
            var i = 0
            while i < pa.count { sum += abs(Int(pa[i]) - Int(pb[i])); n += 1; i += step }
        } }
        return n > 0 && Double(sum) / Double(n) < 0.6
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
