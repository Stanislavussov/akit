import AKitFoundation
import AKitKnowledge
import AKitLab
import AppKit
import SwiftUI

/// The open note tabs and the note in view: read (frontmatter and Markdown) or Edit, which saves
/// the file at once; Find in Note (⌘F), Properties (kind and fields), Copy, Paste, Export PDF…,
/// Open in Obsidian and Delete…. Ask Pi (K30) opens a chat about the note under it.
struct NotePanel: View {
    @Environment(KnowledgeModel.self) private var model
    @State private var draft = ""
    /// The selection in Edit: Ask Pi asks about it.
    @State private var selection: TextSelection?

    var body: some View {
        VStack(spacing: 0) {
            if !model.tabs.isEmpty {
                tabBar
                Divider()
            }
            if let entry = model.noteEntry {
                toolbar(entry)
                HistoryLine(id: entry.id, path: entry.path, words: KnowledgeModel.wordCount(model.text))
                NoteTagsRow(entry: entry).id(entry.id)
                Divider()
                if model.showingProperties {
                    PropertiesForm(entry: entry)
                    Divider()
                }
                if !model.noteRelations.isEmpty {
                    RelationsView(note: entry.id)
                    Divider()
                }
                let checks = model.lintFindings(of: entry.id)
                if !checks.isEmpty {
                    NoteChecksView(findings: checks)
                    Divider()
                }
                if model.findShown, !model.editing {
                    NoteFindBar(count: model.findCount)
                    Divider()
                }
                if model.ask.isOpen {
                    VSplitView {
                        noteText(checks)
                            .frame(minHeight: 120, maxHeight: .infinity)
                        KnowledgeAskPanel()
                    }
                } else {
                    noteText(checks)
                }
            } else {
                ContentUnavailableView("No note open", systemImage: "doc.text",
                                       description: Text("Pick a note in the list, or New Note… to write one."))
            }
        }
        .onChange(of: model.note, initial: true) {
            draft = model.text
            model.findCurrent = 0
        }
        .confirmationDialog("Move the note \(model.deleteRequest ?? "") to the Trash?",
                            isPresented: Binding(get: { model.deleteRequest != nil }, set: { if !$0 { model.deleteRequest = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let id = model.deleteRequest { Task { await model.delete(note: id) } }
            }
        } message: {
            Text("The file goes to the Trash, and its removal is committed in the base's git. Links to it from other notes stay as they are.")
        }
        .sheet(isPresented: Binding(get: { model.obsidianSetup != nil }, set: { if !$0 { model.obsidianSetup = nil } })) {
            if let folder = model.obsidianSetup { ObsidianSetupSheet(folder: folder) }
        }
        .alert("Changed on disk", isPresented: Binding(get: { model.noteConflict != nil }, set: { _ in })) {
            Button("Reload") { model.reloadConflictedNote() }
            Button("Keep Mine") { model.keepMineInNoteConflict() }
        } message: {
            Text("The note \(model.noteConflict ?? "") changed on disk while you edit it, in another app like Obsidian or by git. Reload shows the version on disk. Keep Mine saves your text and backs up the one on disk in ~/.akit/backups.")
        }
    }

    @ViewBuilder private func noteText(_ checks: [KnowledgeLint.Finding]) -> some View {
        if model.editing {
            TextEditor(text: $draft, selection: $selection)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .onChange(of: draft) { _, text in model.save(text) }
                .onChange(of: model.text) { _, text in if text != draft { draft = text } }
        } else {
            NoteReadView(text: model.text, section: model.sectionTarget, grey: Set(checks.compactMap(\.link)),
                         askAbout: { model.showAsk(passage: $0) }, marks: findMarks) { model.follow(link: $0) }
        }
    }

    /// What the read view marks while the Find bar is open.
    private var findMarks: TextMarks? {
        guard model.findShown, !model.findText.allSatisfy(\.isWhitespace) else { return nil }
        let count = model.findCount
        return TextMarks(query: model.findText, current: count == 0 ? nil : min(model.findCurrent, count - 1))
    }

    @ViewBuilder private var copyButtons: some View {
        Button("Copy", systemImage: "doc.on.doc") { model.copy() }
            .help("Copy the note's whole text")
        Button("Paste", systemImage: "doc.on.clipboard") { model.paste() }
            .help("Add the clipboard's text at the end of the note and save it")
    }

    @ViewBuilder private func otherButtons(_ entry: KnowledgeBase.NoteEntry) -> some View {
        Button("Open in Obsidian", systemImage: "arrow.up.forward.app") { model.openInObsidian() }
            .help("Open the note in Obsidian: the base is a plain Obsidian vault")
        Button("Export PDF…", systemImage: "arrow.down.doc") { model.exportPDF() }
            .help("Save the note as a PDF file, drawn as you read it, in A4 pages")
        Button("Rename…", systemImage: "character.cursor.ibeam") { model.renameRequest = entry.id }
            .help("Rename the note and every link to it in notes and maps, all or nothing, in one commit")
        Button("Delete…", systemImage: "trash") { model.deleteRequest = entry.id }
            .help("Move the note to the Trash and commit its removal")
    }

    private func moreMenu(_ help: String, @ViewBuilder _ items: () -> some View) -> some View {
        Menu("More", systemImage: "ellipsis.circle", content: items)
            .labelStyle(.iconOnly)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(help)
    }

    /// The text selected in Edit, when there is some.
    private var selectedText: String? {
        guard model.editing, let selection, case .selection(let range) = selection.indices, !range.isEmpty,
              range.upperBound <= draft.endIndex else { return nil }
        let text = String(draft[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
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
            Text(entry.title).font(.headline).lineLimit(1)
                .help(entry.path)
                .layoutPriority(2)
            Spacer(minLength: 4)
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Button("Find in Note", systemImage: "magnifyingglass") { model.showFind() }
                .labelStyle(.iconOnly)
                .keyboardShortcut("f")
                .fixedSize()
                .help("Find text in this note (⌘F): every match is marked; Return or ⌘G goes to the next, ⇧⌘G to the one before. In Edit it shows the note to read first")
            Toggle("Edit", systemImage: "pencil", isOn: $model.editing)
                .toggleStyle(.button)
                .fixedSize()
                .help("Edit the note's Markdown. Every change is saved to the file at once and committed when you close the tab, after 5 minutes without edits, or when AKit quits")
            Toggle("Properties", systemImage: "list.bullet.rectangle", isOn: $model.showingProperties)
                .toggleStyle(.button)
                .fixedSize()
                .help("Change the note's kind and fields (its frontmatter), one line each; saved at once, committed with your other edits")
            Button("History", systemImage: "clock.arrow.circlepath") { model.historyRequest = entry.id }
                .fixedSize()
                .help("Every version of the note from the base's git, with what changed; restore any of them")
            Button("Ask Pi", systemImage: "bubble.left.and.text.bubble.right") {
                if model.ask.isOpen, selectedText == nil { model.ask.isOpen = false } else { model.showAsk(passage: selectedText) }
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .fixedSize()
            .help("Ask your own Pi about this note in a chat under it (⌥⌘A); in Edit, about the selected text. Right-click a section to ask about it")
            // The rest as wide as there is room for: titled, else Copy and Paste as icons and the
            // others in a menu, else all in the menu. Labels are never cut.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    copyButtons
                    otherButtons(entry)
                }
                HStack(spacing: 8) {
                    copyButtons.labelStyle(.iconOnly)
                    moreMenu("More: Export PDF…, Open in Obsidian, Rename…, Delete…") { otherButtons(entry) }
                }
                moreMenu("More: Copy, Paste, Export PDF…, Open in Obsidian, Rename…, Delete…") {
                    copyButtons
                    otherButtons(entry)
                }
            }
            .layoutPriority(1)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(8)
    }
}

/// Find in Note (⌘F) over the note's read view: the text to find (case and accents ignored), which
/// match is in view of how many, Previous (⇧⌘G, ⇧Return) and Next (⌘G, Return), Done (Esc). Every
/// match is marked, the current one brighter and scrolled into view.
struct NoteFindBar: View {
    @Environment(KnowledgeModel.self) private var model
    let count: Int
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            TextField("Find in Note", text: $model.findText, prompt: Text("Find in note"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($focused)
                .onSubmit { model.findStep(1, count: count) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    model.findStep(-1, count: count)
                    return .handled
                }
                .onKeyPress(.escape) {
                    model.findShown = false
                    return .handled
                }
            Text(status)
                .foregroundStyle(count == 0 && !model.findText.isEmpty ? .orange : .secondary)
                .monospacedDigit()
                .lineLimit(1)
            Button("Previous Match", systemImage: "chevron.up") { model.findStep(-1, count: count) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(count == 0)
                .help("The match before (⇧⌘G)")
            Button("Next Match", systemImage: "chevron.down") { model.findStep(1, count: count) }
                .keyboardShortcut("g")
                .disabled(count == 0)
                .help("The next match (⌘G)")
            Spacer(minLength: 4)
            Button("Done") { model.findShown = false }
                .help("Close Find; the marks go (Esc)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .onChange(of: model.findFocus, initial: true) { focused = true }
    }

    private var status: String {
        if model.findText.isEmpty { return "" }
        if count == 0 { return "No matches" }
        return "\(min(model.findCurrent, count - 1) + 1) of \(count)"
    }
}

/// The line under a panel's buttons (K40): the file's path, then changed, created, the number
/// of versions, edits not committed yet and a note's words, from the base's git; the last
/// commit's message on hover. Long lines wrap rather than cut.
struct HistoryLine: View {
    @Environment(KnowledgeModel.self) private var model
    let id: String
    let path: String
    var words: Int?

    var body: some View {
        let history = model.histories[id]
        Text(([path] + [history.map(KnowledgeModel.summary(of:)), words.map { $0 == 1 ? "1 word" : "\($0) words" }].compactMap(\.self))
            .joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .help(history?.versions.first.map { "Last commit: \($0.message) (\($0.short)). History shows every version" } ?? path)
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
                let problem = taskProblems.first { $0.hasPrefix(property.key + ":") }
                GridRow {
                    Text(property.key).foregroundStyle(problem == nil ? Color.secondary : Color.red)
                        .help(problem ?? (property.isField ? "A field of the kind \(entry.kind ?? "")" : "Not a field of the kind; kept as it is"))
                    PropertyField(key: property.key, value: property.value)
                }
            }
            // A task note (K44): what the board needs and the note lacks, in red.
            ForEach(taskProblems, id: \.self) { problem in
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
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

    /// The fields a task note lacks for the board; empty for other notes.
    private var taskProblems: [String] {
        entry.kind == KnowledgeTask.kind ? KnowledgeTask.problems(KnowledgeNote(text: model.text)) : []
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

/// A note as Obsidian shows it: its frontmatter as a small table, then the Markdown drawn —
/// headings, lists, tables, quotes and callouts, code, Mermaid diagrams. `[[links]]` open the note
/// or map they point to (`follow`). The links and paths lint flags (`grey`: broken or ambiguous
/// links, unknown repos, missing files) are grey.
struct NoteReadView: View {
    let text: String
    /// A heading to scroll to (a search hit's section).
    var section: String?
    var grey: Set<String> = []
    /// Ask Pi About This Section: the section's Markdown. nil: no menu.
    var askAbout: ((String) -> Void)?
    /// Find in the note: the matches to mark, `current` counted over the whole note (its
    /// properties first, then its text).
    var marks: TextMarks?
    /// A clicked `[[link]]` or `akit:` link, as written.
    var follow: (String) -> Void = { _ in }

    var body: some View {
        let note = KnowledgeNote(text: text)
        let front = note.frontmatter.sorted { $0.key < $1.key }.map { ($0.key, Self.describe($0.value)) }
        let chunks = Self.chunks(note)
        // Where each value's and each section's matches start in the whole note's count.
        let starts = marks.map { Self.starts(front: front.map(\.1), chunks: chunks, grey: grey, query: $0.query) }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !front.isEmpty {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                            ForEach(Array(front.enumerated()), id: \.offset) { index, item in
                                GridRow {
                                    Text(item.0).foregroundStyle(.secondary)
                                    let shown = item.1
                                    let marks = marks?.shifted(by: starts?.front[index] ?? 0)
                                    Text(Self.marked(shown, marks)).textSelection(.enabled)
                                        .foregroundStyle(grey.contains { shown.contains($0) } ? .secondary : .primary)
                                        .overlay(alignment: .topLeading) {
                                            if let current = marks?.current, current >= 0, current < TextFind.ranges(of: marks?.query ?? "", in: shown).count {
                                                Color.clear.frame(width: 1, height: 1).id(TextMarks.currentID)
                                            }
                                        }
                                }
                            }
                        }
                        .font(.callout)
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                    // One block per `##` section, so a right-click can ask about that section (K30).
                    ForEach(Array(chunks.enumerated()), id: \.offset) { index, chunk in
                        NoteChunkView(text: chunk, grey: grey, marks: marks?.shifted(by: starts?.chunks[index] ?? 0), askAbout: askAbout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .environment(\.openURL, OpenURLAction { url in
                guard let link = Self.link(url) else { return .systemAction }
                follow(link)
                return .handled
            })
            // The note's text is in the key too: the same heading in another note scrolls again.
            .onChange(of: section.map { [$0, text] }, initial: true) {
                guard let section else { return }
                Task { @MainActor in proxy.scrollTo(Self.anchor(section), anchor: .top) }
            }
            // Find: the block of the current match comes into view.
            .onChange(of: marks) {
                guard marks?.current != nil else { return }
                Task { @MainActor in proxy.scrollTo(TextMarks.currentID, anchor: .center) }
            }
        }
    }

    /// How many matches of `query` Find counts in the note: in its properties' values, then in its
    /// text as drawn.
    static func matches(of query: String, in text: String, grey: Set<String>) -> Int {
        let note = KnowledgeNote(text: text)
        let front = note.frontmatter.map { describe($0.value) }
        let starts = starts(front: front, chunks: chunks(note), grey: grey, query: query)
        return starts.total
    }

    /// The count of matches before each property value and each section, and in all.
    private static func starts(front: [String], chunks: [String], grey: Set<String>, query: String)
        -> (front: [Int], chunks: [Int], total: Int) {
        var total = 0
        let front = front.map { value in
            defer { total += TextFind.ranges(of: query, in: value).count }
            return total
        }
        let chunks = chunks.map { chunk in
            defer { total += NoteChunkView.text(chunk, grey: grey).matches(of: query) }
            return total
        }
        return (front, chunks, total)
    }

    private static func marked(_ text: String, _ marks: TextMarks?) -> AttributedString {
        var attributed = AttributedString(text)
        marks?.mark(&attributed)
        return attributed
    }

    /// The note's body cut at its section headings: the text before the first, then each section
    /// with its heading. Empty parts are left out.
    static func chunks(_ note: KnowledgeNote) -> [String] {
        let body = note.body
        let starts = note.sections.map(\.headingRange.lowerBound).filter { $0 > body.startIndex && $0 < body.endIndex }
        let bounds = [body.startIndex] + starts + [body.endIndex]
        return zip(bounds, bounds.dropFirst()).map { String(note.text[$0..<$1]) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The scroll id of a heading's line.
    static func anchor(_ heading: String) -> String { "heading:" + heading }

    static func describe(_ value: Any) -> String {
        if let list = value as? [Any] { return list.map { "\($0)" }.joined(separator: ", ") }
        return "\(value)"
    }

    /// The link a clicked URL stands for: a `[[link]]` (`akit-link:`) or an `akit:` link; nil for
    /// the web.
    static func link(_ url: URL) -> String? {
        switch url.scheme?.lowercased() {
        case "akit-link": return url.absoluteString.dropFirst("akit-link:".count).removingPercentEncoding.map { "[[\($0)]]" }
        // `akit://meetings/open?…` is an app link (AppLink), not a note: the system hands it to AKit.
        case "akit" where url.host(percentEncoded: false) != nil: return nil
        case "akit": return url.absoluteString.removingPercentEncoding ?? url.absoluteString
        default: return nil
        }
    }

    /// A note's inline Markdown: `[[target#Heading|alias]]` becomes a link showing the alias (or
    /// the target), grey and dead when lint flags it; `![[embed]]` and `[[image.png]]` show their name. Bold, italics,
    /// code and web links as `MarkdownText.inline`. Inside `code` nothing changes.
    static func inline(_ text: String, grey: Set<String> = []) -> AttributedString {
        // A table cell loses the `\|` of `[[note\|alias]]`; lint keeps it.
        let dead = Set(grey.map { $0.replacingOccurrences(of: "\\|", with: "|") })
        let parts = text.split(separator: "`", omittingEmptySubsequences: false)
        let marked = parts.enumerated().map { index, part -> String in
            if index % 2 == 1 { return String(part) }
            return String(part).replacing(/!?\[\[([^\[\]\n]+)\]\]/) { match in
                let inner = String(match.output.1)
                // An embed or an attachment (`[[image.png]]`) is no note: its name, not a link.
                let plain = match.output.0.hasPrefix("!") || KnowledgeLint.isAttachment("[[\(inner)]]")
                let scheme = plain ? "akit-plain:"
                    : dead.contains("[[\(inner.replacingOccurrences(of: "\\|", with: "|"))]]") ? "akit-grey:" : "akit-link:"
                let target = inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                return "[\(escaped(shown(inner)))](\(scheme)\(target))"
            }
        }.joined(separator: "`")
        guard var attributed = try? AttributedString(markdown: marked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(text) }
        for run in attributed.runs {
            if let link = run.link {
                switch link.scheme?.lowercased() ?? "" {
                case "http", "https", "akit-link": break
                case "akit" where !grey.contains(link.absoluteString.removingPercentEncoding ?? link.absoluteString): break
                case "akit-plain": attributed[run.range].link = nil
                case "akit", "akit-grey":
                    attributed[run.range].link = nil
                    attributed[run.range].foregroundColor = .secondary
                default: attributed[run.range].link = nil
                }
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .system(.body, design: .monospaced)
                attributed[run.range].backgroundColor = Color.secondary.opacity(0.12)
            }
        }
        // Repo and file paths lint flags; never part of a link's text.
        for link in grey where !link.hasPrefix("[[") && !link.hasPrefix("akit:") {
            var start = attributed.startIndex
            while start < attributed.endIndex, let found = attributed[start...].range(of: link) {
                if !attributed[found].runs.contains(where: { $0.link != nil }) { attributed[found].foregroundColor = .secondary }
                start = found.upperBound
            }
        }
        return attributed
    }

    /// What a `[[link]]` shows: its alias, else the target without `.md`, a heading after `›`.
    static func shown(_ inner: String) -> String {
        let unescaped = inner.replacingOccurrences(of: "\\|", with: "|")
        if let bar = unescaped.firstIndex(of: "|") {
            let alias = unescaped[unescaped.index(after: bar)...].trimmingCharacters(in: .whitespaces)
            if !alias.isEmpty { return alias }
        }
        let target = unescaped.split(separator: "|", maxSplits: 1).first.map(String.init) ?? unescaped
        var parts = target.split(separator: "#", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if let first = parts.first, first.lowercased().hasSuffix(".md") { parts[0] = String(first.dropLast(3)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " › ")
    }

    /// Text safe inside `[…]` of a Markdown link.
    static func escaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\[]*_`<>".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}

/// One section of a note in the read view. Selectable text keeps the system's own right-click
/// menu, so Ask Pi About This Section is a button at the section's top right, shown while the
/// pointer is over it (and the menu of the space around the text).
private struct NoteChunkView: View {
    let text: String
    let grey: Set<String>
    var marks: TextMarks?
    let askAbout: ((String) -> Void)?
    @State private var hovering = DebugSnapshot.options?.tab == "knowledge-ask-section"

    /// A section drawn as the read view draws it.
    static func text(_ text: String, grey: Set<String>, marks: TextMarks? = nil) -> MarkdownText {
        MarkdownText(text: text, font: .body, large: true, diagrams: true, headingID: NoteReadView.anchor,
                     inlineText: { NoteReadView.inline($0, grey: grey) }, marks: marks)
    }

    var body: some View {
        Self.text(text, grey: grey, marks: marks)
            .padding(.trailing, askAbout == nil ? 0 : 22)
            .contentShape(Rectangle())
            .onHover { hovering = $0 || DebugSnapshot.options?.tab == "knowledge-ask-section" }
            .overlay(alignment: .topTrailing) {
                if let askAbout, hovering {
                    Button("Ask Pi About This Section", systemImage: "bubble.left.and.text.bubble.right") { ask(askAbout) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Ask Pi about this section: it goes with your next question as the passage")
                }
            }
            .contextMenu {
                if let askAbout { Button("Ask Pi About This Section") { ask(askAbout) } }
            }
    }

    private func ask(_ askAbout: (String) -> Void) { askAbout(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
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
                    Button(KnowledgeModel.mapName(edge.map)) { model.showRelation(map: edge.map) }
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

/// What lint finds in the note (4.1): one grey line per finding, its link or path greyed in the
/// text below. The Lint tab lists the whole base's.
struct NoteChecksView: View {
    let findings: [KnowledgeLint.Finding]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Checks").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(findings, id: \.self) { finding in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    LintIcon(severity: finding.severity)
                    Text(finding.message).foregroundStyle(.secondary).lineLimit(2)
                        .help(finding.fix ?? finding.message)
                }
                .font(.callout)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Open in Obsidian on a base that is in none of Obsidian's vaults: Obsidian opens only files of
/// its vaults, so the base folder is opened as a vault once, in Obsidian. AKit doesn't change
/// Obsidian's list itself; `.obsidian/` stays out of the base's git (`.gitignore`).
struct ObsidianSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let folder: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open the Base in Obsidian").font(.title3.weight(.semibold))
            Text("Obsidian opens only notes inside its vaults, and this base isn't one yet. Make it a vault once, then Open in Obsidian opens its notes.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Open Obsidian.")
                Text("2. In the vault switcher choose Open folder as vault, then Open.")
                Text("3. Pick this folder (Copy Path, then ⇧⌘G in the folder dialog):")
                Text(folder.tildePath)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.leading, 16)
                Text("4. Back in AKit, press Open in Obsidian again.")
            }
            Text("Obsidian keeps its settings in .obsidian/ inside the folder; the base's .gitignore keeps it out of the base's commits.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy Path", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(folder.path, forType: .string)
                }
                .help("Copy the base folder's path, to paste into Obsidian's folder dialog")
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    .help("Show the base folder in Finder")
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open Obsidian") {
                    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") {
                        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .help("Start Obsidian, where you open this folder as a vault")
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
