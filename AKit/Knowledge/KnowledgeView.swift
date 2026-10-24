import AKitBrain
import AKitFoundation
import AKitKnowledge
import AppKit
import SwiftUI

/// Knowledge screen (`docs/design/knowledge.md`): the base's spaces (areas), their notes and the
/// note panel. Notes are plain Markdown in `~/.akit/local/knowledge/<world>`, a local git repo
/// without a remote; AKit commits your edits in batches.
struct KnowledgeView: View {
    @Environment(KnowledgeModel.self) private var model
    /// Snapshots: `--tab new-area|new-note|create-base`.
    @State private var sheet: Sheet? = DebugSnapshot.options?.tab.flatMap(Sheet.init(rawValue:))
    @State private var areaToDelete: String?

    enum Sheet: String, Identifiable {
        case createBase = "create-base", newArea = "new-area", newNote = "new-note"
        var id: Self { self }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let problem = model.problem {
                HStack {
                    Label(problem, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.problem = nil }
                }
                .font(.callout)
                .padding(8)
                .background(.orange.opacity(0.15))
                .overlay(alignment: .bottom) { Divider() }
            }
            if DebugSnapshot.options?.tab == "map" {
                // Spike 2.0: the map canvas alone, showing the `.excalidraw` file `--query` names.
                MapCanvasView(scene: DebugSnapshot.options?.query.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
                    ?? #"{"type":"excalidraw","version":2,"elements":[]}"#)
            } else if model.base == nil {
                if model.loaded {
                    ContentUnavailableView {
                        Label("No knowledge base", systemImage: "books.vertical")
                    } description: {
                        Text("A knowledge base holds notes about your services, flows and teams as Markdown files in a local git repo without a remote, in ~/.akit/local/knowledge. Agents read it; you write it here or in Obsidian.")
                    } actions: {
                        Button("Create Base…") { sheet = .createBase }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HSplitView {
                    spaces.frame(minWidth: 150, idealWidth: 180, maxWidth: 260)
                    noteList.frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
                    NotePanel().frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .navigationTitle("Knowledge")
        .navigationSubtitle(model.base.map { "\($0.name) · \($0.root.tildePath)" } ?? "")
        .toolbar {
            if model.bases.count > 1 {
                ToolbarItem(placement: .navigation) {
                    Picker("Base", selection: Binding(get: { model.base }, set: { if let base = $0 { model.choose(base: base) } })) {
                        ForEach(model.bases, id: \.self) { Text($0.name).tag(Optional($0)) }
                    }
                    .fixedSize()
                    .help("The knowledge base of one world (work, personal) on this Mac")
                }
            }
            ToolbarItem {
                Button("New Area…", systemImage: "folder.badge.plus") { sheet = .newArea }
                    .disabled(model.base == nil)
                    .help("Add a space: a folder in areas/ for one part of your work, like payments or logistics")
            }
            ToolbarItem {
                Button("New Note…", systemImage: "square.and.pencil") { sheet = .newNote }
                    .disabled(model.base == nil)
                    .help("Write a new note in a space; it is committed at once")
            }
            ToolbarItem {
                GuideButton(guide: .knowledge)
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .createBase: CreateBaseSheet()
            case .newArea: NewAreaSheet()
            case .newNote: NewNoteSheet()
            }
        }
        .confirmationDialog("Move the space \(areaToDelete ?? "") and all its notes to the Trash?",
                            isPresented: Binding(get: { areaToDelete != nil }, set: { if !$0 { areaToDelete = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let area = areaToDelete { Task { await model.delete(area: area) } }
            }
        } message: {
            Text("The folder goes to the Trash, and its removal is committed in the base's git.")
        }
        .task { await model.load(select: DebugSnapshot.options?.select) }
    }

    private var spaces: some View {
        List(selection: Binding(get: { model.area }, set: { model.choose(area: $0) })) {
            Section("Spaces") {
                ForEach(model.areas, id: \.name) { area in
                    HStack {
                        Label(area.name, systemImage: "folder")
                        Spacer()
                        Text("\(area.notes)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(Optional(area.name))
                    .help("areas/\(area.name): \(area.notes) note\(area.notes == 1 ? "" : "s")")
                    .contextMenu {
                        Button("Show in Finder") {
                            if let base = model.base { NSWorkspace.shared.activateFileViewerSelecting([base.areasFolder.appending(path: area.name)]) }
                        }
                        Button("Delete…", role: .destructive) { areaToDelete = area.name }
                    }
                }
            }
        }
        .overlay {
            if model.areas.isEmpty {
                ContentUnavailableView("No spaces", systemImage: "folder",
                                       description: Text("New Area… adds one, like payments."))
            }
        }
    }

    private var noteList: some View {
        List(selection: Binding(get: { model.note }, set: { if let id = $0 { model.open(id) } })) {
            ForEach(model.notes, id: \.id) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title).fontWeight(.medium).lineLimit(1)
                    Text([note.kind, note.id.split(separator: "/").dropFirst().joined(separator: "/")].compactMap(\.self).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 2)
                .tag(Optional(note.id))
                .contextMenu {
                    Button("Show in Finder") {
                        if let base = model.base { NSWorkspace.shared.activateFileViewerSelecting([base.noteFile(note.id)]) }
                    }
                    Button("Delete…", role: .destructive) { model.deleteRequest = note.id }
                }
            }
        }
        .overlay {
            if model.notes.isEmpty, model.area != nil {
                ContentUnavailableView("No notes", systemImage: "doc.text",
                                       description: Text("New Note… writes the first one in this space."))
            }
        }
    }
}

/// Create Base…: `akit kb init --world NAME`.
struct CreateBaseSheet: View {
    @Environment(KnowledgeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var world = MachineProfile.load(home: HarnessEnvironment.current.homeDirectory).kind.rawValue
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Knowledge Base").font(.title3.bold())
            Text("A folder in ~/.akit/local/knowledge with areas/ and inbox/, and a git repo that never gets a remote: nothing leaves this Mac.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField(text: $world) { RequiredLabel("World") }
                    .help("One word for the world the notes belong to: work or personal")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create Base") {
                    working = true
                    Task {
                        if await model.createBase(world: world) { dismiss() }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(world.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// New Area…: a folder in `areas/`.
struct NewAreaSheet: View {
    @Environment(KnowledgeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Area").font(.title3.bold())
            Text("A space for one part of your work. It holds notes and, later, maps.")
                .foregroundStyle(.secondary)
            Form {
                TextField(text: $name, prompt: Text("payments")) { RequiredLabel("Name") }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add Area") { if model.newArea(name) { dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// New Note…: `akit kb new-note AREA NAME [--kind K]`, committed at once.
struct NewNoteSheet: View {
    @Environment(KnowledgeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var area = ""
    @State private var name = ""
    @State private var kind = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Note").font(.title3.bold())
            Form {
                Picker(selection: $area) {
                    ForEach(model.areas, id: \.name) { Text($0.name).tag($0.name) }
                } label: { RequiredLabel("Area") }
                TextField(text: $name, prompt: Text("orders-api")) { RequiredLabel("Name") }
                Picker("Kind", selection: $kind) {
                    Text("None").tag("")
                    ForEach(model.kinds, id: \.self) { Text($0).tag($0) }
                }
                .help("What the note is about; written as kind: in its frontmatter")
            }
            if model.areas.isEmpty {
                Text("Add an area first: New Area….").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add Note") {
                    working = true
                    Task {
                        if await model.newNote(area: area, name: name, kind: kind.isEmpty ? nil : kind) { dismiss() }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(area.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { area = model.area ?? model.areas.first?.name ?? "" }
    }
}
