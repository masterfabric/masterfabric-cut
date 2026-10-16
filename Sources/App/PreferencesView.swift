import SwiftUI
import Carbon.HIToolbox

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPrefs().tabItem { Label("General", systemImage: "gearshape") }
            ShortcutsPrefs().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            OutputPrefs().tabItem { Label("Output", systemImage: "folder") }
            FormatPrefs().tabItem { Label("Format", systemImage: "photo") }
            QuickAccessPrefs().tabItem { Label("Quick Access", systemImage: "rectangle.on.rectangle") }
            RecordingPrefs().tabItem { Label("Recording", systemImage: "record.circle") }
        }
        .frame(width: 520, height: 400)
    }
}

private struct GeneralPrefs: View {
    @ObservedObject var s = AppSettings.shared
    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(get: { s.launchAtLogin }, set: { LaunchAtLogin.set($0) }))
            Toggle("Play sounds", isOn: Binding(get: { s.playSounds }, set: { s.playSounds = $0 }))
            Toggle("Show menu bar icon", isOn: Binding(get: { s.showMenuBarIcon }, set: { s.showMenuBarIcon = $0 }))
            Toggle("Freeze screen while selecting", isOn: Binding(get: { s.freezeScreen }, set: { s.freezeScreen = $0 }))
            Toggle("Show crosshair", isOn: Binding(get: { s.showCrosshair }, set: { s.showCrosshair = $0 }))
            Toggle("Show magnifier", isOn: Binding(get: { s.showMagnifier }, set: { s.showMagnifier = $0 }))
            Stepper("Self-timer: \(s.timerSeconds)s", value: Binding(get: { s.timerSeconds }, set: { s.timerSeconds = $0 }), in: 1...30)
            Stepper("History limit: \(s.historyLimit)", value: Binding(get: { s.historyLimit }, set: { s.historyLimit = $0 }), in: 10...2000, step: 10)
        }.padding(20)
    }
}

private struct OutputPrefs: View {
    @ObservedObject var s = AppSettings.shared
    var body: some View {
        Form {
            HStack {
                Text("Save to: \(s.saveDirectory.path)").lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                    if p.runModal() == .OK, let u = p.url { s.saveDirectory = u }
                }
            }
            Toggle("Save automatically", isOn: Binding(get: { s.saveAutomatically }, set: { s.saveAutomatically = $0 }))
            Toggle("Copy to clipboard automatically", isOn: Binding(get: { s.copyToClipboard }, set: { s.copyToClipboard = $0 }))
            TextField("Filename template", text: Binding(get: { s.filenameTemplate }, set: { s.filenameTemplate = $0 }))
            Text("Tokens: %Y %m %d %H %M %S").font(.caption).foregroundStyle(.secondary)
            Toggle("Include window shadow", isOn: Binding(get: { s.windowShadow }, set: { s.windowShadow = $0 }))
        }.padding(20)
    }
}

private struct FormatPrefs: View {
    @ObservedObject var s = AppSettings.shared
    var body: some View {
        Form {
            Picker("Image format", selection: Binding(get: { s.imageFormat }, set: { s.imageFormat = $0 })) {
                ForEach(ImageFormat.allCases) { Text($0.displayName).tag($0) }
            }
            if s.imageFormat == .jpg {
                Slider(value: Binding(get: { s.jpegQuality }, set: { s.jpegQuality = $0 }), in: 0.1...1) { Text("JPEG quality") }
            }
            Toggle("Retina (2x) resolution", isOn: Binding(get: { s.retina }, set: { s.retina = $0 }))
        }.padding(20)
    }
}

private struct QuickAccessPrefs: View {
    @ObservedObject var s = AppSettings.shared
    var body: some View {
        Form {
            Toggle("Show Quick Access Overlay", isOn: Binding(get: { s.overlayEnabled }, set: { s.overlayEnabled = $0 }))
            Picker("Position", selection: Binding(get: { s.overlayCorner }, set: { s.overlayCorner = $0 })) {
                ForEach(OverlayCorner.allCases) { Text($0.displayName).tag($0) }
            }
            Stepper("Auto-close after \(s.overlayAutoCloseSeconds)s (0 = never)",
                    value: Binding(get: { s.overlayAutoCloseSeconds }, set: { s.overlayAutoCloseSeconds = $0 }), in: 0...60)
            Toggle("Close after action", isOn: Binding(get: { s.overlayCloseAfterAction }, set: { s.overlayCloseAfterAction = $0 }))
        }.padding(20)
    }
}

private struct RecordingPrefs: View {
    @ObservedObject var s = AppSettings.shared
    var body: some View {
        Form {
            Picker("Video FPS", selection: Binding(get: { s.recordFPS }, set: { s.recordFPS = $0 })) {
                ForEach([24, 30, 60], id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("GIF FPS", selection: Binding(get: { s.gifFPS }, set: { s.gifFPS = $0 })) {
                ForEach([10, 15, 20, 30], id: \.self) { Text("\($0)").tag($0) }
            }
            Toggle("Record microphone", isOn: Binding(get: { s.recordMic }, set: { s.recordMic = $0 }))
            Toggle("Record system audio", isOn: Binding(get: { s.recordSystemAudio }, set: { s.recordSystemAudio = $0 }))
            Toggle("Show mouse clicks", isOn: Binding(get: { s.showClicks }, set: { s.showClicks = $0 }))
            Toggle("Show keystrokes", isOn: Binding(get: { s.showKeystrokes }, set: { s.showKeystrokes = $0 }))
        }.padding(20)
    }
}

private struct ShortcutsPrefs: View {
    @ObservedObject var store = ShortcutStore.shared
    var body: some View {
        VStack {
            List(ShortcutAction.allCases) { a in
                HStack {
                    Text(a.title)
                    Spacer()
                    ShortcutRecorder(combo: Binding(get: { store.combo(for: a) }, set: { store.set($0, for: a) }))
                        .frame(width: 140, height: 24)
                }
            }
            HStack { Spacer(); Button("Reset to Defaults") { store.resetToDefaults() } }.padding(.horizontal)
        }.padding(.vertical, 12)
    }
}

/// Click-to-record shortcut field.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo?

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton(); b.onChange = { combo = $0 }; return b
    }
    func updateNSView(_ v: RecorderButton, context: Context) {
        v.onChange = { combo = $0 }
        v.combo = combo; v.refreshTitle()
    }

    final class RecorderButton: NSButton {
        var combo: KeyCombo?
        var onChange: ((KeyCombo?) -> Void)?
        private var recording = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            bezelStyle = .rounded; target = self; action = #selector(toggle)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { true }

        func refreshTitle() { title = recording ? "Type shortcut…" : (combo?.displayString ?? "Record") }
        @objc func toggle() { recording = true; window?.makeFirstResponder(self); refreshTitle() }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == UInt16(kVK_Escape) { recording = false; refreshTitle(); return }
            if event.keyCode == UInt16(kVK_Delete) { recording = false; combo = nil; onChange?(nil); refreshTitle(); return }
            let mods = KeyCombo.carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else { return }
            let c = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods)
            recording = false; combo = c; onChange?(c); refreshTitle()
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if recording { keyDown(with: event); return true }
            return super.performKeyEquivalent(with: event)
        }
    }
}
