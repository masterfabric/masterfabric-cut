import Foundation
import AppKit
import Carbon.HIToolbox

/// Every user-triggerable action that can have a global hotkey.
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case captureArea, captureWindow, captureFullscreen, capturePreviousArea
    case scrollingCapture, captureText, selfTimer
    case recordScreen, recordGIF, recordingStudio
    case toggleDesktopIcons, openHistory
    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .captureWindow: return "Capture Window"
        case .captureFullscreen: return "Capture Fullscreen"
        case .capturePreviousArea: return "Capture Previous Area"
        case .scrollingCapture: return "Scrolling Capture"
        case .captureText: return "Capture Text (OCR)"
        case .selfTimer: return "Self-Timer"
        case .recordScreen: return "Record Screen"
        case .recordGIF: return "Record GIF"
        case .recordingStudio: return "Recording Studio"
        case .toggleDesktopIcons: return "Hide/Show Desktop Icons"
        case .openHistory: return "Capture History"
        }
    }

    var defaultCombo: KeyCombo? {
        let cs = UInt32(cmdKey | shiftKey)
        switch self {
        case .captureArea: return KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: cs)
        case .captureWindow: return KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: cs)
        case .captureFullscreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: cs)
        case .capturePreviousArea: return KeyCombo(keyCode: UInt32(kVK_ANSI_6), modifiers: cs)
        case .scrollingCapture: return KeyCombo(keyCode: UInt32(kVK_ANSI_7), modifiers: cs)
        case .captureText: return KeyCombo(keyCode: UInt32(kVK_ANSI_8), modifiers: cs)
        case .recordScreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_9), modifiers: cs)
        case .recordGIF: return KeyCombo(keyCode: UInt32(kVK_ANSI_0), modifiers: cs)
        case .recordingStudio: return KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .selfTimer, .toggleDesktopIcons, .openHistory: return nil
        }
    }
}

/// A Carbon-style key combination (modifiers use Carbon flags: cmdKey, shiftKey, optionKey, controlKey).
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyCombo.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let map: [Int: String] = [
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z", kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Tab: "⇥",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return map[Int(code)] ?? "Key\(code)"
    }
}

/// Persists the per-action shortcut configuration and notifies listeners on change.
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    static let didChange = Notification.Name("ShortcutStoreDidChange")
    private let key = "shortcutBindings"

    @Published private(set) var bindings: [ShortcutAction: KeyCombo] = [:]

    private init() { load() }

    func combo(for action: ShortcutAction) -> KeyCombo? { bindings[action] }

    func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        bindings[action] = combo
        save()
    }

    func resetToDefaults() {
        bindings = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.compactMap { a in a.defaultCombo.map { (a, $0) } })
        save()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let raw = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            bindings = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in ShortcutAction(rawValue: k).map { ($0, v) } })
        } else { resetToDefaults() }
    }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { UserDefaults.standard.set(data, forKey: key) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
