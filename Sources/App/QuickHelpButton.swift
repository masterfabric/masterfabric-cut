// MasterFabric Cut — App shell
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import SwiftUI

/// Floating squircle "Quick Help" button. Hover for 2 s (a ring fills while you wait) or click to open a
/// semicircular radial menu whose arc points away from the nearest screen edge. Drag to move; it snaps to the
/// nearest screen edge and remembers its position. Drop an image or PDF on it to pin the file.
@MainActor
final class QuickHelpButton {
    static let shared = QuickHelpButton()

    static let size: CGFloat = 52
    static let inset: CGFloat = 10          // room around the squircle for the ring and shadow
    static let edgeMargin: CGFloat = 10
    static let dwell: TimeInterval = 2

    let model = QuickHelpModel()
    private var panel: QuickHelpPanel?
    private var menuPanel: QuickHelpPanel?
    private var dwellWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?

    var isMenuOpen: Bool { menuPanel != nil }

    func refresh() {
        if AppSettings.shared.showQuickHelp { show() } else { hide() }
    }

    // MARK: Button panel

    private func show() {
        if panel == nil {
            let side = Self.size + Self.inset * 2
            let p = QuickHelpPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isReleasedWhenClosed = false
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView: QuickHelpButtonView(model: model, controller: self))
            p.setFrameOrigin(initialOrigin(for: p.frame.size))
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    private func hide() {
        closeMenu(animated: false)
        cancelDwell()
        panel?.orderOut(nil)
        panel = nil
    }

    private func initialOrigin(for size: NSSize) -> NSPoint {
        if let saved = AppSettings.shared.quickHelpOrigin,
           NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -4, dy: -4).contains(NSPoint(x: saved.x + size.width / 2, y: saved.y + size.height / 2)) }) {
            return saved
        }
        // Default: middle of the right edge of the main screen (the launcher lives bottom-right).
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vf.maxX - size.width - Self.edgeMargin + Self.inset, y: vf.midY - size.height / 2)
    }

    // MARK: Hover dwell

    func hoverChanged(_ inside: Bool) {
        if inside {
            guard !isMenuOpen, dragStartMouse == nil, dwellWork == nil else { return }
            model.dwellProgress = 0
            withAnimation(.linear(duration: Self.dwell)) { model.dwellProgress = 1 }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.dwellWork = nil
                self.openMenu()
            }
            dwellWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell, execute: work)
        } else {
            cancelDwell()
        }
    }

    private func cancelDwell() {
        dwellWork?.cancel(); dwellWork = nil
        withAnimation(.easeOut(duration: 0.2)) { model.dwellProgress = 0 }
    }

    func clicked() {
        cancelDwell()
        isMenuOpen ? closeMenu() : openMenu()
    }

    // MARK: Drag & edge snapping

    func dragChanged() {
        guard let p = panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStartMouse == nil {
            dragStartMouse = mouse; dragStartOrigin = p.frame.origin
            cancelDwell(); closeMenu()
        }
        guard let sm = dragStartMouse, let so = dragStartOrigin else { return }
        p.setFrameOrigin(NSPoint(x: so.x + mouse.x - sm.x, y: so.y + mouse.y - sm.y))
    }

    /// Returns true if the gesture was a drag (moved more than a few points) rather than a click.
    @discardableResult
    func dragEnded() -> Bool {
        defer { dragStartMouse = nil; dragStartOrigin = nil }
        guard let p = panel, let sm = dragStartMouse else { return false }
        let mouse = NSEvent.mouseLocation
        guard hypot(mouse.x - sm.x, mouse.y - sm.y) > 3 else { return false }
        let target = snappedOrigin(for: p.frame)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.25, 0.4, 1)   // slight overshoot, springy
            p.animator().setFrame(NSRect(origin: target, size: p.frame.size), display: true)
        }
        AppSettings.shared.quickHelpOrigin = target
        return true
    }

    private func snappedOrigin(for frame: NSRect) -> NSPoint {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let m = Self.edgeMargin - Self.inset    // the squircle sits edgeMargin from the edge
        var o = frame.origin
        o.x = min(max(o.x, vf.minX + m), vf.maxX - frame.width - m)
        o.y = min(max(o.y, vf.minY + m), vf.maxY - frame.height - m)
        let d = [center.x - vf.minX, vf.maxX - center.x, center.y - vf.minY, vf.maxY - center.y]
        switch d.firstIndex(of: d.min()!)! {
        case 0: o.x = vf.minX + m
        case 1: o.x = vf.maxX - frame.width - m
        case 2: o.y = vf.minY + m
        default: o.y = vf.maxY - frame.height - m
        }
        return o
    }

    // MARK: Radial menu

    static let items: [QuickHelpItem] = [
        .init(id: "area", title: "Screenshot Area", symbol: "rectangle.dashed", tint: .blue) { AppCoordinator.shared.perform(.captureArea) },
        .init(id: "scroll", title: "Scrolling Capture", symbol: "arrow.up.and.down.text.horizontal", tint: .purple) { AppCoordinator.shared.perform(.captureScrolling) },
        .init(id: "record", title: "Record", symbol: "record.circle", tint: .red) { AppCoordinator.shared.perform(.recordScreen) },
        .init(id: "qr", title: "Link to QR", symbol: "qrcode", tint: .teal) { AppCoordinator.shared.perform(.linkToQR) },
        .init(id: "pin", title: "Pin Image / PDF", symbol: "pin.square.fill", tint: .mint) { AppCoordinator.shared.perform(.pinFile) },
        .init(id: "settings", title: "Settings", symbol: "gearshape.fill", tint: .gray) { (NSApp.delegate as? AppDelegate)?.showPreferences() },
    ]

    /// `autoClose: false` is only for the debug snapshot hook (the real cursor is elsewhere).
    func openMenu(autoClose: Bool = true) {
        guard menuPanel == nil, let bp = panel else { return }
        cancelDwell()
        let center = NSPoint(x: bp.frame.midX, y: bp.frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
        let layout = QuickHelpLayout.make(center: center, visibleFrame: screen.visibleFrame, count: Self.items.count)
        model.layout = layout
        model.hovered = nil
        model.menuOpen = false

        let side = layout.panelSide
        let p = QuickHelpPanel(contentRect: NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.contentView = NSHostingView(rootView: QuickHelpMenuView(model: model, controller: self))
        p.orderFrontRegardless()
        p.makeKey()
        menuPanel = p
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { model.menuOpen = true }
        if autoClose { installMonitors(center: center, reach: layout.radius + layout.bubble + 30) }
    }

    func closeMenu(animated: Bool = true) {
        guard let p = menuPanel else { return }
        removeMonitors()
        menuPanel = nil
        model.hovered = nil
        if animated {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { model.menuOpen = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { p.orderOut(nil) }
        } else {
            model.menuOpen = false
            p.orderOut(nil)
        }
    }

    func select(_ item: QuickHelpItem) {
        closeMenu()
        // Let the menu fade out first so it never ends up in a capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { item.perform() }
    }

    private func installMonitors(center: NSPoint, reach: CGFloat) {
        removeMonitors()
        let checkDistance: () -> Void = { [weak self] in
            let m = NSEvent.mouseLocation
            if hypot(m.x - center.x, m.y - center.y) > reach { self?.closeMenu() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { _ in checkDistance() }) { monitors.append(g) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.closeMenu() }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { e in checkDistance(); return e }) { monitors.append(l) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53 { self?.closeMenu(); return nil }   // Esc
            return e
        }) { monitors.append(l) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    #if DEBUG
    var debugMenuView: NSView? { menuPanel?.contentView }
    #endif
}

final class QuickHelpPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { QuickHelpButton.shared.closeMenu() }
}

struct QuickHelpItem: Identifiable {
    let id: String
    let title: String, symbol: String
    let tint: Color
    let perform: () -> Void
}

/// Geometry of the semicircle: bubbles spread over an arc centred on `direction` (pointing away from the nearest edge).
struct QuickHelpLayout {
    var direction: CGFloat = .pi / 2      // radians, math orientation (y up)
    var span: CGFloat = .pi
    var radius: CGFloat = 96
    var bubble: CGFloat = 44
    var count = 6

    var panelSide: CGFloat { (radius + bubble + 60) * 2 }

    func angle(_ i: Int) -> CGFloat {
        guard count > 1 else { return direction }
        return direction + span / 2 - span * CGFloat(i) / CGFloat(count - 1)   // counter-clockwise → clockwise
    }

    /// Offset from the centre in SwiftUI coordinates (y down).
    func offset(_ i: Int, extra: CGFloat = 0) -> CGSize {
        let a = angle(i), r = radius + extra
        return CGSize(width: cos(a) * r, height: -sin(a) * r)
    }

    static func make(center: NSPoint, visibleFrame vf: NSRect, count: Int) -> QuickHelpLayout {
        var l = QuickHelpLayout(); l.count = count
        // Point from the nearest edge(s) towards the screen: quantize the vector to the visible-frame centre to 45°.
        let raw = atan2(vf.midY - center.y, vf.midX - center.x)
        // Prefer straight away from a single nearby edge when the button hugs only one edge.
        let near: CGFloat = 140
        let dl = center.x - vf.minX, dr = vf.maxX - center.x, db = center.y - vf.minY, dt = vf.maxY - center.y
        let hx: CGFloat = dl < near ? 1 : (dr < near ? -1 : 0)
        let hy: CGFloat = db < near ? 1 : (dt < near ? -1 : 0)
        if hx != 0 || hy != 0 {
            l.direction = atan2(hy, hx)
        } else {
            l.direction = (raw / (.pi / 4)).rounded() * (.pi / 4)
        }
        if hx != 0 && hy != 0 {
            // Corner: a tighter arc on a larger radius keeps every bubble on screen.
            l.span = .pi * 0.6; l.radius = 140
        }
        return l
    }
}

final class QuickHelpModel: ObservableObject {
    @Published var dwellProgress: CGFloat = 0
    @Published var menuOpen = false
    @Published var hovered: String?
    @Published var dropTarget = false
    @Published var hovering = false
    var layout = QuickHelpLayout()
}

// MARK: - Views

private struct Squircle: InsettableShape {
    var insetAmount: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        return RoundedRectangle(cornerRadius: min(r.width, r.height) * 0.225, style: .continuous).path(in: r)
    }
    func inset(by amount: CGFloat) -> Squircle { var s = self; s.insetAmount += amount; return s }
}

/// The brand squircle itself (shared by the button panel and the centre of the radial menu).
struct QuickHelpFace: View {
    var size: CGFloat
    var lifted: Bool
    var body: some View {
        ZStack {
            Squircle().fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
            BrandIcon(size: size * 0.78)
            Squircle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(lifted ? 0.38 : 0.25), radius: lifted ? 9 : 5, y: lifted ? 4 : 2)
        .scaleEffect(lifted ? 1.06 : 1)
    }
}

private struct QuickHelpButtonView: View {
    @ObservedObject var model: QuickHelpModel
    let controller: QuickHelpButton
    private let size = QuickHelpButton.size

    var body: some View {
        ZStack {
            QuickHelpFace(size: size, lifted: model.hovering || model.dropTarget)
            // Dwell ring: a squircle stroke that fills over 2 s while hovering.
            Squircle()
                .trim(from: 0, to: model.dwellProgress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: size + 7, height: size + 7)
                .rotationEffect(.degrees(-90))
                .opacity(model.dwellProgress > 0.001 ? 1 : 0)
            if model.dropTarget {
                Squircle().strokeBorder(Color.accentColor, lineWidth: 3).frame(width: size + 7, height: size + 7)
            }
        }
        .frame(width: size + QuickHelpButton.inset * 2, height: size + QuickHelpButton.inset * 2)
        .contentShape(Squircle().size(width: size, height: size).offset(x: QuickHelpButton.inset, y: QuickHelpButton.inset))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.hovering)
        .onHover { inside in
            model.hovering = inside
            controller.hoverChanged(inside)
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in controller.dragChanged() }
                .onEnded { _ in if !controller.dragEnded() { controller.clicked() } }
        )
        .onDrop(of: PinnedScreenshotController.dropTypes, isTargeted: $model.dropTarget) { PinnedScreenshotController.shared.handleDrop($0) }
        .help("Quick Help — hover or click for actions, drag to move, drop an image or PDF to pin it")
    }
}

private struct QuickHelpMenuView: View {
    @ObservedObject var model: QuickHelpModel
    let controller: QuickHelpButton

    var body: some View {
        let l = model.layout
        ZStack {
            // Soft halo behind the arc.
            Circle()
                .fill(RadialGradient(colors: [Color.black.opacity(0.22), .clear], center: .center, startRadius: 10, endRadius: l.radius + l.bubble))
                .frame(width: (l.radius + l.bubble) * 2, height: (l.radius + l.bubble) * 2)
                .opacity(model.menuOpen ? 1 : 0)
                .allowsHitTesting(false)

            ForEach(Array(QuickHelpButton.items.enumerated()), id: \.element.id) { i, item in
                let hovered = model.hovered == item.id
                Bubble(item: item, size: l.bubble, hovered: hovered)
                    .offset(model.menuOpen ? l.offset(i) : .zero)
                    .scaleEffect(model.menuOpen ? 1 : 0.2)
                    .opacity(model.menuOpen ? 1 : 0)
                    .animation(.spring(response: 0.38, dampingFraction: 0.72).delay(model.menuOpen ? Double(i) * 0.025 : 0), value: model.menuOpen)
                    .onHover { inside in
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            if inside { model.hovered = item.id } else if model.hovered == item.id { model.hovered = nil }
                        }
                    }
                    .onTapGesture { controller.select(item) }
                if hovered && model.menuOpen {
                    Label(text: item.title)
                        .offset(l.offset(i, extra: l.bubble / 2 + 30))
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        .allowsHitTesting(false)
                }
            }

            QuickHelpFace(size: QuickHelpButton.size, lifted: true)
                .onTapGesture { controller.closeMenu() }
                .help("Close")
        }
        .frame(width: l.panelSide, height: l.panelSide)
    }

    private struct Bubble: View {
        let item: QuickHelpItem
        let size: CGFloat
        let hovered: Bool
        var body: some View {
            Image(systemName: item.symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(item.tint.gradient))
                .overlay(Circle().strokeBorder(Color.white.opacity(hovered ? 0.9 : 0.25), lineWidth: hovered ? 2 : 0.75))
                .shadow(color: .black.opacity(0.3), radius: hovered ? 8 : 4, y: 2)
                .scaleEffect(hovered ? 1.18 : 1)
                .contentShape(Circle())
                .help(item.title)
        }
    }

    private struct Label: View {
        let text: String
        var body: some View {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
                .fixedSize()
        }
    }
}
