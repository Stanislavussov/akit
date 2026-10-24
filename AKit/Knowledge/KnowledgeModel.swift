import AKitBrain
import AKitFoundation
import AKitKnowledge
import AppKit
import Observation

/// Knowledge screen state: the bases of this Mac, the chosen one's areas and notes, the open
/// note tabs and the note in view. Every write goes through `AKitKnowledge`. Edits save to the
/// file at once and wait in the base's commit queue (U2), which is flushed when a note tab
/// closes, after 5 minutes without edits, before AKit quits or rebuilds, and at the next launch.
@MainActor @Observable
final class KnowledgeModel {
    /// The model on screen, for the app's quit and rebuild flushes (one main window).
    private(set) static weak var current: KnowledgeModel?

    static let idleFlush: Duration = .seconds(5 * 60)

    private(set) var bases: [KnowledgeBase] = []
    /// The sample base (K26, `.akit-seed.json`) among `bases`, for Remove Sample Base….
    private(set) var sampleBase: KnowledgeBase?
    private(set) var base: KnowledgeBase?
    private(set) var areas: [KnowledgeBase.Area] = []
    var area: String?
    private(set) var notes: [KnowledgeBase.NoteEntry] = []
    /// Open note tabs (ids), in the order they were opened.
    private(set) var tabs: [String] = []
    private(set) var note: String?
    /// The text of the note in view, as on disk after the last save.
    private(set) var text = ""
    var problem: String?
    /// The note panel shows the Markdown to edit (Edit). Snapshots: `--tab edit`.
    var editing = DebugSnapshot.options?.tab == "edit"
    /// The note panel shows the Properties form (kind and fields). Snapshots: `--tab properties`.
    var showingProperties = DebugSnapshot.options?.tab == "properties"
    /// The base's kinds from `kb.yaml` (K24): the defaults without the file, or when it can't be read.
    private(set) var kindsFile = KnowledgeKinds.defaults
    /// Delete…: the note whose move to the Trash waits for confirmation. Snapshots: `--tab delete`.
    var deleteRequest: String?
    /// What the last write did, under the panel's buttons.
    var notice: String?
    private(set) var loaded = false

    /// Saved paths whose enqueue found the lock held: tried again before every flush.
    private var unqueued: Set<String> = []
    private var idleTask: Task<Void, Never>?
    /// The last save's enqueue: a flush waits for it, so an edit is in the flush that follows it.
    private var lastEnqueue: Task<Void, Never>?

    var env: HarnessEnvironment { HarnessEnvironment.current }
    var home: URL { env.homeDirectory }

    init() { Self.current = self }

    var noteEntry: KnowledgeBase.NoteEntry? { note.flatMap { id in allNotes.first { $0.id == id } } }
    private var allNotes: [KnowledgeBase.NoteEntry] = []

    /// The kinds New Note… and Properties offer: the ones in `kb.yaml`, in its order.
    var kinds: [String] { kindsFile.names }

    // MARK: - Loading

    /// Reads the bases; picks `select` (a note id, for snapshots) when given. Flushes what an
    /// earlier run left pending.
    func load(select: String? = nil) async {
        bases = KnowledgeBase.all(home: home)
        sampleBase = bases.first { KnowledgeSeed.marker(of: $0) != nil }
        if !bases.contains(where: { $0 == base }) { base = Self.defaultBase(bases, home: home) }
        // Snapshots: `--tab sample` shows the sample base, `--tab sample-remove` asks Remove Sample Base….
        if DebugSnapshot.options?.tab?.hasPrefix("sample") == true, let sampleBase { base = sampleBase }
        if !loaded {
            loaded = true
            await Self.flushQueues(of: bases, env: env)
        }
        reload()
        if let select, allNotes.contains(where: { $0.id == select }) {
            open(select)
            if DebugSnapshot.options?.tab == "delete" { deleteRequest = select }
        }
    }

    /// The only base, else the one named like this Mac's kind, else the first.
    static func defaultBase(_ bases: [KnowledgeBase], home: URL) -> KnowledgeBase? {
        let kind = MachineProfile.load(home: home).kind.rawValue
        return bases.count == 1 ? bases[0] : bases.first { $0.name == kind } ?? bases.first
    }

    /// Areas and notes of the base again, keeping the selection where it still exists.
    func reload() {
        guard let base else {
            (areas, notes, allNotes, tabs, note, text) = ([], [], [], [], nil, "")
            kindsFile = .defaults
            return
        }
        do { kindsFile = try base.kinds() } catch {
            kindsFile = .defaults
            problem = "\(error.message) The screen uses the default kinds until it is fixed."
        }
        areas = base.areas()
        if let area, !areas.contains(where: { $0.name == area }) { self.area = nil }
        if area == nil { area = areas.first?.name }
        allNotes = (try? base.notes()) ?? []
        notes = allNotes.filter { $0.area == area }
        tabs = tabs.filter { id in allNotes.contains { $0.id == id } }
        if let note, !tabs.contains(note) { self.note = nil }
        if note == nil { note = tabs.last }
        readNote()
    }

    func choose(base: KnowledgeBase) {
        guard base != self.base else { return }
        let old = self.base
        Task { await flush(old) }
        self.base = base
        (area, tabs, note) = (nil, [], nil)
        reload()
    }

    func choose(area: String?) {
        self.area = area
        notes = allNotes.filter { $0.area == area }
    }

    // MARK: - Tabs

    func open(_ id: String) {
        guard let entry = allNotes.first(where: { $0.id == id }) else { return }
        area = entry.area
        notes = allNotes.filter { $0.area == entry.area }
        if !tabs.contains(id) { tabs.append(id) }
        note = id
        readNote()
    }

    func show(tab id: String) {
        guard tabs.contains(id) else { return }
        note = id
        readNote()
    }

    /// Closes a tab and flushes the queue (U2).
    func close(tab id: String) {
        guard let index = tabs.firstIndex(of: id) else { return }
        tabs.remove(at: index)
        if note == id {
            note = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]
            readNote()
        }
        let base = base
        Task { await flush(base) }
    }

    private func readNote() {
        guard let base, let note else {
            text = ""
            return
        }
        text = KnowledgeNote.load(base.noteFile(note))?.text ?? ""
    }

    // MARK: - Writes

    /// Edit: the file is saved at once with exactly this text; the commit waits in the queue.
    func save(_ newText: String) {
        guard let base, let note, newText != text else { return }
        do {
            let path = try base.save(note: note, text: newText)
            text = newText
            enqueue(path, in: base)
            if let index = allNotes.firstIndex(where: { $0.id == note }), let title = KnowledgeNote(text: newText).title,
               title != allNotes[index].title {
                reload()
            }
        } catch {
            problem = error.message
        }
    }

    /// Paste: the clipboard's text is added at the end of the note and saved.
    func paste() {
        guard let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty else {
            notice = "The clipboard has no text."
            return
        }
        let separator = text.isEmpty || text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n"
        save(text + separator + clip + (clip.hasSuffix("\n") ? "" : "\n"))
        notice = "Pasted at the end of the note and saved."
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = "The note's text is copied."
    }

    func openInObsidian() {
        guard let base, let note, let url = Obsidian.openURL(note: base.noteFile(note)) else { return }
        if NSWorkspace.shared.urlForApplication(toOpen: url) == nil {
            problem = "Obsidian isn't installed. The base is a plain folder of Markdown files: \(base.root.tildePath)"
            return
        }
        NSWorkspace.shared.open(url)
    }

    func createBase(world: String) async -> Bool {
        do {
            let created = try await KnowledgeBase.create(world: world.trimmingCharacters(in: .whitespaces), env: env)
            base = created
            await load()
            return true
        } catch {
            problem = error.message
            return false
        }
    }

    // MARK: - Sample base (K26)

    /// Add Sample Base…: `akit kb seed`. Writes (or brings up to date) the base of the world
    /// `sample` and shows it.
    func addSampleBase() async {
        do {
            let outcome = try await KnowledgeSeed.seed(env: env)
            base = outcome.base
            (area, tabs, note) = (nil, [], nil)
            await load()
            notice = switch outcome.status {
            case .created: "Added the sample base \(outcome.base.root.tildePath)."
            case .updated: "Updated the sample base to seed v\(KnowledgeSeed.version)."
            case .unchanged: "The sample base is up to date."
            }
        } catch {
            problem = error.message
        }
    }

    /// Remove Sample Base…: `akit kb seed --remove --yes`. The whole folder goes to the Trash.
    func removeSampleBase() async {
        guard let sample = sampleBase else { return }
        do {
            try KnowledgeSeed.remove(sample, home: home)
            if base == sample { (base, area, tabs, note) = (nil, nil, [], nil) }
            await load()
            notice = "Moved the sample base to the Trash."
        } catch {
            problem = error.message
        }
    }

    func newArea(_ name: String) -> Bool {
        guard let base else { return false }
        do {
            try base.newArea(name)
            reload()
            choose(area: name.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping)
            return true
        } catch {
            problem = error.message
            return false
        }
    }

    func newNote(area: String, name: String, kind: String?) async -> Bool {
        guard let base else { return false }
        do {
            let path = try await base.newNote(area: area, name: name, kind: kind, env: env)
            reload()
            open(String(path.dropFirst("areas/".count).dropLast(".md".count)))
            return true
        } catch {
            problem = error.message
            return false
        }
    }

    // MARK: - Properties, kinds, area settings (K24)

    /// Properties: sets one frontmatter key of the note in view (an empty value removes it), one
    /// line, every other byte kept; the file is saved at once and its commit waits in the queue.
    func setProperty(_ key: String, to value: String) {
        guard let base, let note else { return }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        do {
            let result = trimmed.isEmpty ? try base.setProperties(note: note, set: [], unset: [key])
                : try base.setProperties(note: note, set: [(key, .parse(trimmed))])
            guard result.changed else { return }
            enqueue(result.path, in: base)
            reload()
        } catch {
            problem = error.message
        }
    }

    /// The note in view's properties: the kind's fields first (in `kb.yaml`'s order, empty when
    /// unset), then the other keys, sorted. `kind` itself is not in the list.
    var noteProperties: [(key: String, value: String, isField: Bool)] {
        let values = KnowledgeNote(text: text).properties
        let fields = noteEntry?.kind.flatMap { kindsFile.kind($0) }?.fields ?? []
        let others = values.keys.filter { $0 != "kind" && !fields.contains($0) }.sorted()
        return fields.map { ($0, values[$0]?.display ?? "", true) } + others.map { ($0, values[$0]?.display ?? "", false) }
    }

    /// Kinds… Save: writes `kb.yaml`; its commit waits in the queue like a note edit.
    func save(kinds: KnowledgeKinds) -> Bool {
        guard let base else { return false }
        do {
            let path = try base.save(kinds: kinds)
            enqueue(path, in: base)
            reload()
            notice = "The kinds are saved."
            return true
        } catch {
            problem = error.message
            return false
        }
    }

    /// Kinds… Rename…: `kind:` changes in every note of that kind and in `kb.yaml`, all or
    /// nothing, in one commit made at once (after the pending edits are committed).
    func renameKind(_ old: String, to new: String) async -> Bool {
        guard let base else { return false }
        await lastEnqueue?.value
        do {
            let paths = try await base.renameKind(old, to: new.trimmingCharacters(in: .whitespaces), env: env)
            reload()
            notice = "Renamed \(old) in \(paths.count - 1) note\(paths.count == 2 ? "" : "s"), committed."
            return true
        } catch {
            problem = error.message
            return false
        }
    }

    /// Area Settings…: the area's `area.yaml` (empty settings without one).
    func settings(area: String) -> KnowledgeArea {
        guard let base else { return KnowledgeArea() }
        do { return try base.settings(area: area) } catch {
            problem = error.message
            return KnowledgeArea()
        }
    }

    /// Area Settings… Save: writes `area.yaml`; its commit waits in the queue.
    func save(area: String, settings: KnowledgeArea) -> Bool {
        guard let base else { return false }
        do {
            let path = try base.save(area: area, settings: settings)
            enqueue(path, in: base)
            reload()
            notice = "The settings of \(area) are saved."
            return true
        } catch {
            problem = error.message
            return false
        }
    }

    /// Delete…: the note (or the whole area) goes to the Trash, and its removal is committed.
    func delete(note id: String? = nil, area: String? = nil) async {
        guard let base else { return }
        do {
            try await base.moveToTrash(note: id, area: area, env: env)
            if let id { tabs.removeAll { $0 == id } }
            if let area { tabs.removeAll { $0.hasPrefix(area + "/") } }
            if note.map({ !tabs.contains($0) }) == true { note = nil }
            reload()
            notice = "Moved to the Trash."
        } catch {
            problem = error.message
        }
    }

    // MARK: - Commit queue

    private func enqueue(_ path: String, in base: KnowledgeBase) {
        let queue = KnowledgeCommitQueue(base: base.root, env: env)
        let wanted = unqueued.union([path])
        let previous = lastEnqueue
        lastEnqueue = Task { [weak self] in
            await previous?.value
            let result = await Task.detached { queue.enqueue(Array(wanted)) }.value
            self?.enqueued(wanted, result)
        }
        scheduleIdleFlush()
    }

    private func enqueued(_ paths: Set<String>, _ result: KnowledgeCommitQueue.EnqueueResult) {
        switch result {
        case .queued: unqueued.subtract(paths)
        case .busy: unqueued.formUnion(paths)
        case .failed(let message):
            unqueued.formUnion(paths)
            problem = "The edit is saved, but not queued for its commit: \(message)"
        }
    }

    /// 5 minutes after the last edit, the queue is committed.
    private func scheduleIdleFlush() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleFlush)
            guard !Task.isCancelled, let self else { return }
            await self.flush(self.base)
        }
    }

    /// Commits a base's queue (and first queues what couldn't be queued). A busy lock or a git
    /// failure keeps the paths for the next trigger, without a dialog.
    func flush(_ base: KnowledgeBase?) async {
        guard let base else { return }
        await lastEnqueue?.value
        let queue = KnowledgeCommitQueue(base: base.root, env: env)
        let retry = unqueued
        let result: (KnowledgeCommitQueue.FlushResult, Bool) = await Task.detached {
            if !retry.isEmpty {
                guard case .queued = queue.enqueue(Array(retry)) else { return (.busy, false) }
            }
            return (await queue.flush(), true)
        }.value
        if result.1 { unqueued.subtract(retry) }
        if case .committed(let paths) = result.0 { notice = paths.count == 1 ? "Committed 1 edit." : "Committed \(paths.count) edits." }
    }

    /// Before AKit quits or rebuilds: the model's own pending work, then every base of this Mac.
    static func flushBeforeQuit() async {
        let env = HarnessEnvironment.current
        if let current { await current.flush(current.base) }
        await flushQueues(of: KnowledgeBase.all(home: env.homeDirectory), env: env)
    }

    private static func flushQueues(of bases: [KnowledgeBase], env: HarnessEnvironment) async {
        for base in bases {
            _ = await KnowledgeCommitQueue(base: base.root, env: env).flush()
        }
    }

    /// Runs `work` and returns when it is done or `seconds` have passed, whichever comes first
    /// (the quit and rebuild cap: a hung flush must not keep AKit from quitting; what it didn't
    /// commit stays in `.akit-pending.json`).
    static func within(seconds: Double, _ work: @escaping @MainActor () async -> Void) async {
        final class Once {
            var continuation: CheckedContinuation<Void, Never>?
            func finish() {
                continuation?.resume()
                continuation = nil
            }
        }
        let once = Once()
        await withCheckedContinuation { continuation in
            once.continuation = continuation
            Task { @MainActor in
                await work()
                once.finish()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                once.finish()
            }
        }
    }

    // MARK: - Snapshots

    /// What `make snapshot SECTION=knowledge` prints: the visible state as text, so a check
    /// needs no image.
    var manifest: String {
        var lines = ["knowledge base: \(base?.root.tildePath ?? "none")",
                     "bases: " + bases.map { $0.name + ($0 == sampleBase ? " (sample)" : "") }.joined(separator: ", ")]
        lines.append("areas: " + areas.map { "\($0.name)\($0.name == area ? "*" : "") (\($0.notes))" }.joined(separator: ", "))
        lines.append("notes: " + notes.map(\.id).joined(separator: ", "))
        lines.append("tabs: " + tabs.joined(separator: ", "))
        if let entry = noteEntry {
            lines.append("note: \(entry.title) (\(entry.id)\(entry.kind.map { ", kind \($0)" } ?? "")), \(editing ? "Edit" : "read")")
            let sections = KnowledgeNote(text: text).sections.map(\.heading)
            if !sections.isEmpty { lines.append("sections: " + sections.joined(separator: ", ")) }
            if showingProperties {
                lines.append("properties: kind \(entry.kind ?? "none")"
                    + noteProperties.map { "; \($0.key) \($0.value.isEmpty ? "-" : $0.value)\($0.isField ? "" : " (not a field of the kind)")" }.joined())
            }
        } else {
            lines.append("note: none")
        }
        switch DebugSnapshot.options?.tab {
        case "kinds":
            lines.append("kinds: " + kindsFile.kinds.map { "\($0.name) (\($0.fields.joined(separator: ", ")))" }.joined(separator: ", "))
        case "area-settings":
            if let area {
                let settings = settings(area: area)
                lines.append("area settings: \(area), title \(settings.title ?? "-"), description \(settings.description ?? "-"), projects "
                    + (settings.projects.isEmpty ? "-" : settings.projects.joined(separator: ", ")))
            }
        default: break
        }
        return lines.joined(separator: "\n")
    }
}
