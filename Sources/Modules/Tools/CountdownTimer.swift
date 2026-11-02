// MasterFabric Cut — Tools module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import SwiftUI

/// Always-on-top countdown overlay for talks, demos and focus blocks.
@MainActor
final class CountdownTimer: ObservableObject {
    static let shared = CountdownTimer()
    static let presets = [5, 10, 15, 30]

    enum State { case idle, running, paused, finished }

    @Published private(set) var state: State = .idle
    @Published private(set) var total: TimeInterval = 0
    @Published private(set) var remaining: TimeInterval = 0
    @Published var customMinutes = ""

    private var endDate: Date?
    private var ticker: Timer?
    private var panel: NSPanel?

    var isCounting: Bool { state == .running || state == .paused }
    /// Last minute, or the last 20 % of a short timer.
    var isWarning: Bool { isCounting && remaining <= min(60, total * 0.2) }

    var display: String {
        let s = Int(remaining.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: Window

    func toggleWindow() { panel?.isVisible == true ? close() : show() }

    func show() {
        let p = panel ?? makePanel()
        panel = p
        if !p.isVisible, let vf = Optional(NSScreen.underMouse)?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.midX - p.frame.width / 2, y: vf.maxY - p.frame.height - 24))
        }
        p.orderFrontRegardless()
    }

    func close() {
        reset()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: CountdownView(timer: self, window: { [weak p] in p }))
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        return p
    }

    // MARK: Control

    func start(minutes: Double) {
        guard minutes > 0 else { return }
        total = minutes * 60
        remaining = total
        resume()
        show()
    }

    func startCustom() {
        let v = Double(customMinutes.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
        guard v > 0, v <= 24 * 60 else { Toast.show("Enter minutes between 1 and 1440", symbol: "timer", tint: .orange); return }
        start(minutes: v)
    }

    func pause() {
        guard state == .running else { return }
        remaining = max(0, endDate?.timeIntervalSinceNow ?? remaining)
        ticker?.invalidate(); ticker = nil
        state = .paused
    }

    func resume() {
        guard remaining > 0 else { return }
        endDate = Date().addingTimeInterval(remaining)
        state = .running
        ticker?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func reset() {
        ticker?.invalidate(); ticker = nil
        state = .idle
        remaining = 0
        total = 0
        KeepAwake.shared.countdownEnded()
    }

    private func tick() {
        remaining = max(0, endDate?.timeIntervalSinceNow ?? 0)
        guard remaining <= 0 else { return }
        ticker?.invalidate(); ticker = nil
        state = .finished
        if AppSettings.shared.countdownSound { NSSound(named: "Glass")?.play() }
        KeepAwake.shared.countdownEnded()
        show()
    }
}

/// Borderless panel that can still take keyboard focus (custom minutes field, quick notes).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct CountdownView: View {
    @ObservedObject var timer: CountdownTimer
    let window: () -> NSWindow?
    @State private var blink = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "timer").font(.system(size: 11, weight: .bold))
                Text(timer.state == .finished ? "TIME'S UP" : "COUNTDOWN").font(.system(size: 10, weight: .bold, design: .rounded))
                Spacer()
                Button { timer.close() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).help("Close the countdown")
            }
            .foregroundStyle(.white.opacity(0.7))
            .dragsWindow(window)

            if timer.state == .idle {
                HStack(spacing: 6) {
                    ForEach(CountdownTimer.presets, id: \.self) { m in
                        Button("\(m)m") { timer.start(minutes: Double(m)) }.buttonStyle(TimerPillButton(tint: .orange))
                    }
                }
                HStack(spacing: 6) {
                    TextField("Minutes", text: $timer.customMinutes)
                        .textFieldStyle(.plain).font(.system(size: 13, design: .rounded))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(.white)
                        .onSubmit { timer.startCustom() }
                    Button("Start") { timer.startCustom() }.buttonStyle(TimerPillButton(tint: .green))
                }
            } else {
                Text(timer.display)
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(timer.isWarning || timer.state == .finished ? Color.red : .white)
                    .opacity(timer.state == .finished && blink ? 0.35 : 1)
                    .contentTransition(.numericText())
                    .dragsWindow(window)
                HStack(spacing: 8) {
                    if timer.state == .running {
                        Button { timer.pause() } label: { Label("Pause", systemImage: "pause.fill") }.buttonStyle(TimerPillButton(tint: .orange))
                    } else if timer.state == .paused {
                        Button { timer.resume() } label: { Label("Resume", systemImage: "play.fill") }.buttonStyle(TimerPillButton(tint: .green))
                    }
                    Button { timer.reset() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }.buttonStyle(TimerPillButton(tint: .gray))
                }
            }
            if timer.isCounting {
                ProgressView(value: timer.total > 0 ? 1 - timer.remaining / timer.total : 0)
                    .progressViewStyle(.linear).tint(timer.isWarning ? .red : .orange)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.black.opacity(0.82))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(timer.isWarning || timer.state == .finished ? Color.red.opacity(0.8) : .white.opacity(0.12), lineWidth: 1.5)))
        .onReceive(Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()) { _ in
            if timer.state == .finished { blink.toggle() } else if blink { blink = false }
        }
    }
}

struct TimerPillButton: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(tint.opacity(configuration.isPressed ? 0.55 : 0.8), in: Capsule())
    }
}
