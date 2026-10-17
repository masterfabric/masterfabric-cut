import SwiftUI
import Carbon.HIToolbox

enum PrefsPane: String, CaseIterable, Identifiable {
    case general, capture, recording, studio, quickAccess, shortcuts, permissions, storage, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .capture: return "Capture"
        case .recording: return "Recording"
        case .studio: return "Studio"
        case .quickAccess: return "Quick Access"
        case .shortcuts: return "Shortcuts"
        case .permissions: return "Permissions"
        case .storage: return "Storage & History"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .capture: return "camera.viewfinder"
        case .recording: return "record.circle.fill"
        case .studio: return "video.badge.waveform"
        case .quickAccess: return "rectangle.on.rectangle"
        case .shortcuts: return "command"
        case .permissions: return "lock.shield.fill"
        case .storage: return "internaldrive.fill"
        case .about: return "info.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .general: return .gray
        case .capture: return .blue
        case .recording: return .red
        case .studio: return .orange
        case .quickAccess: return .purple
        case .shortcuts: return .indigo
        case .permissions: return .green
        case .storage: return .brown
        case .about: return .teal
        }
    }
}

struct PreferencesView: View {
    @State private var pane: PrefsPane = .general

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            VStack(spacing: 0) {
            BrandHeader(iconSize: 22, font: .system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            List(PrefsPane.allCases, selection: $pane) { p in
                Label { Text(p.title) } icon: { IconTile(symbol: p.symbol, color: p.color) }
                    .tag(p)
                    .help(p.title)
            }
            }
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralPane()
                case .capture: CapturePane()
                case .recording: RecordingPane()
                case .studio: StudioPane()
                case .quickAccess: QuickAccessPane()
                case .shortcuts: ShortcutsPane()
                case .permissions: PermissionsPane()
                case .storage: StoragePane()
                case .about: AboutPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 720, height: 520)
    }
}

/// Rounded colored tile with a white SF Symbol, like System Settings.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// A control with a short gray helper text underneath.
private struct Option<Content: View>: View {
    let hint: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            content
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

private func flag(_ s: AppSettings, _ title: String, _ hint: String, _ kp: ReferenceWritableKeyPath<AppSettings, Bool>,
                  after: (() -> Void)? = nil) -> some View {
    Option(hint: hint) {
        Toggle(title, isOn: Binding(get: { s[keyPath: kp] }, set: { s[keyPath: kp] = $0; after?() })).help(hint)
    }
}

// MARK: Panes

private struct GeneralPane: View {
    @ObservedObject var s = AppSettings.shared
    var body: some View {
        Form {
            Section("Startup") {
                Option(hint: "Start MasterFabric Cut automatically when you log in.") {
                    Toggle("Launch at login", isOn: Binding(get: { s.launchAtLogin }, set: { LaunchAtLogin.set($0) }))
                        .help("Start MasterFabric Cut automatically when you log in")
                }
            }
            Section("Appearance") {
                flag(s, "Show menu bar icon", "Keep the scissors icon in the menu bar.", \.showMenuBarIcon)
                flag(s, "Show floating launcher button", "A draggable button that opens the action palette from anywhere.", \.showLauncher,
                     after: { FloatingLauncher.shared.refresh() })
            }
            Section("Feedback") {
                flag(s, "Play sounds", "Play a shutter sound after each capture.", \.playSounds)
            }
        }
    }
}

private struct CapturePane: View {
    @ObservedObject var s = AppSettings.shared
    var body: some View {
        Form {
            Section("Selection") {
                flag(s, "Freeze screen while selecting", "Freeze the screen contents while you choose a region.", \.freezeScreen)
                flag(s, "Show crosshair", "Show guide lines across the screen while selecting.", \.showCrosshair)
                flag(s, "Show magnifier", "Show a pixel magnifier next to the cursor while selecting.", \.showMagnifier)
                Option(hint: "Seconds to count down before a self-timer capture.") {
                    Stepper("Self-timer: \(s.timerSeconds)s", value: Binding(get: { s.timerSeconds }, set: { s.timerSeconds = $0 }), in: 1...30)
                        .help("Seconds to count down before a self-timer capture")
                }
            }
            Section("Image") {
                Option(hint: "File format for saved screenshots.") {
                    Picker("Format", selection: Binding(get: { s.imageFormat }, set: { s.imageFormat = $0 })) {
                        ForEach(ImageFormat.allCases) { Text($0.displayName).tag($0) }
                    }.help("File format for saved screenshots")
                }
                if s.imageFormat == .jpg {
                    Option(hint: "Higher quality means larger files.") {
                        Slider(value: Binding(get: { s.jpegQuality }, set: { s.jpegQuality = $0 }), in: 0.1...1) { Text("JPEG quality") }
                            .help("Higher quality means larger files")
                    }
                }
                flag(s, "Retina (2x) resolution", "Capture at full Retina pixel density.", \.retina)
                flag(s, "Include window shadow", "Keep the macOS drop shadow when capturing a window.", \.windowShadow)
            }
            Section("After capture") {
                flag(s, "Save automatically", "Save every capture to the save folder right away.", \.saveAutomatically)
                flag(s, "Copy to clipboard", "Copy every capture to the clipboard.", \.copyToClipboard)
            }
        }
    }
}

private struct RecordingPane: View {
    @ObservedObject var s = AppSettings.shared
    var body: some View {
        Form {
            Section("Quality") {
                Option(hint: "Frames per second for MP4 recordings.") {
                    Picker("Video FPS", selection: Binding(get: { s.recordFPS }, set: { s.recordFPS = $0 })) {
                        ForEach([24, 30, 60], id: \.self) { Text("\($0)").tag($0) }
                    }.help("Frames per second for MP4 recordings")
                }
                Option(hint: "Frames per second for GIF recordings. Lower is smaller.") {
                    Picker("GIF FPS", selection: Binding(get: { s.gifFPS }, set: { s.gifFPS = $0 })) {
                        ForEach([10, 15, 20, 30], id: \.self) { Text("\($0)").tag($0) }
                    }.help("Frames per second for GIF recordings")
                }
            }
            Section("Audio") {
                flag(s, "Record microphone", "Add your microphone to screen recordings.", \.recordMic)
                flag(s, "Record system audio", "Add the Mac's sound output to screen recordings.", \.recordSystemAudio)
            }
            Section("Focus") {
                flag(s, "Dim outside recorded area", "While recording an area or window, darken everything outside it. The dim never appears in the video.", \.recordDimEnabled)
                if s.recordDimEnabled {
                    Option(hint: "How dark the area outside the recording is.") {
                        HStack {
                            Text("Dim strength")
                            Slider(value: Binding(get: { s.recordDimOpacity }, set: { s.recordDimOpacity = $0 }), in: 0.2...0.8)
                                .help("How dark the area outside the recording is")
                            Text("\(Int(s.recordDimOpacity * 100))%").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Overlays") {
                flag(s, "Show mouse clicks", "Highlight clicks in the recording.", \.showClicks)
                flag(s, "Show keystrokes", "Display pressed keys in the recording.", \.showKeystrokes)
            }
        }
    }
}

private struct StudioPane: View {
    @ObservedObject var s = AppSettings.shared
    var body: some View {
        Form {
            Section("Recording") {
                Option(hint: "Countdown before Recording Studio starts recording. 0 starts immediately.") {
                    Stepper("Countdown: \(s.studioCountdown)s", value: Binding(get: { s.studioCountdown }, set: { s.studioCountdown = $0 }), in: 0...10)
                        .help("Countdown before the Studio starts recording")
                }
            }
            Section("Webcam bubble") {
                Option(hint: "Default shape of the camera bubble.") {
                    Picker("Shape", selection: Binding(get: { s.studioShape }, set: { s.studioShape = $0 })) {
                        ForEach(CameraBubbleShape.allCases) { Text($0.title).tag($0.rawValue) }
                    }.help("Default shape of the camera bubble")
                }
                flag(s, "Mirror camera", "Flip the preview horizontally like a mirror.", \.studioMirror)
            }
            Section { Text("Applied the next time Recording Studio opens. Audio and overlays follow the Recording settings.")
                .font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct QuickAccessPane: View {
    @ObservedObject var s = AppSettings.shared
    var body: some View {
        Form {
            Section("Overlay") {
                flag(s, "Show Quick Access overlay", "Show a floating preview after every capture.", \.overlayEnabled)
                Option(hint: "Screen corner where previews appear.") {
                    Picker("Position", selection: Binding(get: { s.overlayCorner }, set: { s.overlayCorner = $0 })) {
                        ForEach(OverlayCorner.allCases) { Text($0.displayName).tag($0) }
                    }.help("Screen corner where the preview appears")
                }
            }
            Section("Behavior") {
                Option(hint: "Hovering a preview pauses the timer. 0 keeps it until dismissed.") {
                    Stepper(s.overlayAutoCloseSeconds == 0 ? "Auto-close: never" : "Auto-close after \(s.overlayAutoCloseSeconds)s",
                            value: Binding(get: { s.overlayAutoCloseSeconds }, set: { s.overlayAutoCloseSeconds = $0 }), in: 0...60)
                        .help("Seconds before the preview disappears on its own")
                }
                flag(s, "Close after action", "Dismiss the preview after Copy or Save.", \.overlayCloseAfterAction)
            }
        }
    }
}

private struct ShortcutsPane: View {
    @State private var tick = 0
    var body: some View {
        Form {
            Section {
                ForEach(CaptureAction.allCases, id: \.self) { a in
                    LabeledContent(a.title) {
                        ShortcutRecorder(combo: Binding(
                            get: { _ = tick; return HotkeyManager.shared.bindings[a] },
                            set: { HotkeyManager.shared.register(a, binding: $0); tick += 1 }))
                            .frame(width: 140, height: 24)
                            .help("Click, then press a shortcut. Delete clears it, Esc cancels.")
                    }
                }
            } header: { Text("Global shortcuts") } footer: {
                Text("Click a field and press a key combination with ⌘, ⌥, ⌃ or ⇧.")
            }
            Section {
                Button("Reset to Defaults") { HotkeyManager.shared.resetToDefaults(); tick += 1 }
                    .help("Restore the default keyboard shortcuts")
            }
        }
    }
}

private struct PermissionsPane: View {
    @State private var tick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases, id: \.self) { p in row(p) }
            } header: { Text("System access") } footer: {
                Text("Status updates live. Screen Recording and Accessibility may require restarting the app after you grant them.")
            }
        }
        .onReceive(timer) { _ in tick += 1 }
    }

    private func info(_ p: Permission) -> (String, String, Color) {
        switch p {
        case .screen: return ("Screen Recording", "rectangle.dashed.badge.record", .red)
        case .camera: return ("Camera", "video.fill", .blue)
        case .microphone: return ("Microphone", "mic.fill", .orange)
        case .accessibility: return ("Accessibility", "accessibility", .indigo)
        }
    }
    private func hint(_ p: Permission) -> String {
        switch p {
        case .screen: return "Required to capture screenshots and record the screen."
        case .camera: return "Used for the webcam bubble in Recording Studio."
        case .microphone: return "Used to record voice with screen recordings."
        case .accessibility: return "Used to show keystrokes and detect clicks while recording."
        }
    }

    @ViewBuilder private func row(_ p: Permission) -> some View {
        let _ = tick
        let status = PermissionManager.shared.status(p)
        let (title, symbol, color) = info(p)
        HStack(spacing: 10) {
            IconTile(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(hint(p)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            badge(status)
            if status != .granted {
                Button(status == .notDetermined ? "Grant" : "Open Settings") {
                    if status == .notDetermined { Task { await PermissionManager.shared.request(p); tick += 1 } }
                    else { NSWorkspace.shared.open(p.settingsURL) }
                }
                .help(status == .notDetermined ? "Ask macOS for \(title) access" : "Open the \(title) pane in System Settings")
            }
        }
        .padding(.vertical, 2)
    }

    private func badge(_ s: PermissionStatus) -> some View {
        let (text, color): (String, Color) = switch s {
        case .granted: ("Granted", .green)
        case .notDetermined: ("Not Set", .orange)
        case .denied: ("Denied", .red)
        }
        return Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

private struct StoragePane: View {
    @ObservedObject var s = AppSettings.shared
    @ObservedObject var history = CaptureHistoryStore.shared
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Save location") {
                Option(hint: "Captures are saved here when Save automatically is on.") {
                    LabeledContent("Folder") {
                        HStack {
                            Text(s.saveDirectory.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("Choose…") {
                                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                                if p.runModal() == .OK, let u = p.url { s.saveDirectory = u }
                            }.help("Choose the folder where captures are saved")
                        }
                    }
                }
                Option(hint: "Tokens: %Y year, %m month, %d day, %H hour, %M minute, %S second.") {
                    TextField("Filename", text: Binding(get: { s.filenameTemplate }, set: { s.filenameTemplate = $0 }))
                        .help("Filename template using strftime tokens")
                }
            }
            Section("History") {
                Option(hint: "Oldest items are removed beyond this limit.") {
                    Stepper("Keep up to \(s.historyLimit) items", value: Binding(get: { s.historyLimit }, set: {
                        s.historyLimit = $0; history.maxItems = $0
                    }), in: 10...2000, step: 10).help("Maximum number of items kept in Capture History")
                }
                LabeledContent("Stored items", value: "\(history.items.count)")
                HStack {
                    Button("Show History") { AnnotateModule.shared.showHistory() }.help("Open Capture History")
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                        .disabled(history.items.isEmpty).help("Delete all items from Capture History")
                }
            }
        }
        .confirmationDialog("Clear all capture history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { history.clear() }
        } message: { Text("This removes every item stored in history. Files you saved elsewhere are not affected.") }
    }
}

private struct AboutPane: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(b))"
    }
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Group {
                BrandIcon(size: 96)
            }
            Text("MasterFabric Cut").font(.title.bold())
            Text(version).foregroundStyle(.secondary)
            Text("by Gürkan Fikret Günak · masterfabric.co").font(.callout)
            Link("masterfabric.co", destination: URL(string: "https://masterfabric.co")!).help("Open masterfabric.co")
            Text("Released under the MIT License.").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
