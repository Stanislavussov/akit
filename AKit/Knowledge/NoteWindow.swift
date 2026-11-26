import AKitKnowledge
import AppKit
import SwiftUI

/// Which note a note window shows: the base folder and the note id. Codable, so Open in New
/// Window can pass it to its own window.
struct NoteWindowRef: Codable, Hashable {
    let base: String
    let note: String
}

/// A note in its own window (K44): Open in New Window on a board card or a note in the list, so a
/// task can be read beside the board or the code. It reads the note from disk, again whenever the
/// Knowledge screen reads the base or saves a note, so a move on the board or an edit in the main
/// window shows here at once. A task note gets its status as a picker (the same one-line write as
/// a drag on the board) and its missing fields in red; a `[[link]]` opens its note in another
/// window. Editing stays in the main window: Show in AKit.
struct NoteWindow: View {
    static let id = "note"
    let ref: NoteWindowRef

    var body: some View {
        if let model = KnowledgeModel.current {
            NoteWindowContent(model: model, ref: ref)
        } else {
            ContentUnavailableView("AKit's main window is closed", systemImage: "macwindow",
                                   description: Text("Open AKit's window again, then open the note from it."))
        }
    }
}

/// The window's view; the Knowledge screen also shows it in its main window for snapshots
/// (`--tab note-window --select <note>`), since a second window can't be captured.
struct NoteWindowContent: View {
    let model: KnowledgeModel
    let ref: NoteWindowRef
    @Environment(\.openWindow) private var openWindow
    @State private var text: String?

    private var file: URL { KnowledgeBase(root: URL(filePath: ref.base)).noteFile(ref.note) }
    /// The window's note is in the base the main window shows: its writes go through that model.
    private var sameBase: Bool { model.base?.root.standardizedFileURL.path == URL(filePath: ref.base).standardizedFileURL.path }

    var body: some View {
        let note = text.map(KnowledgeNote.init(text:))
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(note?.title ?? ref.note).font(.headline).lineLimit(1)
                    Text("areas/\(ref.note).md").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if let note, note.kind == KnowledgeTask.kind { statusPicker(note) }
                Button("Show in AKit", systemImage: "macwindow") {
                    model.showFromWindow(ref.note)
                    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(GuideView.mainWindowID) == true }?.makeKeyAndOrderFront(nil)
                }
                .disabled(!sameBase)
                .help("Open the note in AKit's main window, to edit it or see it beside the board")
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    .help("Show the note's .md file in Finder")
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
            .padding(10)
            Divider()
            if let note {
                let problems = note.kind == KnowledgeTask.kind ? KnowledgeTask.problems(note) : []
                if !problems.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red) }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
                NoteReadView(text: note.text) { link in
                    if let target = model.noteWindowLink(link, from: ref.note) {
                        openWindow(id: NoteWindow.id, value: NoteWindowRef(base: ref.base, note: target))
                    }
                }
            } else {
                ContentUnavailableView("The note is gone", systemImage: "doc.questionmark",
                                       description: Text("areas/\(ref.note).md was moved, renamed or deleted."))
            }
        }
        .navigationTitle(note?.title ?? ref.note)
        .task(id: "\(ref.base)|\(ref.note)|\(model.diskRevision)") { text = KnowledgeNote.load(file)?.text }
    }

    /// The card's column: picking one sets `status:` as a drag on the board does.
    private func statusPicker(_ note: KnowledgeNote) -> some View {
        let current = KnowledgeTask.text(note.frontmatter["status"]).flatMap(KnowledgeTask.Status.init)
        return Picker("Status", selection: Binding(get: { current }, set: { status in
            if let status { model.move(card: ref.note, to: status) }
        })) {
            if current == nil { Text("No status").tag(KnowledgeTask.Status?.none) }
            ForEach(KnowledgeTask.Status.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(!sameBase)
        .help("The task's status: the column of its card on the board. Picking one writes the note's status: line")
    }
}
