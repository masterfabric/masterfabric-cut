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
            Toggle("Launch at login", isOn: Binding(get: { s.launchAtLogin }, set: { LaunchAtLogin.set($0) })).help("Start MasterFabric Cut automatically when you log in")
            Toggle("Play sounds", isOn: Binding(get: { s.playSounds }, set: { s.playSounds = $0 })).help("Play a shutter sound after each capture")
            Toggle("Show menu bar icon", isOn: Binding(get: { s.showMenuBarIcon }, set: { s.showMenuBarIcon = $0 })).help("Show the scissors icon in the menu bar")
            Toggle("Freeze screen while selecting", isOn: Binding(get: { s.freezeScreen }, set: { s.freezeScreen = $0 })).help("Freeze the screen contents while you choose a region")
            Toggle("Show crosshair", isOn: Binding(get: { s.showCrosshair }, set: { s.showCrosshair = $0 })).help("Show crosshair guides while selecting")
            Toggle("Show magnifier", isOn: Binding(get: { s.showMagnifier }, set: { s.showMagnifier = $0 })).help("Show a pixel magnifier while selecting")
            Stepper("Self-timer: \(s.timerSeconds)s", value: Binding(get: { s.timerSeconds }, set: { s.timerSeconds = $0 }), in: 1...30).help("Seconds to count down before a self-timer capture")
            Stepper("History limit: \(s.historyLimit)", value: Binding(get: { s.historyLimit }, set: { s.historyLimit = $0 }), in: 10...2000, step: 10).help("Maximum number of items kept in Capture History")
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
                }.help("Choose the folder where captures are saved")
            }
            Toggle("Save automatically", isOn: Binding(get: { s.saveAutomatically }, set: { s.saveAutomatically = $0 })).help("Save every capture to the save folder right away")
            Toggle("Copy to clipboard automatically", isOn: Binding(get: { s.copyToClipboard }, set: { s.copyToClipboard = $0 })).help("Copy every capture to the clipboard")
            TextField("Filename template", text: Binding(get: { s.filenameTemplate }, set: { s.filenameTemplate = $0 }))
            Text("Tokens: %Y %m %d %H %M %S").font(.caption).foregroundStyle(.secondary)
            Toggle("Include window shadow", isOn: Binding(get: { s.windowShadow }, set: { s.windowShadow = $0 })).help("Keep the macOS drop shadow when capturing a window")
        }.padding(20)
    }
}

private struct FormatPrefs: View {
    @ObservedObject var s = AppSettings.shared
    var body: some View {
        Form {
            Picker("Image format", selection: Binding(get: { s.imageFormat }, set: { s.imageFormat = $0 })) {
                ForEach(ImageFormat.allCases) { Text($0.displayName).tag($0) }
            }.help("File format for saved screenshots")
            if s.imageFormat == .jpg {
                Slider(value: Binding(get: { s.jpegQuality }, set: { s.jpegQuality = $0 }), in: 0.1...1) { Text("JPEG quality") }.help("Higher quality means larger files")
            }
            Toggle("Retina (2x) resolution", isOn: Binding(get: { s.retina }, set: { s.retina = $0 })).help("Record at full Retina pixel density")
        }.padding(20)
    }
}

private struct QuickAccessPrefs: View {
    @ObservedObject var s = AppSettings.shared
    var body: some View {
        Form {
            Toggle("Show Quick Access Overlay", isOn: Binding(get: { s.overlayEnabled }, set: { s.overlayEnabled = $0 })).help("Show a floating preview after every capture")
            Picker("Position", selection: Binding(get: { s.overlayCorner }, set: { s.overlayCorner = $0 })) {
                ForEach(OverlayCorner.allCases) { Text($0.displayName).tag($0) }
            }.help("Screen corner where the preview appears")
            Stepper("Auto-close after \(s.overlayAutoCloseSeconds)s (0 = never)",
                    value: Binding(get: { s.overlayAutoCloseSeconds }, set: { s.overlayAutoCloseSeconds = $0 }), in: 0...60).help("Seconds before the preview disappears on its own; hovering pauses the timer")
            Toggle("Close after action", isOn: Binding(get: { s.overlayCloseAfterAction }, set: { s.overlayCloseAfterAction = $0 })).help("Dismiss the preview after Copy or Save")
        }.padding(20)
    }
}

private struct RecordingPrefs: View {
    @ObservedObject var s = AppSettings.shared
    var body: some View {
        Form {
            Picker("Video FPS", selection: Binding(get: { s.recordFPS }, set: { s.recordFPS = $0 })) {
                ForEach([24, 30, 60], id: \.self) { Text("\($0)").tag($0) }
            }.help("Frames per second for MP4 recordings")
            Picker("GIF FPS", selection: Binding(get: { s.gifFPS }, set: { s.gifFPS = $0 })) {
                ForEach([10, 15, 20, 30], id: \.self) { Text("\($0)").tag($0) }
            }.help("Frames per second for GIF recordings")
            Toggle("Record microphone", isOn: Binding(get: { s.recordMic }, set: { s.recordMic = $0 })).help("Add microphone audio to screen recordings")
            Toggle("Record system audio", isOn: Binding(get: { s.recordSystemAudio }, set: { s.recordSystemAudio = $0 })).help("Add Mac sound output to screen recordings")
            Toggle("Show mouse clicks", isOn: Binding(get: { s.showClicks }, set: { s.showClicks = $0 })).help("Highlight clicks in screen recordings")
            Toggle("Show keystrokes", isOn: Binding(get: { s.showKeystrokes }, set: { s.showKeystrokes = $0 })).help("Show pressed keys in screen recordings")
        }.padding(20)
    }
}

private struct ShortcutsPrefs: View {
    @State private var tick = 0
    var body: some View {
        VStack {
            List(CaptureAction.allCases, id: \.self) { a in
                HStack {
                    Text(a.title)
                    Spacer()
                    ShortcutRecorder(combo: Binding(
                        get: { _ = tick; return HotkeyManager.shared.bindings[a] },
                        set: { HotkeyManager.shared.register(a, binding: $0); tick += 1 }))
                        .frame(width: 140, height: 24)
                }
            }
            HStack { Spacer(); Button("Reset to Defaults") { HotkeyManager.shared.resetToDefaults(); tick += 1 } }.help("Restore the default keyboard shortcuts").padding(.horizontal)
        }.padding(.vertical, 12)
    }
}

/// Click-to-record shortcut field.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: HotkeyBinding?

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton(); b.onChange = { combo = $0 }; return b
    }
    func updateNSView(_ v: RecorderButton, context: Context) {
        v.onChange = { combo = $0 }
        v.combo = combo; v.refreshTitle()
    }

    final class RecorderButton: NSButton {
        var combo: HotkeyBinding?
        var onChange: ((HotkeyBinding?) -> Void)?
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
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard !mods.isEmpty else { return }
            let c = HotkeyBinding(event: event)
            recording = false; combo = c; onChange?(c); refreshTitle()
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if recording { keyDown(with: event); return true }
            return super.performKeyEquivalent(with: event)
        }
    }
}
