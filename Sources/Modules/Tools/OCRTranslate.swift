// MasterFabric Cut — Tools module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import NaturalLanguage
import SwiftUI
#if canImport(Translation)
import Translation
#endif

// MARK: - Model

enum TranslateDirection: String, CaseIterable, Identifiable {
    case auto, trToEn, enToTr
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto (TR ⇄ EN)"
        case .trToEn: return "Turkish → English"
        case .enToTr: return "English → Turkish"
        }
    }
}

@MainActor
final class OCRTranslateModel: ObservableObject {
    @Published var source = ""
    @Published var translated = ""
    @Published var direction: TranslateDirection = .auto
    @Published var busy = false
    @Published var status: String?
    @Published var isError = false
    /// Bumped to ask the SwiftUI translation host to run again.
    @Published private(set) var request = 0

    static var isTranslationAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// (source, target) BCP-47 codes. Auto detects Turkish text and translates it to English, everything else to Turkish.
    var languages: (String, String) {
        switch direction {
        case .trToEn: return ("tr", "en")
        case .enToTr: return ("en", "tr")
        case .auto:
            let r = NLLanguageRecognizer()
            r.languageConstraints = [.turkish, .english]
            r.processString(source)
            return r.dominantLanguage == .turkish ? ("tr", "en") : ("en", "tr")
        }
    }

    var languagesLabel: String {
        let (s, t) = languages
        return "\(s.uppercased()) → \(t.uppercased())"
    }

    func translate() {
        translated = ""
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setStatus("No text was recognized in that area.", error: true); return
        }
        guard Self.isTranslationAvailable else {
            setStatus("Translation needs macOS 15 or later. The recognized text is ready to copy.", error: true); return
        }
        busy = true
        status = nil
        request += 1
    }

    func finish(_ text: String) {
        busy = false
        translated = text
        setStatus("Translated \(languagesLabel) on this Mac", error: false)
    }

    func fail(_ error: Error) {
        busy = false
        setStatus("Translation failed: \(error.localizedDescription). Check System Settings › General › Language & Region › Translation Languages.", error: true)
    }

    func copy(_ text: String, what: String) {
        guard !text.isEmpty else { return }
        ToolClipboard.copy(text)
        Toast.show("\(what) copied", symbol: "character.bubble.fill", tint: .blue)
    }

    private func setStatus(_ s: String, error: Bool) { status = s; isError = error }
}

// MARK: - Tool

/// Select an area → Vision OCR → on-device Apple Translation (TR ⇄ EN) → small result window.
@MainActor
final class OCRTranslateTool {
    static let shared = OCRTranslateTool()
    let model = OCRTranslateModel()

    func captureAndTranslate() {
        Task {
            await AppCoordinator.shared.capture.recognizeTextInArea(languages: ["tr-TR", "en-US"]) { [weak self] text in
                DispatchQueue.main.async { self?.show(text: text) }
            }
        }
    }

    func show(text: String) {
        model.source = text
        showWindow()
        model.translate()
    }

    func showWindow() {
        ToolWindows.show("ocrTranslate", title: "OCR Translate", resizable: true) { OCRTranslateView(model: model) }
    }
}

// MARK: - View

struct OCRTranslateView: View {
    @ObservedObject var model: OCRTranslateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolHeader(symbol: "character.bubble.fill", tint: .blue, title: "OCR Translate",
                       subtitle: "Text from the screen, translated on this Mac")
            HStack(spacing: 8) {
                Picker("", selection: $model.direction) {
                    ForEach(TranslateDirection.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 190)
                .help("Auto translates Turkish text to English and anything else to Turkish")
                Text(model.languagesLabel).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                Spacer()
                Button { OCRTranslateTool.shared.captureAndTranslate() } label: { Label("Capture Again", systemImage: "text.viewfinder") }
                    .help("Select another area of the screen")
                Button { model.translate() } label: { Label("Translate", systemImage: "arrow.right.circle.fill") }
                    .buttonStyle(.borderedProminent).tint(.blue)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.busy || !OCRTranslateModel.isTranslationAvailable)
                    .help("Translate the text on the left (⌘↩)")
            }
            HStack(spacing: 10) {
                pane(title: "RECOGNIZED TEXT", text: $model.source, editable: true) { model.copy(model.source, what: "Text") }
                pane(title: "TRANSLATION", text: .constant(model.translated), editable: false) { model.copy(model.translated, what: "Translation") }
                    .overlay { if model.busy { ProgressView().controlSize(.small) } }
            }
            if let s = model.status { ToolStatus(text: s, isError: model.isError) }
        }
        .padding(18)
        .frame(minWidth: 600, idealWidth: 640, minHeight: 360, idealHeight: 400)
        .modifier(TranslationHost(model: model))
        .onChange(of: model.direction) { _, _ in model.translate() }
    }

    private func pane(title: String, text: Binding<String>, editable: Bool, copy: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: copy) { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
            }
            TextEditor(text: text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(editable ? 0.35 : 0.2), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// Runs Apple's Translation framework via `.translationTask` (macOS 15+). On macOS 14 it does nothing.
private struct TranslationHost: ViewModifier {
    @ObservedObject var model: OCRTranslateModel

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            content.modifier(TranslationRunner(model: model))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct TranslationRunner: ViewModifier {
    @ObservedObject var model: OCRTranslateModel
    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(config) { session in
                let text = await MainActor.run { model.source }
                do {
                    let response = try await session.translate(text)
                    await MainActor.run { model.finish(response.targetText) }
                } catch {
                    await MainActor.run { model.fail(error) }
                }
            }
            .onChange(of: model.request) { _, _ in run() }
            .onAppear { if model.busy { run() } }
    }

    private func run() {
        let (s, t) = model.languages
        let next = TranslationSession.Configuration(source: Locale.Language(identifier: s), target: Locale.Language(identifier: t))
        if config?.source == next.source, config?.target == next.target {
            config?.invalidate()
        } else {
            config = next
        }
    }
}
#endif
