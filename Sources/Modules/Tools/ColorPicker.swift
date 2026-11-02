// MasterFabric Cut — Tools module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import SwiftUI

// MARK: - Model

/// How a picked color is written to the clipboard.
enum ColorFormat: String, CaseIterable, Identifiable {
    case hex, rgb, hsl
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

/// An sRGB color sampled from the screen.
struct PickedColor: Codable, Hashable {
    let r: Int, g: Int, b: Int

    init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }

    init?(_ color: NSColor) {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        func q(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        self.init(r: q(c.redComponent), g: q(c.greenComponent), b: q(c.blueComponent))
    }

    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    var color: Color { Color(nsColor: nsColor) }

    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    var rgb: String { "rgb(\(r), \(g), \(b))" }
    var hsl: String {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let mx = max(rf, gf, bf), mn = min(rf, gf, bf), l = (mx + mn) / 2
        var h = 0.0, s = 0.0
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            switch mx {
            case rf: h = (gf - bf) / d + (gf < bf ? 6 : 0)
            case gf: h = (bf - rf) / d + 2
            default: h = (rf - gf) / d + 4
            }
            h *= 60
        }
        return "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
    }

    func string(_ f: ColorFormat) -> String {
        switch f { case .hex: return hex; case .rgb: return rgb; case .hsl: return hsl }
    }

    /// Black or white, whichever reads better on top of this color.
    var isLight: Bool { (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) > 160 }
}

// MARK: - Tool

/// Screen color picker built on the system loupe (`NSColorSampler`, no Screen Recording needed).
/// Copies the value in the preferred format and remembers recent colors.
@MainActor
final class ColorPickerTool: ObservableObject {
    static let shared = ColorPickerTool()
    static let maxRecents = 16
    private static let key = "tools.recentColors"

    @Published private(set) var recents: [PickedColor] = []
    private var sampler: NSColorSampler?

    private init() {
        if let s = AppStateStore.shared.string(forKey: Self.key), let data = s.data(using: .utf8),
           let list = try? JSONDecoder().decode([PickedColor].self, from: data) {
            recents = list
        }
    }

    var format: ColorFormat {
        get { ColorFormat(rawValue: AppSettings.shared.colorFormat) ?? .hex }
        set { AppSettings.shared.colorFormat = newValue.rawValue; objectWillChange.send() }
    }

    /// Shows the magnifier loupe; clicking copies the color, Esc cancels.
    func pick() {
        guard sampler == nil else { return }
        let s = NSColorSampler()
        sampler = s
        s.show { [weak self] color in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sampler = nil
                guard let color, let picked = PickedColor(color) else { return }
                self.remember(picked)
                self.copy(picked)
            }
        }
    }

    func copy(_ c: PickedColor, as f: ColorFormat? = nil) {
        let value = c.string(f ?? format)
        ToolClipboard.copy(value)
        Toast.show("Copied \(value)", swatch: c.nsColor)
    }

    func remember(_ c: PickedColor) {
        recents.removeAll { $0 == c }
        recents.insert(c, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
        save()
    }

    func clear() { recents = []; save() }

    private func save() {
        let s = (try? JSONEncoder().encode(recents)).flatMap { String(data: $0, encoding: .utf8) }
        AppStateStore.shared.set(s, forKey: Self.key)
    }

    func showWindow() {
        ToolWindows.show("colorPicker", title: "Color Picker") { ColorPickerView(tool: self) }
    }
}

// MARK: - Window

struct ColorPickerView: View {
    @ObservedObject var tool: ColorPickerTool
    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 8), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolHeader(symbol: "eyedropper.halffull", tint: .pink, title: "Color Picker",
                       subtitle: "Pick any pixel on screen and copy its value")
            if let c = tool.recents.first {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.color)
                        .frame(width: 92, height: 92)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.12)))
                        .overlay(Text(c.hex).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(c.isLight ? Color.black.opacity(0.7) : Color.white.opacity(0.9)).padding(6), alignment: .bottom)
                    VStack(spacing: 6) {
                        ForEach(ColorFormat.allCases) { f in valueRow(c, f) }
                    }
                }
            } else {
                Text("No colors yet. Click Pick Color, then click anywhere on screen.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 92)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            HStack {
                Button { tool.pick() } label: { Label("Pick Color", systemImage: "eyedropper") }
                    .buttonStyle(.borderedProminent).tint(.pink)
                    .keyboardShortcut("p", modifiers: .command)
                    .help("Show the loupe; click to copy the color, Esc to cancel (⌘P)")
                Spacer()
                Picker("Copy as", selection: Binding(get: { tool.format }, set: { tool.format = $0 })) {
                    ForEach(ColorFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 190)
                .help("Format used when a picked color is copied")
            }
            if !tool.recents.isEmpty {
                HStack {
                    Text("RECENT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { tool.clear() }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.red)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(tool.recents, id: \.self) { c in
                        ColorSwatchButton(color: c) { tool.copy(c) }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private func valueRow(_ c: PickedColor, _ f: ColorFormat) -> some View {
        HStack(spacing: 8) {
            Text(f.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            Text(c.string(f)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            Spacer(minLength: 4)
            Button { tool.copy(c, as: f) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy \(c.string(f))")
        }
    }
}

/// Round swatch; click copies, hover shows the HEX value.
struct ColorSwatchButton: View {
    let color: PickedColor
    var size: CGFloat = 30
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle().fill(color.color)
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(.primary.opacity(hovering ? 0.5 : 0.15), lineWidth: hovering ? 2 : 1))
                .scaleEffect(hovering ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .help("Copy \(color.hex)")
    }
}
