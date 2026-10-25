import AKitFoundation
import AKitKnowledge
import AppKit
import SwiftUI

/// Add Folder… (K27): a note for a folder on this Mac, so the base is the one way in. Another
/// repository (the backend of this frontend) gets kind service and its origin remote; a folder
/// without git (a local wiki) gets kind folder. The note keeps the folder in `path:`, and agents
/// find it through `akit kb context` and `kb show`. The sheet shows the note before it is
/// written; Add Note writes and commits it (`akit kb add-folder … --yes`).
struct AddFolderSheet: View {
    @Environment(KnowledgeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Snapshots: `--tab add-folder --query <folder>` starts with that folder.
    @State private var folder: URL? = DebugSnapshot.options?.tab == "add-folder"
        ? DebugSnapshot.options?.query.map { URL(filePath: HarnessEnvironment.current.expand($0).path) } : nil
    @State private var area = ""
    @State private var name = ""
    @State private var description = ""
    @State private var working = false

    private var plan: Result<KnowledgeFolderNote, KnowledgeBase.Failure>? {
        guard let base = model.base, let folder, !area.isEmpty else { return nil }
        return Result { () throws(KnowledgeBase.Failure) in
            try base.plan(folder: folder, area: area, name: name.isEmpty ? nil : name, description: description, home: model.home)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Folder").font(.title3.bold())
            Text("A note for a folder on this Mac: another repository, like the backend of this frontend, or a folder without git, like a local wiki. Agents find the folder through the note (akit kb context, akit kb show), so the base is the one way in.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                LabeledContent {
                    HStack {
                        Text(folder.map { FileWalk.tilde($0, home: model.home) } ?? "None")
                            .foregroundStyle(folder == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button("Choose…") { choose() }
                            .help("Pick the folder; ⇧⌘G in the panel takes a typed path, ⇧⌘. shows hidden folders")
                    }
                } label: { RequiredLabel("Folder") }
                Picker(selection: $area) {
                    ForEach(model.areas, id: \.name) { Text($0.name).tag($0.name) }
                } label: { RequiredLabel("Area") }
                TextField("Name", text: $name, prompt: Text(folder?.lastPathComponent ?? "backend"))
                TextField("Description", text: $description, prompt: Text("What it is, in one line (optional)"))
            }
            if model.areas.isEmpty {
                Text("Add an area first: New Area….").font(.callout).foregroundStyle(.secondary)
            }
            switch plan {
            case .success(let plan):
                Text("The note \(plan.note) (kind \(plan.kind)):").font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    Text(plan.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(height: 140)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            case .failure(let failure):
                Label(failure.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add Note") {
                    guard case .success(let plan) = plan else { return }
                    working = true
                    Task {
                        if await model.addFolder(plan) { dismiss() }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || { if case .success = plan { false } else { true } }())
                .help("Write the note and commit it at once")
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if let folder { picked(folder) }
        }
        // The areas may arrive after the sheet (a snapshot opens it at launch).
        .task(id: model.areas.map(\.name)) {
            if area.isEmpty { area = model.area ?? model.areas.first?.name ?? "" }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "The folder the note points to: a repository or any folder"
        panel.directoryURL = folder ?? model.projectsRoot
        if panel.runModal() == .OK, let url = panel.url { picked(url) }
    }

    /// A new folder: its name, and README's first line as the description.
    private func picked(_ url: URL) {
        folder = url
        name = ""
        description = (try? KnowledgeFolderNote.plan(folder: url, area: area.isEmpty ? "x" : area, name: "x", home: model.home).description) ?? ""
    }
}
