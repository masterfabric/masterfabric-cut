// MasterFabric Cut — Tools module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import IOKit.pwr_mgt

enum KeepAwakeMode: Equatable {
    case indefinitely, minutes(Int), untilTimerEnds

    var title: String {
        switch self {
        case .indefinitely: return "Indefinitely"
        case .minutes(let m): return m % 60 == 0 ? "\(m / 60) hour\(m == 60 ? "" : "s")" : "\(m) minutes"
        case .untilTimerEnds: return "Until the countdown ends"
        }
    }

    static let menuChoices: [KeepAwakeMode] = [.indefinitely, .minutes(60), .minutes(120), .untilTimerEnds]
}

/// Prevents idle sleep with an IOPMAssertion (display sleep by default, system-only in Settings).
/// The menu bar icon shows a small cup while it is on.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    @Published private(set) var isActive = false
    @Published private(set) var mode: KeepAwakeMode = .indefinitely
    @Published private(set) var endsAt: Date?

    private var assertion: IOPMAssertionID = 0
    private var expiry: Timer?

    var statusText: String {
        guard isActive else { return "Off" }
        switch mode {
        case .indefinitely: return "On until turned off"
        case .untilTimerEnds: return "On until the countdown ends"
        case .minutes:
            guard let e = endsAt else { return "On" }
            return "On until \(e.formatted(date: .omitted, time: .shortened))"
        }
    }

    /// Shortcut / menu toggle: off → on indefinitely, on → off.
    func toggle() { isActive ? stop() : start(.indefinitely) }

    func start(_ mode: KeepAwakeMode) {
        if mode == .untilTimerEnds && !CountdownTimer.shared.isCounting {
            Toast.show("Start a countdown first", symbol: "timer", tint: .orange); return
        }
        release()
        let type = (AppSettings.shared.keepAwakeDisplay ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep") as CFString
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), "MasterFabric Cut — Keep Awake" as CFString, &id)
        guard r == kIOReturnSuccess else {
            Toast.show("Couldn't keep the Mac awake (error \(r))", symbol: "exclamationmark.triangle.fill", tint: .orange); return
        }
        assertion = id
        self.mode = mode
        isActive = true
        endsAt = nil
        if case .minutes(let m) = mode {
            let end = Date().addingTimeInterval(TimeInterval(m * 60))
            endsAt = end
            let t = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
            RunLoop.main.add(t, forMode: .common)
            expiry = t
        }
        Toast.show("Keep Awake on · \(mode.title)", symbol: "cup.and.saucer.fill", tint: .orange)
    }

    func stop() {
        guard isActive else { return }
        release()
        isActive = false
        endsAt = nil
        Toast.show("Keep Awake off", symbol: "moon.zzz.fill", tint: .indigo)
    }

    /// Called by the countdown when it finishes or is reset.
    func countdownEnded() { if isActive && mode == .untilTimerEnds { stop() } }

    /// Settings changed (display vs system): re-create the assertion with the new type.
    func applySettings() { if isActive { let m = mode; let e = endsAt; start(m); if let e { reschedule(e) } } }

    private func reschedule(_ end: Date) {
        expiry?.invalidate()
        endsAt = end
        let t = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
        RunLoop.main.add(t, forMode: .common)
        expiry = t
    }

    private func release() {
        expiry?.invalidate(); expiry = nil
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }
}
