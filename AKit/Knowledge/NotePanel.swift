import AKitKnowledge
import SwiftUI

/// The open note tabs and the note in view: read (frontmatter and Markdown) or Edit, which saves
/// the file at once; Properties (kind and fields), Copy, Paste, Open in Obsidian and Delete….
struct NotePanel: View {
    @Environment(KnowledgeModel.self) private var model
    @State private var draft = ""

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if !model.tabs.isEmpty {
                tabBar
                Divider()
            }
            if let entry = model.noteEntry {
                toolbar(entry)
                Divider()
                if model.showingProperties {
                    PropertiesForm(entry: entry)
                    Divider()
                }
                if !model.noteRelations.isEmpty {
                    RelationsView(note: entry.id)
                    Divider()
                }
                if model.editing {
                    TextEditor(text: $draft)
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .onChange(of: draft) { _, text in model.save(text) }
                        .onChange(of: model.text) { _, text in if text != draft { draft = text } }
                } else {
                    NoteReadView(text: model.text, section: model.sectionTarget)
                }
            } else {
                ContentUnavailableView("No note open", systemImage: "doc.text",
                                       description: Text("Pick a note in the list, or New Note… to write one."))
            }
        }
        .onChange(of: model.note, initial: true) { draft = model.text }
        .confirmationDialog("Move the note \(model.deleteRequest ?? "") to the Trash?",
                            isPresented: Binding(get: { model.deleteRequest != nil }, set: { if !$0 { model.deleteRequest = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let id = model.deleteRequest { Task { await model.delete(note: id) } }
            }
        } message: {
            Text("The file goes to the Trash, and its removal is committed in the base's git. Links to it from other notes stay as they are.")
        }
        .alert("Changed on disk", isPresented: Binding(get: { model.noteConflict != nil }, set: { _ in })) {
            Button("Reload") { model.reloadConflictedNote() }
            Button("Keep Mine") { model.keepMineInNoteConflict() }
        } message: {
            Text("The note \(model.noteConflict ?? "") changed on disk while you edit it, in another app like Obsidian or by git. Reload shows the version on disk. Keep Mine saves your text and backs up the one on disk in ~/.akit/backups.")
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.tabs, id: \.self) { id in
                    HStack(spacing: 4) {
                        Text(id.split(separator: "/").last.map(String.init) ?? id).lineLimit(1)
                        Button("Close Tab", systemImage: "xmark") { model.close(tab: id) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("Close the tab; your saved edits are committed now")
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(id == model.note ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .onTapGesture { model.show(tab: id) }
                    .help(id)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    private func toolbar(_ entry: KnowledgeBase.NoteEntry) -> some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.headline).lineLimit(1)
                Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            }
            Spacer()
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Toggle("Edit", systemImage: "pencil", isOn: $model.editing)
                .toggleStyle(.button)
                .help("Edit the note's Markdown. Every change is saved to the file at once and committed when you close the tab, after 5 minutes without edits, or when AKit quits")
            Toggle("Properties", systemImage: "list.bullet.rectangle", isOn: $model.showingProperties)
                .toggleStyle(.button)
                .help("Change the note's kind and fields (its frontmatter), one line each; saved at once, committed with your other edits")
            Button("Copy", systemImage: "doc.on.doc") { model.copy() }
                .help("Copy the note's whole text")
            Button("Paste", systemImage: "doc.on.clipboard") { model.paste() }
                .help("Add the clipboard's text at the end of the note and save it")
            Button("Open in Obsidian", systemImage: "arrow.up.forward.app") { model.openInObsidian() }
                .help("Open the note in Obsidian: the base is a plain Obsidian vault")
            Button("Rename…", systemImage: "character.cursor.ibeam") { model.renameRequest = entry.id }
                .help("Rename the note and every link to it in notes and maps, all or nothing, in one commit")
            Button("Delete…", systemImage: "trash") { model.deleteRequest = entry.id }
                .help("Move the note to the Trash and commit its removal")
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(8)
    }
}

/// Properties: the note's kind (from `kb.yaml`) and one field per field of the kind, then the
/// other frontmatter keys; Add Field… adds a key. A value is saved when you press Return or leave
/// the field: `[a, b]` is a list, an empty value removes the key.
struct PropertiesForm: View {
    @Environment(KnowledgeModel.self) private var model
    let entry: KnowledgeBase.NoteEntry
    @State private var adding = false
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Kind").foregroundStyle(.secondary)
                Picker("Kind", selection: Binding(get: { entry.kind ?? "" }, set: { model.setProperty("kind", to: $0) })) {
                    Text("None").tag("")
                    ForEach(kinds, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("The kind of the note, from the base's kinds (Kinds…); written as kind: in its frontmatter")
            }
            ForEach(model.noteProperties, id: \.key) { property in
                GridRow {
                    Text(property.key).foregroundStyle(.secondary)
                        .help(property.isField ? "A field of the kind \(entry.kind ?? "")" : "Not a field of the kind; kept as it is")
                    PropertyField(key: property.key, value: property.value)
                }
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Button("Add Field…", systemImage: "plus") { adding = true }
                    .controlSize(.small)
                    .help("Add a frontmatter key that the kind doesn't list, like owner or url")
                    .popover(isPresented: $adding) { addField }
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3))
        .id(entry.id)
    }

    /// The base's kinds, and the note's own kind when `kb.yaml` doesn't list it.
    private var kinds: [String] {
        model.kinds + (entry.kind.map { model.kinds.contains($0) ? [] : [$0] } ?? [])
    }

    private var addField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Field").font(.headline)
            Form {
                TextField(text: $newKey, prompt: Text("owner")) { RequiredLabel("Name") }
                TextField(text: $newValue, prompt: Text("team-a, or [a, b] for a list")) { RequiredLabel("Value") }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { adding = false }
                Button("Add") {
                    model.setProperty(newKey.trimmingCharacters(in: .whitespaces), to: newValue)
                    (newKey, newValue, adding) = ("", "", false)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty || newValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// One property's value: saved on Return or when the field loses focus.
private struct PropertyField: View {
    @Environment(KnowledgeModel.self) private var model
    let key: String
    let value: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField(key, text: $draft, prompt: Text("empty"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
                .onChange(of: focused) { _, now in if !now { save() } }
                .help("[a, b] is a list; an empty value removes the line")
            if !value.isEmpty {
                Button("Remove \(key)", systemImage: "minus.circle") { model.setProperty(key, to: "") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Remove the \(key): line from the note")
            }
        }
        .frame(maxWidth: 420)
        .onChange(of: value, initial: true) { _, new in draft = new }
    }

    private func save() {
        if draft != value { model.setProperty(key, to: draft) }
    }
}

/// A note as text: its frontmatter as a small table, then the Markdown body, headings bigger.
struct NoteReadView: View {
    let text: String
    /// A heading to scroll to (a search hit's section).
    var section: String?

    var body: some View {
        let note = KnowledgeNote(text: text)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    let front = note.frontmatter.sorted { $0.key < $1.key }
                    if !front.isEmpty {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                            ForEach(front, id: \.key) { key, value in
                                GridRow {
                                    Text(key).foregroundStyle(.secondary)
                                    Text(Self.describe(value)).textSelection(.enabled)
                                }
                            }
                        }
                        .font(.callout)
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                    ForEach(Array(Self.blocks(note.body).enumerated()), id: \.offset) { _, block in
                        block
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            // The note's text is in the key too: the same heading in another note scrolls again.
            .onChange(of: section.map { [$0, text] }, initial: true) {
                guard let section else { return }
                Task { @MainActor in proxy.scrollTo(Self.anchor(section), anchor: .top) }
            }
        }
    }

    /// The scroll id of a heading's line.
    static func anchor(_ heading: String) -> String { "heading:" + heading }

    static func describe(_ value: Any) -> String {
        if let list = value as? [Any] { return list.map { "\($0)" }.joined(separator: ", ") }
        return "\(value)"
    }

    /// One view per line: `#` headings bigger, code fences monospaced, the rest inline Markdown.
    static func blocks(_ body: Substring) -> [AnyView] {
        var views: [AnyView] = []
        var inFence = false
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence {
                views.append(AnyView(Text(line).font(.body.monospaced()).textSelection(.enabled)))
                continue
            }
            let level = line.prefix { $0 == "#" }.count
            if (1...3).contains(level), line.dropFirst(level).first == " " {
                let title = String(line.dropFirst(level + 1))
                views.append(AnyView(Text(title).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                    .padding(.top, level == 1 ? 2 : 8).id(anchor(title))))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                views.append(AnyView(Spacer().frame(height: 2)))
            } else {
                let attributed = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(line)
                views.append(AnyView(Text(attributed).textSelection(.enabled)))
            }
        }
        return views
    }
}

/// Relations: the arrows to and from the note on every map (read only; draw them on a map). The
/// other note opens on a click, and so does the map.
struct RelationsView: View {
    @Environment(KnowledgeModel.self) private var model
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Relations").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(model.noteRelations, id: \.arrow) { edge in
                let outgoing = edge.from == note
                let other = outgoing ? edge.to : edge.from
                HStack(spacing: 6) {
                    Image(systemName: outgoing ? "arrow.right" : "arrow.left").foregroundStyle(.secondary)
                    Button(other) { model.showRelation(note: other) }
                        .buttonStyle(.link)
                        .help(outgoing ? "\(note) → \(other): open \(other)" : "\(other) → \(note): open \(other)")
                    if let kind = edge.kind { Text("“\(kind)”").foregroundStyle(.secondary) }
                    if let flow = edge.flow {
                        Button("flow \(flow.split(separator: "/").last.map(String.init) ?? flow)") { model.showRelation(note: flow) }
                            .buttonStyle(.link)
                            .help("The note the arrow links: \(flow)")
                    }
                    Spacer()
                    Button(edge.map.split(separator: "/").dropFirst(2).joined(separator: "/")) { model.showRelation(map: edge.map) }
                        .buttonStyle(.link)
                        .help("Open the map \(edge.map)")
                }
                .font(.callout)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
