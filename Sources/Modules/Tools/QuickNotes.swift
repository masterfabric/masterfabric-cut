// MasterFabric Cut — Tools module
// Author: Gürkan Fikret Günak · masterfabric.co
import AppKit
import SwiftUI

enum NoteColor: String, Codable, CaseIterable, Identifiable {
    case yellow, pink, blue, green, purple, gray
    var id: String { rawValue }
    var fill: Color {
        switch self {
        case .yellow: return Color(red: 1.00, green: 0.93, blue: 0.55)
        case .pink: return Color(red: 1.00, green: 0.80, blue: 0.86)
        case .blue: return Color(red: 0.76, green: 0.88, blue: 1.00)
        case .green: return Color(red: 0.78, green: 0.95, blue: 0.76)
        case .purple: return Color(red: 0.88, green: 0.82, blue: 1.00)
        case .gray: return Color(red: 0.88, green: 0.88, blue: 0.90)
        }
    }
}

struct QuickNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var text = ""
    var color: NoteColor = .yellow
    var frame = CGRect(x: 0, y: 0, width: 260, height: 220)
}

/// Sticky notes that float above every app and come back after a relaunch.
@MainActor
final class QuickNotes: ObservableObject {
    static let shared = QuickNotes()
    private static let key = "tools.quickNotes"

    @Published private(set) var notes: [QuickNote] = []
    private var panels: [UUID: NSPanel] = [:]
    private var observers: [UUID: [NSObjectProtocol]] = [:]
    private var pendingSave: DispatchWorkItem?

    /// Re-open notes saved by a previous session.
    func restore() {
        guard let s = AppStateStore.shared.string(forKey: Self.key), let data = s.data(using: .utf8),
              let saved = try? JSONDecoder().decode([QuickNote].self, from: data) else { return }
        notes = saved
        saved.forEach(open)
    }

    func newNote() {
        var note = QuickNote()
        note.color = NoteColor.allCases[notes.count % NoteColor.allCases.count]
        if let vf = Optional(NSScreen.underMouse)?.visibleFrame {
            let k = CGFloat(notes.count % 6) * 26
            note.frame.origin = CGPoint(x: vf.maxX - note.frame.width - 40 - k, y: vf.maxY - note.frame.height - 40 - k)
        }
        notes.append(note)
        open(note)
        panels[note.id]?.makeKey()
        save()
    }

    func showAll() {
        if notes.isEmpty { newNote(); return }
        for p in panels.values { p.orderFrontRegardless() }
    }

    func update(_ id: UUID, _ change: (inout QuickNote) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[i])
        scheduleSave()
    }

    func delete(_ id: UUID) {
        if let text = notes.first(where: { $0.id == id })?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let a = NSAlert()
            a.messageText = "Delete this note?"
            a.informativeText = "Its text will be removed from this Mac."
            a.addButton(withTitle: "Delete")
            a.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        observers[id]?.forEach(NotificationCenter.default.removeObserver)
        observers[id] = nil
        panels[id]?.orderOut(nil)
        panels[id] = nil
        notes.removeAll { $0.id == id }
        save()
    }

    func panel(_ id: UUID) -> NSPanel? { panels[id] }

    private func open(_ note: QuickNote) {
        let p = KeyablePanel(contentRect: note.frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                             backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 180, height: 120)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: QuickNoteView(id: note.id, store: self))
        p.setFrame(note.frame, display: false)
        p.orderFrontRegardless()
        panels[note.id] = p
        let id = note.id
        let nc = NotificationCenter.default
        observers[id] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
            nc.addObserver(forName: name, object: p, queue: .main) { [weak self, weak p] _ in
                MainActor.assumeIsolated {
                    guard let f = p?.frame else { return }
                    self?.update(id) { $0.frame = f }
                }
            }
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        pendingSave = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(notes), let s = String(data: data, encoding: .utf8) else { return }
        AppStateStore.shared.set(s, forKey: Self.key)
    }
}

struct QuickNoteView: View {
    let id: UUID
    @ObservedObject var store: QuickNotes

    private var note: QuickNote? { store.notes.first { $0.id == id } }

    var body: some View {
        let color = note?.color ?? .yellow
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(NoteColor.allCases) { c in
                    Circle().fill(c.fill)
                        .overlay(Circle().strokeBorder(.black.opacity(c == color ? 0.55 : 0.15), lineWidth: c == color ? 1.5 : 0.5))
                        .frame(width: 11, height: 11)
                        .onTapGesture { store.update(id) { $0.color = c } }
                        .help(c.rawValue.capitalized)
                }
                Spacer()
                Button { store.newNote() } label: { Image(systemName: "plus") }.help("New note")
                Button { store.delete(id) } label: { Image(systemName: "xmark") }.help("Delete note")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.black.opacity(0.55))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.black.opacity(0.06))
            .dragsWindow({ store.panel(id) })

            TextEditor(text: Binding(get: { note?.text ?? "" }, set: { v in store.update(id) { $0.text = v } }))
                .font(.system(size: 14))
                .foregroundStyle(.black.opacity(0.85))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .background(color.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .light)
    }
}
