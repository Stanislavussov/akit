import AKitFoundation
import AKitKnowledge
import AppKit
import SwiftUI

/// Notebook screen (docs/design/notebook.md): short notes, plans and "what I did today" in the
/// knowledge base's `notebook/` folder, one Markdown file per tab, in a Markdown editor with check
/// boxes, images and links. Obsidian reads the same files; AKit commits the edits.
struct NotebookView: View {
    @Environment(NotebookModel.self) private var model
    @Environment(KnowledgeModel.self) private var knowledge
    @Environment(AppModel.self) private var app

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
            if knowledge.base == nil {
                if knowledge.loaded {
                    ContentUnavailableView {
                        Label("No knowledge base", systemImage: "note.text")
                    } description: {
                        Text("The notebook lives in a knowledge base, in its notebook folder beside the notes. Create a base on the Knowledge screen first.")
                    } actions: {
                        Button("Open Knowledge") { app.section = .knowledge }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                NotebookTabBar()
                Divider()
                header
                Divider()
                NotebookEditorView(document: model.document, imageFile: { model.imageFile($0) },
                                   upload: { data, ext in try model.upload(data, ext: ext) }) { message in
                    switch message.type {
                    case "save":
                        if let key = message.body["key"] as? String, let text = message.body["text"] as? String { model.save(key, text: text) }
                    case "drawingOpen":
                        if let link = message.body["link"] as? String { model.openDrawing(link) }
                    case "linkOpen":
                        if let link = message.body["link"] as? String, model.openLink(link) { app.section = .knowledge }
                    case "problem":
                        if let text = message.body["message"] as? String { model.problem = "The editor: \(text)" }
                    default: break
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        .navigationTitle("Notebook")
        .navigationSubtitle(knowledge.base.map { "\($0.name) · \($0.root.appending(path: KnowledgeNotebook.folderName).tildePath)" } ?? "")
        .toolbar { toolbar }
        .sheet(isPresented: $model.newTabRequest) { TabNameSheet(tab: nil) }
        .sheet(item: $model.drawingRequest) { request in NotebookDrawingSheet(request: request) }
        .sheet(isPresented: Binding(get: { model.renameRequest != nil }, set: { if !$0 { model.renameRequest = nil } })) {
            if let tab = model.renameRequest { TabNameSheet(tab: tab) }
        }
        .confirmationDialog("Move the tab \(model.deleteRequest ?? "") to the Trash?",
                            isPresented: Binding(get: { model.deleteRequest != nil }, set: { if !$0 { model.deleteRequest = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let tab = model.deleteRequest { Task { await model.delete(tab) } }
            }
        } message: {
            Text("The tab's Markdown file goes to the Trash, and its removal is committed in the base's git. Its images stay in notebook/assets.")
        }
        .alert("Changed on disk", isPresented: Binding(get: { model.conflict != nil }, set: { _ in })) {
            Button("Reload") { model.reloadConflict() }
            Button("Keep Mine") { model.keepMine() }
        } message: {
            Text("This tab changed on disk after AKit opened it, in Obsidian, by an agent (akit notebook) or by git. Reload shows the version on disk and drops your change. Keep Mine saves your version and backs up the one on disk in ~/.akit/backups.")
        }
        .task {
            (knowledge.projectsRoot, knowledge.brainRoot) = (app.projectsRoot, app.brainRoot)
            await model.load()
        }
    }

    /// The tab's file, what just happened, and Show in Finder.
    private var header: some View {
        HStack(spacing: 8) {
            if let tab = model.tab {
                Text("\(KnowledgeNotebook.folderName)/\(tab).md").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("⌘-click opens a link").font(.caption).foregroundStyle(.tertiary)
            Button("Show in Finder", systemImage: "folder") {
                if let notebook = model.notebook, let tab = model.tab {
                    let file = notebook.file(tab)
                    if FileWalk.isRegularFile(file) {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    } else {
                        NSWorkspace.shared.open(notebook.base.root)
                    }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Show the tab's Markdown file in Finder")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if knowledge.bases.count > 1 {
            ToolbarItem(placement: .navigation) {
                Picker("Base", selection: Binding(get: { knowledge.base }, set: { if let base = $0 { knowledge.choose(base: base) } })) {
                    ForEach(knowledge.bases, id: \.self) { Text($0.name).tag(Optional($0)) }
                }
                .fixedSize()
                .help("The knowledge base of one world (work, personal); the notebook is in its notebook folder")
            }
        }
        ToolbarItem {
            Button("Today", systemImage: "calendar.badge.plus") { Task { await model.today() } }
                .disabled(knowledge.base == nil || model.tab == nil)
                .help("Put today's date as a heading at the top of this tab and the cursor under it: a log of what you did, newest day first")
        }
        ToolbarItem {
            Button("Draw…", systemImage: "pencil.and.scribble") { model.newDrawing() }
                .disabled(knowledge.base == nil || model.tab == nil)
                .help("Draw with Excalidraw; Done puts the drawing into the tab as a picture. Double-click a drawing to change it")
        }
        ToolbarItem {
            Button("New Tab…", systemImage: "plus.square.on.square") { model.newTabRequest = true }
                .disabled(knowledge.base == nil)
                .help("Add a tab: a new Markdown file in the notebook folder, committed at once")
        }
        ToolbarItem {
            GuideButton(guide: .notebook)
        }
    }
}

/// The tabs, in their order: a click shows one, a drag onto another moves it there, the context
/// menu renames or deletes it. + adds one.
private struct NotebookTabBar: View {
    @Environment(NotebookModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.tabs, id: \.self) { tab in
                    Text(tab)
                        .lineLimit(1)
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(tab == model.tab ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                        .onTapGesture { model.show(tab) }
                        .draggable(tab)
                        .dropDestination(for: String.self) { dropped, _ in
                            guard let moved = dropped.first, moved != tab, model.tabs.contains(moved) else { return false }
                            Task { await model.move(moved, to: tab) }
                            return true
                        }
                        .contextMenu {
                            Button("Rename…") { model.renameRequest = tab }
                            Button("Delete…", role: .destructive) { model.deleteRequest = tab }
                        }
                        .help("notebook/\(tab).md: drag to move it, right-click to rename or delete it")
                }
                Button("New Tab…", systemImage: "plus") { model.newTabRequest = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Add a tab: a new Markdown file in the notebook folder")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }
}

/// New Tab… (`tab` nil) and Rename…: the tab's name, which is its file's name.
private struct TabNameSheet: View {
    @Environment(NotebookModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tab: String?
    @State private var name = ""
    @State private var working = false

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let problem: String? = trimmed.isEmpty ? nil : { () -> String? in
            do throws(KnowledgeBase.Failure) { _ = try KnowledgeNotebook.checkedName(trimmed); return nil } catch { return error.message }
        }()
        VStack(alignment: .leading, spacing: 12) {
            Text(tab == nil ? "New Tab" : "Rename Tab").font(.title3.bold())
            Text(tab == nil
                ? "A tab is one Markdown file in the notebook folder of the knowledge base, like notebook/Plans.md. Obsidian sees it too."
                : "Renames notebook/\(tab ?? "").md; the tab keeps its place. One commit.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField(text: $name, prompt: Text("Plans")) { RequiredLabel("Name") }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(tab == nil ? "Add Tab" : "Rename") {
                    working = true
                    Task {
                        let done = if let tab { await model.rename(tab, to: trimmed) } else { await model.addTab(trimmed) }
                        working = false
                        if done { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty || problem != nil || working || trimmed == tab)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            name = tab ?? (DebugSnapshot.options?.tab == "notebook-new" ? DebugSnapshot.options?.query ?? "" : "")
        }
    }
}
