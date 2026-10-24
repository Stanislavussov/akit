import AKitBrain
import AKitFoundation
import AKitKnowledge
import AppKit
import SwiftUI

/// Knowledge screen (`docs/design/knowledge.md`): the base's spaces (areas), their notes and the
/// note panel. Notes are plain Markdown in the world's base folder (by default
/// `~/.akit/local/knowledge/<world>`, Settings → Knowledge sets another), a local git repo
/// without a remote; AKit commits your edits in batches.
struct KnowledgeView: View {
    @Environment(KnowledgeModel.self) private var model
    /// Snapshots: `--tab new-area|new-note|create-base|kinds|area-settings`.
    @State private var sheet: Sheet? = DebugSnapshot.options?.tab.flatMap(Sheet.init(rawValue:))
    @State private var areaToDelete: String?
    /// Add Sample Base… / Remove Sample Base… waiting for confirmation. Snapshots: `--tab sample-remove`.
    @State private var sampleRequest: SampleRequest? = DebugSnapshot.options?.tab == "sample-remove" ? .remove : nil

    enum SampleRequest { case add, remove }

    enum Sheet: String, Identifiable {
        case createBase = "create-base", newArea = "new-area", newNote = "new-note", kinds, areaSettings = "area-settings"
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
                        Text("A knowledge base holds notes about your services, flows and teams as Markdown files in a local git repo without a remote, by default in ~/.akit/local/knowledge (Settings → Knowledge sets another folder, like one in your Obsidian vault). Agents read it; you write it here or in Obsidian.")
                    } actions: {
                        Button("Create Base…") { sheet = .createBase }
                        Button("Add Sample Base…") { sampleRequest = .add }
                            .help("A separate base with made-up notes that shows what the Knowledge screen can do")
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
                Button("Kinds…", systemImage: "tag") { sheet = .kinds }
                    .disabled(model.base == nil)
                    .help("The kinds of notes in this base (service, flow, team…) and the fields of each, kept in kb.yaml")
            }
            ToolbarItem {
                Menu("Sample Base", systemImage: "shippingbox") {
                    Button("Add Sample Base…") { sampleRequest = .add }
                    Button("Remove Sample Base…") { sampleRequest = .remove }
                        .disabled(model.sampleBase == nil)
                }
                .help("A separate base, sample, with made-up notes that shows every feature; remove it when you are done")
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
            case .kinds: KindsSheet()
            case .areaSettings: AreaSettingsSheet(area: model.area ?? "")
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
        .confirmationDialog(sampleRequest == .remove ? "Move the sample base to the Trash?" : "Add the sample base?",
                            isPresented: Binding(get: { sampleRequest != nil }, set: { if !$0 { sampleRequest = nil } })) {
            if sampleRequest == .remove {
                Button("Move to Trash", role: .destructive) { Task { await model.removeSampleBase() } }
            } else {
                Button("Add Sample Base") { Task { await model.addSampleBase() } }
            }
        } message: {
            if sampleRequest == .remove {
                Text("The whole folder \(model.sampleBase?.root.tildePath ?? "") goes to the Trash. Your other bases stay as they are.")
            } else {
                Text("A separate base, sample, with made-up notes about a shop: two spaces, a note of every kind, links between them. Your bases stay as they are; Remove Sample Base… moves it to the Trash.")
            }
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
                    .help("areas/\(area.name): \(area.notes) note\(area.notes == 1 ? "" : "s")" + (area.title.map { " · \($0)" } ?? ""))
                    .contextMenu {
                        Button("Area Settings…") {
                            model.choose(area: area.name)
                            sheet = .areaSettings
                        }
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
            Text("A folder with areas/ and inbox/, and a git repo that never gets a remote: nothing leaves this Mac. It goes in the world's folder from Settings → Knowledge, by default ~/.akit/local/knowledge/<world>.")
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

/// Kinds…: the kinds of notes in `kb.yaml` and the fields of each. Save writes the file (its commit
/// waits in the queue); Rename… renames a kind in every note at once, in one commit.
struct KindsSheet: View {
    @Environment(KnowledgeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = KnowledgeKinds(kinds: [])
    @State private var fields: [String: String] = [:]
    @State private var newName = ""
    @State private var newFields = ""
    @State private var renaming: String?
    @State private var newKindName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kinds").font(.title3.bold())
            Text("What a note can be about, and the fields its Properties show. Kept in kb.yaml in the base; a note with a kind that isn't listed still works.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Kind").font(.caption).foregroundStyle(.secondary)
                    Text("Fields").font(.caption).foregroundStyle(.secondary)
                    Color.clear.frame(width: 1, height: 1)
                }
                ForEach(draft.kinds, id: \.name) { kind in
                    GridRow {
                        Text(kind.name).fontWeight(.medium)
                        TextField("Fields of \(kind.name)", text: binding(kind.name), prompt: Text("repo, owner"))
                            .labelsHidden()
                            .help("The fields, separated by commas")
                        HStack(spacing: 4) {
                            Button("Rename…") { (renaming, newKindName) = (kind.name, kind.name) }
                                .disabled(changed)
                                .help(changed ? "Save or cancel your other changes first" : "Rename the kind here and in every note of this kind, committed at once")
                            Button("Remove", systemImage: "minus.circle") { draft = (try? draft.removing(kind.name)) ?? draft }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Remove the kind from kb.yaml; its notes keep their kind: line")
                        }
                    }
                }
            }
            HStack {
                TextField("New kind", text: $newName, prompt: Text("library"))
                    .frame(width: 140)
                TextField("Its fields", text: $newFields, prompt: Text("repo, owner"))
                Button("Add Kind") {
                    do {
                        draft = try draft.adding(newName.trimmingCharacters(in: .whitespaces), fields: Self.split(newFields))
                        fields[newName.trimmingCharacters(in: .whitespaces)] = newFields
                        (newName, newFields) = ("", "")
                    } catch {
                        model.problem = error.localizedDescription
                    }
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    if let kinds = edited(), model.save(kinds: kinds) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!changed)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onChange(of: model.kindsFile, initial: true) { reset() }
        .alert("Rename the kind \(renaming ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("New name", text: $newKindName)
            Button("Rename") {
                guard let old = renaming else { return }
                Task {
                    if await model.renameKind(old, to: newKindName) { reset() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every note with kind: \(renaming ?? "") gets the new name, and kb.yaml too: all or nothing, in one commit made now.")
        }
    }

    private func reset() {
        draft = model.kindsFile
        fields = Dictionary(uniqueKeysWithValues: draft.kinds.map { ($0.name, $0.fields.joined(separator: ", ")) })
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { fields[name] ?? "" }, set: { fields[name] = $0 })
    }

    /// The draft with the typed fields; nil (and a problem shown) when a field name can't be used.
    private func edited() -> KnowledgeKinds? {
        var kinds = draft
        do {
            for kind in draft.kinds { kinds = try kinds.settingFields(of: kind.name, to: Self.split(fields[kind.name] ?? "")) }
        } catch {
            model.problem = error.message
            return nil
        }
        return kinds
    }

    private var changed: Bool {
        draft.names != model.kindsFile.names
            || draft.kinds.contains { kind in Self.split(fields[kind.name] ?? "") != model.kindsFile.kind(kind.name)?.fields }
    }

    static func split(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Area Settings…: the space's `area.yaml`: a title, a description and the projects it is about
/// (git remotes, `~/` paths, globs). Save writes the file; its commit waits in the queue.
struct AreaSettingsSheet: View {
    @Environment(KnowledgeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let area: String
    @State private var title = ""
    @State private var description = ""
    @State private var projects: [String] = []
    @State private var newProject = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Area Settings").font(.title3.bold())
            Text("Settings of the space \(area), kept in areas/\(area)/area.yaml. Projects tell AKit and agents which repositories and folders this space is about.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Title", text: $title, prompt: Text("Payments"))
                TextField("Description", text: $description, prompt: Text("Orders, billing and refunds"), axis: .vertical)
                    .lineLimit(2...4)
                LabeledContent("Projects") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(projects, id: \.self) { project in
                            HStack {
                                Text(project).textSelection(.enabled).lineLimit(1)
                                Spacer()
                                Button("Remove \(project)", systemImage: "minus.circle") { projects.removeAll { $0 == project } }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            TextField("Project", text: $newProject, prompt: Text("git@example.com:shop/orders-api.git or ~/Projects/billing"))
                                .labelsHidden()
                                .onSubmit(addProject)
                            Button("Add Project", action: addProject)
                                .disabled(newProject.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .help("A git remote, a ~/ path or a glob like ~/work/pay-*")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    if model.save(area: area, settings: KnowledgeArea(title: title, description: description, projects: projects)) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onChange(of: area, initial: true) {
            guard !area.isEmpty else { return }
            let settings = model.settings(area: area)
            (title, description, projects) = (settings.title ?? "", settings.description ?? "", settings.projects)
        }
    }

    private func addProject() {
        let project = newProject.trimmingCharacters(in: .whitespaces)
        guard !project.isEmpty else { return }
        if !projects.contains(project) { projects.append(project) }
        newProject = ""
    }
}
