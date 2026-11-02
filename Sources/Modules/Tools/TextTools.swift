// MasterFabric Cut — Tools module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import SwiftUI

enum TextToolGroup: String, CaseIterable, Identifiable {
    case json = "JSON", base64 = "Base64", url = "URL", text = "Case"
    var id: String { rawValue }
    var operations: [TextOperation] {
        switch self {
        case .json: return [.jsonPretty, .jsonMinify, .jsonValidate]
        case .base64: return [.base64Encode, .base64Decode]
        case .url: return [.urlEncode, .urlDecode]
        case .text: return [.upper, .lower, .title, .camel, .snake, .kebab]
        }
    }
}

enum TextOperation: String, Identifiable {
    case jsonPretty, jsonMinify, jsonValidate, base64Encode, base64Decode, urlEncode, urlDecode
    case upper, lower, title, camel, snake, kebab
    var id: String { rawValue }
    var title: String {
        switch self {
        case .jsonPretty: return "Pretty"
        case .jsonMinify: return "Minify"
        case .jsonValidate: return "Validate"
        case .base64Encode, .urlEncode: return "Encode"
        case .base64Decode, .urlDecode: return "Decode"
        case .upper: return "UPPER"
        case .lower: return "lower"
        case .title: return "Title Case"
        case .camel: return "camelCase"
        case .snake: return "snake_case"
        case .kebab: return "kebab-case"
        }
    }
}

enum TextToolError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// Pure text transforms (no network): JSON, Base64, URL encoding and case conversion.
enum TextTransform {
    static func apply(_ op: TextOperation, to input: String) throws -> String {
        switch op {
        case .jsonPretty: try validateJSON(input); return reformatJSON(input, pretty: true)
        case .jsonMinify: try validateJSON(input); return reformatJSON(input, pretty: false)
        case .jsonValidate: try validateJSON(input); return input
        case .base64Encode: return Data(input.utf8).base64EncodedString()
        case .base64Decode: return try base64Decode(input)
        case .urlEncode:
            var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
            allowed.insert(charactersIn: "-._~")
            return input.addingPercentEncoding(withAllowedCharacters: allowed) ?? input
        case .urlDecode:
            guard let s = input.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
                throw TextToolError.message("Not valid percent-encoding")
            }
            return s
        case .upper: return input.uppercased(with: .current)
        case .lower: return input.lowercased(with: .current)
        case .title: return input.capitalized(with: .current)
        case .camel:
            return lines(input) { w in
                w.enumerated().map { i, s in i == 0 ? s.lowercased(with: posix) : s.lowercased(with: posix).capitalized(with: posix) }.joined()
            }
        case .snake: return lines(input) { $0.map { $0.lowercased(with: posix) }.joined(separator: "_") }
        case .kebab: return lines(input) { $0.map { $0.lowercased(with: posix) }.joined(separator: "-") }
        }
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Applies a word-based conversion line by line so multi-line input keeps its lines.
    private static func lines(_ input: String, _ join: ([String]) -> String) -> String {
        input.components(separatedBy: "\n").map { join(words($0)) }.joined(separator: "\n")
    }

    /// Splits "someHTTPValue_with-dashes 2x" into [some, HTTP, Value, with, dashes, 2x].
    static func words(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            guard c.isLetter || c.isNumber else {
                if !current.isEmpty { result.append(current); current = "" }
                continue
            }
            if let last = current.last {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let lowerToUpper = last.isLowercase && c.isUppercase
                let acronymEnd = last.isUppercase && c.isUppercase && (next?.isLowercase ?? false)
                let letterToDigit = last.isLetter && c.isNumber
                if lowerToUpper || acronymEnd || letterToDigit { result.append(current); current = "" }
            }
            current.append(c)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func validateJSON(_ s: String) throws {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TextToolError.message("Paste some JSON first") }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        } catch let e as NSError {
            let detail = (e.userInfo["NSDebugDescription"] as? String) ?? e.localizedDescription
            throw TextToolError.message("Invalid JSON: \(detail)")
        }
    }

    /// Re-indents valid JSON without re-ordering keys or changing number formatting.
    static func reformatJSON(_ s: String, pretty: Bool, indent: String = "  ") -> String {
        var out = ""
        var level = 0
        var inString = false
        var escaped = false
        let chars = Array(s)
        func newline() { out += "\n" + String(repeating: indent, count: level) }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            defer { i += 1 }
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true; out.append(c)
            case " ", "\n", "\r", "\t": continue
            case "{", "[":
                out.append(c)
                // Keep empty containers on one line.
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == (c == "{" ? "}" : "]") { out.append(chars[j]); i = j; continue }
                level += 1
                if pretty { newline() }
            case "}", "]":
                level -= 1
                if pretty { newline() }
                out.append(c)
            case ",": out.append(c); if pretty { newline() }
            case ":": out += pretty ? ": " : ":"
            default: out.append(c)
            }
        }
        return out
    }

    static func base64Decode(_ input: String) throws -> String {
        var s = input.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if s.count % 4 != 0 { s += String(repeating: "=", count: 4 - s.count % 4) }
        guard let data = Data(base64Encoded: s) else { throw TextToolError.message("Not valid Base64") }
        guard let text = String(data: data, encoding: .utf8) else {
            throw TextToolError.message("Decoded \(data.count) bytes of binary data (not UTF-8 text)")
        }
        return text
    }
}

@MainActor
final class TextToolsModel: ObservableObject {
    @Published var group: TextToolGroup = .json
    @Published var input = ""
    @Published var output = ""
    @Published var status: String?
    @Published var isError = false

    func run(_ op: TextOperation) {
        do {
            let r = try TextTransform.apply(op, to: input)
            if op == .jsonValidate {
                status = "Valid JSON ✓"; isError = false
            } else {
                output = r
                status = "\(group.rawValue) · \(op.title) — \(r.count) characters"
                isError = false
            }
        } catch {
            status = error.localizedDescription; isError = true
        }
    }

    func pasteInput() { if let s = ToolClipboard.string { input = s } }
    func copyOutput() {
        guard !output.isEmpty else { return }
        ToolClipboard.copy(output)
        Toast.show("Result copied", symbol: "doc.on.doc.fill", tint: .purple)
    }
    func useOutputAsInput() { guard !output.isEmpty else { return }; input = output; output = "" }
}

@MainActor
enum TextToolsWindow {
    static let model = TextToolsModel()
    static func show() {
        if model.input.isEmpty, let s = ToolClipboard.string, s.count < 200_000 { model.input = s }
        ToolWindows.show("textTools", title: "Text Tools", resizable: true) { TextToolsView(model: model) }
    }
}

struct TextToolsView: View {
    @ObservedObject var model: TextToolsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolHeader(symbol: "textformat.alt", tint: .purple, title: "Text Tools",
                       subtitle: "JSON, Base64, URL encoding and case conversion — all on this Mac")
            Picker("", selection: $model.group) { ForEach(TextToolGroup.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 6) {
                ForEach(model.group.operations) { op in
                    Button(op.title) { model.run(op) }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                editor("INPUT", text: $model.input) {
                    Button { model.pasteInput() } label: { Image(systemName: "doc.on.clipboard") }.help("Paste")
                    Button { model.input = ""; model.output = ""; model.status = nil } label: { Image(systemName: "xmark.circle") }.help("Clear")
                }
                editor("RESULT", text: $model.output) {
                    Button { model.useOutputAsInput() } label: { Image(systemName: "arrow.uturn.left") }.help("Use as input")
                    Button { model.copyOutput() } label: { Image(systemName: "doc.on.doc") }.help("Copy result")
                }
            }
            if let s = model.status { ToolStatus(text: s, isError: model.isError) }
        }
        .padding(18)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 420, idealHeight: 460)
    }

    private func editor<B: View>(_ title: String, text: Binding<String>, @ViewBuilder buttons: () -> B) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                buttons()
            }
            .buttonStyle(.borderless)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
