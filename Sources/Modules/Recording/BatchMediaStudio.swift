// MasterFabric Cut — Recording module
// Author: Gürkan Fikret Günak · masterfabric.co
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Speech

// MARK: - Model

@MainActor
final class BatchMediaStudioModel: ObservableObject {
    @Published var items: [BatchItem] = []
    @Published var settings = SharedExportSettings()
    @Published var selectedTab: StudioTab = .batch
    @Published var silencePreview: SilenceAnalysis?
    @Published var silencePreviewURL: URL?
    @Published var analyzingSilence = false
    @Published var reframePlan: PortraitReframePlan?
    @Published var planningReframe = false
    @Published var captions: [CaptionCue] = []
    @Published var captionSource: URL?
    @Published var transcriptionLocale = TranscriptionService.preferredTurkish
    @Published var transcriptionInfo = TranscriptionService.availability()
    @Published var isTranscribing = false
    @Published var status: String?
    @Published var subtitleFormat: SubtitleFormat = .srt

    let queue = ProcessingQueue.shared

    struct BatchItem: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var duration: Double?
        var pixelSize: CGSize?
    }

    enum StudioTab: String, CaseIterable, Identifiable {
        case batch, silence, reframe, captions, queue
        var id: String { rawValue }
        var title: String {
            switch self {
            case .batch: return "Batch"
            case .silence: return "Silence"
            case .reframe: return "Portrait"
            case .captions: return "Captions"
            case .queue: return "Queue"
            }
        }
    }

    static let mediaTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg, .mp3, .wav, .aiff]

    func refreshTranscriptionInfo() {
        transcriptionInfo = TranscriptionService.availability(locale: transcriptionLocale)
    }

    func add(_ urls: [URL]) {
        let known = Set(items.map(\.url))
        for u in urls where !known.contains(u) {
            var item = BatchItem(url: u)
            items.append(item)
            Task {
                let asset = AVURLAsset(url: u)
                let d = try? await asset.load(.duration).seconds
                var size: CGSize?
                if let track = try? await asset.loadTracks(withMediaType: .video).first {
                    let n = try? await track.load(.naturalSize)
                    let t = try? await track.load(.preferredTransform)
                    if let n, let t {
                        let r = CGRect(origin: .zero, size: n).applying(t)
                        size = CGSize(width: abs(r.width), height: abs(r.height))
                    }
                }
                await MainActor.run {
                    if let i = self.items.firstIndex(where: { $0.id == item.id }) {
                        self.items[i].duration = d
                        self.items[i].pixelSize = size
                    }
                }
            }
            _ = item
        }
        status = nil
    }

    func chooseFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = Self.mediaTypes
        p.message = "Choose videos or audio to process"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { add(p.urls) }
    }

    func chooseOutputFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { settings.outputFolder = p.url }
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id } }
    func clearItems() { items.removeAll() }

    // MARK: Batch enqueue

    func enqueueBatch() {
        guard !items.isEmpty else { status = "Add at least one file"; return }
        let jobs = items.map {
            MediaQueueJob(source: $0.url, kind: .batchExport,
                          label: "Export · \($0.url.lastPathComponent)")
        }
        queue.enqueueMany(jobs)
        selectedTab = .queue
        runQueue()
        status = "Queued \(jobs.count) export\(jobs.count == 1 ? "" : "s")"
    }

    func enqueueSilence(for url: URL) {
        queue.enqueue(MediaQueueJob(source: url, kind: .silenceRemoval,
                                    label: "Silence · \(url.lastPathComponent)"))
        selectedTab = .queue
        runQueue()
    }

    func enqueueReframe(for url: URL) {
        queue.enqueue(MediaQueueJob(source: url, kind: .portraitReframe,
                                    label: "Portrait · \(url.lastPathComponent)"))
        selectedTab = .queue
        runQueue()
    }

    func runQueue() {
        let settings = self.settings
        queue.start { [weak self] job in
            guard let self else { throw RecordingError.cancelled }
            let dest: URL
            switch job.kind {
            case .batchExport:
                dest = MediaExporter.nonDestructiveURL(for: job.source, suffix: settings.platform.title,
                                                       ext: settings.format.fileExtension,
                                                       folder: settings.outputFolder)
                try await MediaExporter.exportWithSettings(source: job.source, settings: settings, destination: dest) { p in
                    Task { @MainActor in self.queue.updateProgress(id: job.id, p) }
                }
            case .silenceRemoval:
                dest = MediaExporter.nonDestructiveURL(for: job.source, suffix: "no silence",
                                                       ext: "mp4", folder: settings.outputFolder)
                let analysis = try await SilenceRemover.analyze(
                    url: job.source, thresholdDB: settings.silenceThresholdDB,
                    minSilence: settings.silenceMinDuration, padding: settings.paddingAroundSpeech) { p in
                    Task { @MainActor in self.queue.updateProgress(id: job.id, p * 0.4) }
                }
                try await SilenceRemover.exportKeeping(source: job.source, ranges: analysis.keepRanges, destination: dest) { p in
                    Task { @MainActor in self.queue.updateProgress(id: job.id, 0.4 + p * 0.6) }
                }
            case .portraitReframe:
                let size = settings.resolvedSize ?? CGSize(width: 1080, height: 1920)
                dest = MediaExporter.nonDestructiveURL(for: job.source, suffix: "portrait",
                                                       ext: "mp4", folder: settings.outputFolder)
                let plan = try await PortraitReframer.plan(
                    url: job.source, outputSize: size, mode: settings.reframeMode,
                    manualCenterX: settings.manualCropCenterX) { p in
                    Task { @MainActor in self.queue.updateProgress(id: job.id, p * 0.35) }
                }
                try await PortraitReframer.export(source: job.source, plan: plan, destination: dest) { p in
                    Task { @MainActor in self.queue.updateProgress(id: job.id, 0.35 + p * 0.65) }
                }
            case .transcription:
                throw RecordingError.exportFailed("Captions run in the Captions tab (editable before export)")
            }
            if self.queue.isCancelled(job.id) { throw CancellationError() }
            return dest
        }
    }

    // MARK: Silence preview

    func analyzeSilence(for url: URL) {
        analyzingSilence = true
        silencePreview = nil
        silencePreviewURL = url
        status = nil
        let s = settings
        Task {
            do {
                let a = try await SilenceRemover.analyze(
                    url: url, thresholdDB: s.silenceThresholdDB,
                    minSilence: s.silenceMinDuration, padding: s.paddingAroundSpeech)
                silencePreview = a
                status = String(format: "Would remove %.1fs of silence (keeps %.1fs). Original untouched.",
                                a.removedDuration, a.keptDuration)
            } catch {
                status = ErrorPresenter.message(for: error)
            }
            analyzingSilence = false
        }
    }

    // MARK: Reframe preview

    func planReframe(for url: URL) {
        planningReframe = true
        reframePlan = nil
        let s = settings
        let size = s.resolvedSize ?? CGSize(width: 1080, height: 1920)
        Task {
            do {
                let plan = try await PortraitReframer.plan(
                    url: url, outputSize: size, mode: s.reframeMode,
                    manualCenterX: s.manualCropCenterX)
                reframePlan = plan
                status = plan.note
            } catch {
                status = ErrorPresenter.message(for: error)
            }
            planningReframe = false
        }
    }

    // MARK: Captions

    func transcribe(url: URL) {
        isTranscribing = true
        captions = []
        captionSource = url
        status = nil
        let locale = transcriptionLocale
        Task {
            let auth = await TranscriptionService.requestAuthorization()
            refreshTranscriptionInfo()
            guard auth == .authorized else {
                status = "Speech Recognition permission is required. Enable it in System Settings › Privacy & Security › Speech Recognition."
                isTranscribing = false
                return
            }
            do {
                let cues = try await TranscriptionService.transcribe(url: url, locale: locale)
                captions = cues
                status = cues.isEmpty
                    ? "No speech detected (or empty transcript)."
                    : "Transcribed \(cues.count) cue\(cues.count == 1 ? "" : "s"). Edit below, then export SRT/VTT."
            } catch {
                status = ErrorPresenter.message(for: error)
            }
            isTranscribing = false
        }
    }

    func exportCaptions() {
        guard let src = captionSource, !captions.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: subtitleFormat.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = "\(src.deletingPathExtension().lastPathComponent).\(subtitleFormat.fileExtension)"
        panel.directoryURL = settings.outputFolder ?? src.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try TranscriptionService.exportSubtitles(captions, format: subtitleFormat, to: dest)
            status = "Saved \(dest.lastPathComponent)"
            Toast.show("Subtitles saved", symbol: "captions.bubble", tint: .blue)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            status = ErrorPresenter.message(for: error)
        }
    }

#if DEBUG
    func loadDemo() {
        // Synthetic list for UI screenshots — no media files required.
        items = [
            BatchItem(url: URL(fileURLWithPath: "/tmp/demo-interview.mp4"), duration: 182, pixelSize: CGSize(width: 1920, height: 1080)),
            BatchItem(url: URL(fileURLWithPath: "/tmp/demo-clip.mov"), duration: 44, pixelSize: CGSize(width: 1280, height: 720)),
        ]
        settings.platform = .tikTok
        settings.removeSilence = true
        settings.reframePortrait = true
        settings.reframeMode = .faceGuided
        silencePreview = SilenceAnalysis(
            duration: 60,
            silent: [
                SilenceSegment(start: 4.2, end: 7.8),
                SilenceSegment(start: 22.0, end: 25.5),
                SilenceSegment(start: 48.1, end: 51.0),
            ],
            keepRanges: [
                CMTimeRange(start: CMTime(seconds: 0, preferredTimescale: 600), end: CMTime(seconds: 4.2, preferredTimescale: 600)),
                CMTimeRange(start: CMTime(seconds: 7.8, preferredTimescale: 600), end: CMTime(seconds: 22, preferredTimescale: 600)),
            ],
            thresholdDB: -40, minSilence: 0.45)
        silencePreviewURL = items.first?.url
        reframePlan = PortraitReframePlan(
            sourceSize: CGSize(width: 1920, height: 1080),
            outputSize: CGSize(width: 1080, height: 1920),
            centers: [FaceCenterSample(time: 1.0, x: 0.42), FaceCenterSample(time: 2.0, x: 0.45), FaceCenterSample(time: 3.0, x: 0.48)],
            fallbackCenterX: 0.5, facesDetected: true, modeUsed: .faceGuided,
            note: "Face boxes detected on sampled frames. Crop follows smoothed face centers (not lip/speaker ID).")
        captions = [
            CaptionCue(start: 0.4, end: 2.8, text: "Merhaba, MasterFabric Cut ile kayıt alıyoruz."),
            CaptionCue(start: 3.0, end: 5.6, text: "Sessizlikleri kaldırıp dikey dışa aktaracağız."),
            CaptionCue(start: 6.0, end: 8.2, text: "Altyazıları burada düzenleyebilirsiniz."),
        ]
        captionSource = items.first?.url
        transcriptionInfo = TranscriptionService.availability()
        status = "Demo data for screenshots — originals never overwritten."
        queue.enqueueMany([
            MediaQueueJob(source: items[0].url, kind: .batchExport, label: "Export · demo-interview.mp4",
                          status: .running(progress: 0.42)),
            MediaQueueJob(source: items[1].url, kind: .silenceRemoval, label: "Silence · demo-clip.mov",
                          status: .queued),
        ])
    }
#endif
}

// MARK: - Window

@MainActor
enum BatchMediaStudio {
    static let model = BatchMediaStudioModel()

    static func show() {
        let w = ToolWindows.show("batchMediaStudio", title: "Media Studio", resizable: true) {
            BatchMediaStudioView(model: model)
        }
        w.setContentSize(NSSize(width: 820, height: 620))
        #if DEBUG
        if ProcessInfo.processInfo.environment["MFC_DEMO_TOOL"] == "media-studio" {
            model.loadDemo()
            if let tab = ProcessInfo.processInfo.environment["MFC_DEMO_MEDIA_TAB"],
               let parsed = BatchMediaStudioModel.StudioTab(rawValue: tab) {
                model.selectedTab = parsed
            }
        }
        #endif
    }
}

// MARK: - View

struct BatchMediaStudioView: View {
    @ObservedObject var model: BatchMediaStudioModel
    @ObservedObject private var queue = ProcessingQueue.shared
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("", selection: $model.selectedTab) {
                ForEach(BatchMediaStudioModel.StudioTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.bottom, 10)

            Group {
                switch model.selectedTab {
                case .batch: batchTab
                case .silence: silenceTab
                case .reframe: reframeTab
                case .captions: captionsTab
                case .queue: queueTab
                }
            }
            .padding(.horizontal, 16)

            if let s = model.status {
                Text(s).font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.top, 8)
            }
            Spacer(minLength: 8)
        }
        .padding(.top, 14).padding(.bottom, 12)
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { model.refreshTranscriptionInfo() }
    }

    private var header: some View {
        ToolHeader(symbol: "film.stack", tint: .orange,
                   title: "Media Studio",
                   subtitle: "Batch export, silence removal, portrait crop, captions — all on this Mac")
            .padding(.horizontal, 16).padding(.bottom, 10)
    }

    // MARK: Batch

    private var batchTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            fileList
            sharedSettings
            HStack {
                Button("Add Files…") { model.chooseFiles() }
                Button("Clear") { model.clearItems() }.disabled(model.items.isEmpty)
                Spacer()
                Button("Queue Batch Export") { model.enqueueBatch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.items.isEmpty || queue.isRunning)
            }
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.items.isEmpty {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [6]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(dropTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03)))
                    .frame(height: 88)
                    .overlay(Text("Drop videos here or Add Files…").foregroundStyle(.secondary))
                    .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                        handleDrop(providers); return true
                    }
            } else {
                List {
                    ForEach(model.items) { item in
                        HStack {
                            Image(systemName: "film").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.url.lastPathComponent).lineLimit(1)
                                Text(meta(item)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { model.remove(item.id) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 110, maxHeight: 160)
                .listStyle(.inset)
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    handleDrop(providers); return true
                }
            }
        }
    }

    private func meta(_ item: BatchMediaStudioModel.BatchItem) -> String {
        var parts: [String] = []
        if let d = item.duration { parts.append(MediaDuration.format(d)) }
        if let s = item.pixelSize { parts.append("\(Int(s.width))×\(Int(s.height))") }
        return parts.isEmpty ? item.url.path : parts.joined(separator: " · ")
    }

    private var sharedSettings: some View {
        GroupBox("Shared settings (applied to every queued file)") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Profile").foregroundStyle(.secondary)
                    Picker("", selection: $model.settings.platform) {
                        ForEach(ExportPlatform.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(maxWidth: 220)
                    Text(model.settings.platform.detail).font(.caption).foregroundStyle(.secondary)
                }
                if model.settings.platform == .custom {
                    GridRow {
                        Text("Size").foregroundStyle(.secondary)
                        HStack {
                            TextField("W", value: $model.settings.customWidth, format: .number).frame(width: 70)
                            Text("×")
                            TextField("H", value: $model.settings.customHeight, format: .number).frame(width: 70)
                        }
                    }
                }
                GridRow {
                    Text("Quality").foregroundStyle(.secondary)
                    Picker("", selection: $model.settings.quality) {
                        ForEach(ExportQuality.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(maxWidth: 180)
                    HStack {
                        Text("Target MB").foregroundStyle(.secondary)
                        TextField("optional", value: $model.settings.targetFileSizeMB, format: .number)
                            .frame(width: 70)
                    }
                }
                GridRow {
                    Text("Trim").foregroundStyle(.secondary)
                    HStack {
                        Text("Start")
                        TextField("0", value: $model.settings.trimStart, format: .number).frame(width: 60)
                        Text("End")
                        TextField("full", value: Binding(
                            get: { model.settings.trimEnd ?? 0 },
                            set: { model.settings.trimEnd = $0 <= 0 ? nil : $0 }
                        ), format: .number).frame(width: 60)
                        Text("(0 end = full)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Options").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Remove silence (non-destructive)", isOn: $model.settings.removeSilence)
                        Toggle("Portrait reframe", isOn: $model.settings.reframePortrait)
                        Toggle("Never overwrite originals", isOn: $model.settings.keepOriginals).disabled(true)
                    }
                }
                GridRow {
                    Text("Output").foregroundStyle(.secondary)
                    HStack {
                        Button("Folder…") { model.chooseOutputFolder() }
                        Text(model.settings.outputFolder?.path ?? "Same folder as each source")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: Silence

    private var silenceTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Detect quiet stretches, preview what would be cut, then export a new file. Originals stay intact.")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Threshold").foregroundStyle(.secondary)
                    HStack {
                        Slider(value: Binding(
                            get: { Double(model.settings.silenceThresholdDB) },
                            set: { model.settings.silenceThresholdDB = Float($0) }
                        ), in: -60 ... -20)
                        Text("\(Int(model.settings.silenceThresholdDB)) dB").monospacedDigit().frame(width: 56)
                    }
                }
                GridRow {
                    Text("Min silence").foregroundStyle(.secondary)
                    HStack {
                        Slider(value: $model.settings.silenceMinDuration, in: 0.2...2.0)
                        Text(String(format: "%.2fs", model.settings.silenceMinDuration)).monospacedDigit().frame(width: 48)
                    }
                }
                GridRow {
                    Text("Padding").foregroundStyle(.secondary)
                    HStack {
                        Slider(value: $model.settings.paddingAroundSpeech, in: 0...0.4)
                        Text(String(format: "%.2fs", model.settings.paddingAroundSpeech)).monospacedDigit().frame(width: 48)
                    }
                }
            }
            HStack {
                Button("Analyze Selected / First…") {
                    if let u = model.items.first?.url { model.analyzeSilence(for: u) }
                    else { model.chooseFiles(); if let u = model.items.first?.url { model.analyzeSilence(for: u) } }
                }
                .disabled(model.analyzingSilence)
                if model.analyzingSilence { ProgressView().controlSize(.small) }
                Spacer()
                Button("Queue Silence Removal") {
                    if let u = model.silencePreviewURL ?? model.items.first?.url {
                        model.enqueueSilence(for: u)
                    }
                }
                .disabled(model.silencePreview == nil || queue.isRunning)
            }
            if let a = model.silencePreview {
                GroupBox("Preview") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(format: "Duration %.1fs · silence %.1fs · kept %.1fs · %d segment(s)",
                                    a.duration, a.removedDuration, a.keptDuration, a.silent.count))
                        SilenceTimeline(duration: a.duration, silent: a.silent)
                            .frame(height: 28)
                        ForEach(a.silent.prefix(8)) { s in
                            Text(String(format: "Silence %.1f – %.1f (%.1fs)", s.start, s.end, s.duration))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if a.silent.count > 8 {
                            Text("…and \(a.silent.count - 8) more").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(4)
                }
            }
        }
    }

    // MARK: Reframe

    private var reframeTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Crop landscape video into a portrait frame. Face-guided uses Vision face boxes on sampled frames — not speaker identification.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Mode", selection: $model.settings.reframeMode) {
                ForEach(PortraitReframeMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.radioGroup)
            Text(model.settings.reframeMode.detail).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Manual center X")
                Slider(value: $model.settings.manualCropCenterX, in: 0...1)
                Text("\(Int(model.settings.manualCropCenterX * 100))%").monospacedDigit().frame(width: 40)
            }
            Picker("Target profile", selection: $model.settings.platform) {
                ForEach(ExportPlatform.allCases.filter { $0.isPortrait || $0 == .custom || $0 == .original }) {
                    Text($0.title).tag($0)
                }
            }.labelsHidden().frame(maxWidth: 240)
            HStack {
                Button("Plan Reframe…") {
                    if let u = model.items.first?.url { model.planReframe(for: u) }
                    else { model.chooseFiles(); if let u = model.items.first?.url { model.planReframe(for: u) } }
                }.disabled(model.planningReframe)
                if model.planningReframe { ProgressView().controlSize(.small) }
                Spacer()
                Button("Queue Portrait Export") {
                    if let u = model.items.first?.url { model.enqueueReframe(for: u) }
                }.disabled(model.items.isEmpty || queue.isRunning)
            }
            if let plan = model.reframePlan {
                GroupBox("Plan") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plan.note)
                        Text("Source \(Int(plan.sourceSize.width))×\(Int(plan.sourceSize.height)) → \(Int(plan.outputSize.width))×\(Int(plan.outputSize.height))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(plan.facesDetected
                             ? "Faces sampled at \(plan.centers.count) time point(s); export uses median center."
                             : "No faces sampled — manual center will be used.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(4)
                }
            }
        }
    }

    // MARK: Captions

    private var captionsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On-device Speech transcription. Turkish is used when the system language assets support it; Cut never uploads media.")
                .font(.callout).foregroundStyle(.secondary)
            GroupBox("Language availability") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Picker("Locale", selection: $model.transcriptionLocale) {
                            ForEach(TranscriptionService.supportedLocales(), id: \.identifier) { loc in
                                Text(Locale.current.localizedString(forIdentifier: loc.identifier) ?? loc.identifier)
                                    .tag(loc)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                        .onChange(of: model.transcriptionLocale) { _, _ in model.refreshTranscriptionInfo() }
                        Button("Refresh") { model.refreshTranscriptionInfo() }
                    }
                    Label(model.transcriptionInfo.note, systemImage: model.transcriptionInfo.onDeviceSupported ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(model.transcriptionInfo.onDeviceSupported ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(4)
            }
            HStack {
                Button("Transcribe First / Selected…") {
                    if let u = model.items.first?.url { model.transcribe(url: u) }
                    else { model.chooseFiles(); if let u = model.items.first?.url { model.transcribe(url: u) } }
                }.disabled(model.isTranscribing || !model.transcriptionInfo.onDeviceSupported)
                if model.isTranscribing { ProgressView().controlSize(.small) }
                Spacer()
                Picker("", selection: $model.subtitleFormat) {
                    ForEach(SubtitleFormat.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 80)
                Button("Export Subtitles…") { model.exportCaptions() }
                    .disabled(model.captions.isEmpty)
            }
            if !model.captions.isEmpty {
                List {
                    ForEach($model.captions) { $cue in
                        HStack(alignment: .top) {
                            VStack {
                                TextField("start", value: $cue.start, format: .number.precision(.fractionLength(2)))
                                    .frame(width: 64)
                                TextField("end", value: $cue.end, format: .number.precision(.fractionLength(2)))
                                    .frame(width: 64)
                            }.font(.caption.monospacedDigit())
                            TextField("Caption", text: $cue.text, axis: .vertical)
                                .lineLimit(2...4)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 240)
                .listStyle(.inset)
            }
        }
    }

    // MARK: Queue

    private var queueTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(queue.isRunning ? "Processing…" : "Idle").font(.headline)
                ProgressView(value: queue.overallProgress).frame(maxWidth: 180)
                Text("\(Int(queue.overallProgress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Retry Failed") { queue.retryFailed(); model.runQueue() }
                    .disabled(queue.failedCount == 0)
                Button("Cancel All", role: .destructive) { queue.cancelAll() }
                    .disabled(!queue.isRunning && queue.queuedCount == 0)
                Button("Clear Finished") { queue.clearFinished() }
            }
            if queue.jobs.isEmpty {
                Text("No jobs yet. Queue work from Batch, Silence, or Portrait.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List {
                    ForEach(queue.jobs) { job in
                        HStack {
                            statusIcon(job.status)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.label).lineLimit(1)
                                Text(statusText(job)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if case .running(let p) = job.status {
                                ProgressView(value: p).frame(width: 80)
                            }
                            if case .failed = job.status {
                                Button("Retry") { queue.retry(id: job.id); model.runQueue() }
                            }
                            if case .queued = job.status {
                                Button("Cancel") { queue.cancel(id: job.id) }
                            }
                            if case .running = job.status {
                                Button("Cancel") { queue.cancel(id: job.id) }
                            }
                            if case .succeeded(let url) = job.status {
                                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 220)
            }
        }
    }

    private func statusIcon(_ s: MediaJobStatus) -> some View {
        Group {
            switch s {
            case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
            case .running: Image(systemName: "gear").foregroundStyle(.orange)
            case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
            }
        }.frame(width: 18)
    }

    private func statusText(_ job: MediaQueueJob) -> String {
        switch job.status {
        case .queued: return job.retryCount > 0 ? "Queued (retry \(job.retryCount))" : "Queued"
        case .running(let p): return String(format: "Running · %.0f%%", p * 100)
        case .succeeded(let u): return "Done · \(u.lastPathComponent)"
        case .failed(let m): return m
        case .cancelled: return "Cancelled"
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.add([url]) } }
            }
        }
    }
}

private struct SilenceTimeline: View {
    let duration: Double
    let silent: [SilenceSegment]
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.35))
                ForEach(silent) { s in
                    let x = duration > 0 ? CGFloat(s.start / duration) * w : 0
                    let width = duration > 0 ? CGFloat(s.duration / duration) * w : 0
                    Rectangle().fill(Color.red.opacity(0.55))
                        .frame(width: max(2, width)).offset(x: x)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help("Green = kept · red = silence that would be removed")
    }
}
