// MasterFabric Cut — Capture module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import Carbon.HIToolbox

/// Actions that can be bound to a global hotkey.
public enum CaptureAction: String, CaseIterable, Codable, Sendable {
    case captureArea, capturePreviousArea, captureWindow, captureFullscreen
    case captureScrolling, captureText
    case toggleDesktopIcons
    case recordScreen, recordGIF, openStudio, openHistory   // handled by the app shell / Recording module

    public var title: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .capturePreviousArea: return "Capture Previous Area"
        case .captureWindow: return "Capture Window"
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureScrolling: return "Scrolling Capture"
        case .captureText: return "Capture Text (OCR)"
        case .toggleDesktopIcons: return "Toggle Desktop Icons"
        case .recordScreen: return "Record Screen"
        case .recordGIF: return "Record GIF"
        case .openStudio: return "Recording Studio"
        case .openHistory: return "Capture History"
        }
    }

    /// Defaults avoid the system ⇧⌘3/4/5 shortcuts by using ⌃⇧⌘.
    public var defaultBinding: HotkeyBinding? {
        let m: NSEvent.ModifierFlags = [.control, .shift, .command]
        switch self {
        case .captureArea: return .init(keyCode: kVK_ANSI_4, modifiers: m)
        case .capturePreviousArea: return .init(keyCode: kVK_ANSI_5, modifiers: m)
        case .captureWindow: return .init(keyCode: kVK_ANSI_6, modifiers: m)
        case .captureFullscreen: return .init(keyCode: kVK_ANSI_3, modifiers: m)
        case .captureScrolling: return .init(keyCode: kVK_ANSI_7, modifiers: m)
        case .captureText: return .init(keyCode: kVK_ANSI_8, modifiers: m)
        case .toggleDesktopIcons: return .init(keyCode: kVK_ANSI_H, modifiers: m)
        case .recordScreen: return .init(keyCode: kVK_ANSI_R, modifiers: m)
        case .recordGIF: return .init(keyCode: kVK_ANSI_G, modifiers: m)
        case .openStudio: return .init(keyCode: kVK_ANSI_S, modifiers: m)
        case .openHistory: return .init(keyCode: kVK_ANSI_Y, modifiers: m)
        }
    }
}

/// A key + modifier combination. Codable so the Preferences module can persist it.
public struct HotkeyBinding: Codable, Equatable, Sendable {
    public var keyCode: Int
    public var modifierRaw: UInt

    public init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierRaw = modifiers.intersection(.deviceIndependentFlagsMask).rawValue
    }
    public init(event: NSEvent) { self.init(keyCode: Int(event.keyCode), modifiers: event.modifierFlags) }

    public var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierRaw) }

    var carbonModifiers: UInt32 {
        var c: UInt32 = 0
        if modifiers.contains(.command) { c |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { c |= UInt32(shiftKey) }
        if modifiers.contains(.option) { c |= UInt32(optionKey) }
        if modifiers.contains(.control) { c |= UInt32(controlKey) }
        return c
    }

    /// Human readable, e.g. "⌃⇧⌘4".
    public var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + HotkeyBinding.keyName(keyCode)
    }

    static func keyName(_ code: Int) -> String {
        let special: [Int: String] = [kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
                                      kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
        if let s = special[code] { return s }
        let fkeys = [kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                     kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let s = fkeys[code] { return s }
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let layout = unsafeBitCast(ptr, to: CFData.self)
        let data = CFDataGetBytePtr(layout)!.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        UCKeyTranslate(data, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                       OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        return len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "?"
    }
}

/// Registers system-wide hotkeys through Carbon (no Accessibility permission needed).
@MainActor
public final class HotkeyManager {
    public static let shared = HotkeyManager()

    public private(set) var bindings: [CaptureAction: HotkeyBinding] = [:]
    /// Called on the main actor when a registered hotkey fires.
    public var handler: ((CaptureAction) -> Void)?

    private var refs: [CaptureAction: EventHotKeyRef] = [:]
    private var ids: [UInt32: CaptureAction] = [:]
    private var handlerInstalled = false
    private let defaultsKey = "co.masterfabric.cut.hotkeys"
    private let signature: OSType = 0x4D464354 // 'MFCT'

    private init() {}

    /// Load persisted bindings (falling back to defaults) and register them all.
    public func start(handler: @escaping (CaptureAction) -> Void) {
        self.handler = handler
        installHandlerIfNeeded()
        let stored = loadStored()
        for action in CaptureAction.allCases {
            if let b = stored[action] ?? action.defaultBinding { register(action, binding: b, persist: false) }
        }
    }

    /// Bind (or rebind) an action. Pass nil to clear. Returns false if the OS rejected the combination.
    @discardableResult
    public func register(_ action: CaptureAction, binding: HotkeyBinding?, persist: Bool = true) -> Bool {
        installHandlerIfNeeded()
        if let old = refs.removeValue(forKey: action) { UnregisterEventHotKey(old) }
        bindings[action] = nil
        var ok = true
        if let b = binding {
            let id = UInt32(CaptureAction.allCases.firstIndex(of: action)! + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(b.keyCode), b.carbonModifiers, EventHotKeyID(signature: signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs[action] = ref; ids[id] = action; bindings[action] = b } else { ok = false }
        }
        if persist { save() }
        return ok
    }

    public func resetToDefaults() {
        for a in CaptureAction.allCases { register(a, binding: a.defaultBinding, persist: false) }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    public func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll(); ids.removeAll(); bindings.removeAll()
    }

    fileprivate func fire(id: UInt32) { if let a = ids[id] { handler?(a) } }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyManager.shared.fire(id: id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func save() {
        let enc = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        // Explicitly cleared actions are stored as absent; combine with a marker of known actions.
        if let data = try? JSONEncoder().encode(enc) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    private func loadStored() -> [CaptureAction: HotkeyBinding] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let dict = try? JSONDecoder().decode([String: HotkeyBinding].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in CaptureAction(rawValue: k).map { ($0, v) } })
    }
}
