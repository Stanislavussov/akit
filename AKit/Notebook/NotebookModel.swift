import AKitFoundation
import AKitKnowledge
import AppKit
import Observation

/// The Notebook screen (docs/design/notebook.md): the tabs of the knowledge base's `notebook/`
/// folder and the one in the editor. The base is the Knowledge screen's (`KnowledgeModel.base`).
/// Saving is as for maps (NB4): opening never writes; the editor posts its Markdown 800 ms after
/// the last change, written when the file on disk is still the one AKit read or last wrote, else
/// Changed on disk asks Reload / Keep Mine. Saves wait in the base's commit queue (U2); tab
/// changes are committed at once.
@MainActor
@Observable
final class NotebookModel {
    /// A save found the tab changed on disk: Reload or Keep Mine. `text` is the editor's latest.
    struct Conflict: Equatable {
        var key: String
        var text: String
    }

    let knowledge: KnowledgeModel

    /// The tabs on screen: the notebook's, or `Inbox` alone before its first save.
    private(set) var tabs: [String] = []
    /// The tab in the editor.
    private(set) var tab: String?
    /// What the editor shows. Its key is the base's folder and the tab (`key(tab:)`), so a save
    /// that arrives after a base switch still goes to its own base.
    private(set) var document = NotebookEditorView.Document(key: "", text: "")
    var conflict: Conflict?
    var notice: String?
    var problem: String?
    /// New Tab… and Rename… waiting in their sheet; Delete… waiting for its confirmation.
    var newTabRequest = DebugSnapshot.options?.tab == "notebook-new"
    var renameRequest: String?
    var deleteRequest: String?
    /// A drawing open in Excalidraw (NB10), until Done or Cancel.
    struct DrawingRequest: Identifiable, Equatable {
        var name: String
        var text: String
        /// The scene's hash as read; nil for a new drawing.
        var hash: String?
        var id: String { name }
    }
    var drawingRequest: DrawingRequest?

    /// Per document key: the hash of the tab's bytes as AKit last read or wrote them (the own-write
    /// rule). No entry: the tab's file doesn't exist yet (the first tab before its first save).
    private var hashes: [String: String] = [:]
    /// The images AKit saved, by base-relative path (the own-write rule).
    private var assetHashes: [String: String] = [:]
    private var shownBase: URL?

    private(set) static weak var current: NotebookModel?

    init(knowledge: KnowledgeModel) {
        self.knowledge = knowledge
        Self.current = self
    }

    var notebook: KnowledgeNotebook? { knowledge.base.map(KnowledgeNotebook.init) }

    var env: HarnessEnvironment { HarnessEnvironment.current }

    func key(tab: String, in notebook: KnowledgeNotebook) -> String { notebook.base.root.path + "\n" + tab }

    /// The notebook and tab of a document key; nil when it names no base of this Mac any more.
    func split(_ key: String) -> (notebook: KnowledgeNotebook, tab: String)? {
        let parts = key.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        if let notebook, notebook.base.root.path == parts[0] { return (notebook, parts[1]) }
        guard let base = knowledge.bases.first(where: { $0.root.path == parts[0] }) else { return nil }
        return (KnowledgeNotebook(base: base), parts[1])
    }

    // MARK: - Loading

    /// The screen appears: the bases are read (once), then the tabs.
    func load() async {
        await knowledge.loadIfNeeded()
        refresh()
        // Snapshots: `--select <tab>` shows that tab; `--tab notebook-rename` / `notebook-delete` asks for it.
        if let select = DebugSnapshot.options?.select, tabs.contains(select) { open(select) }
        switch DebugSnapshot.options?.tab {
        case "notebook-rename": renameRequest = tab
        case "notebook-delete": deleteRequest = tab
        default: break
        }
    }

    /// The tabs again; a new base shows its first tab. The tab in view stays when it still exists.
    func refresh() {
        guard let notebook else {
            (tabs, tab, shownBase) = ([], nil, nil)
            document = NotebookEditorView.Document(key: "", text: "", generation: document.generation + 1)
            return
        }
        let found = notebook.tabs()
        tabs = found.isEmpty ? [KnowledgeNotebook.firstTab] : found
        if shownBase != notebook.base.root {
            shownBase = notebook.base.root
            tab = nil
        }
        if let tab, tabs.contains(tab) { return }
        if let first = tabs.first { open(first) }
    }

    /// Shows a tab: its file's text goes to the editor, and its hash becomes the one a save expects.
    func open(_ tab: String) {
        guard let notebook else { return }
        let key = key(tab: tab, in: notebook)
        let text: String
        do { text = try notebook.text(tab) } catch {
            problem = error.message
            return
        }
        if let hash = KnowledgeWrite.hash(of: notebook.file(tab)) { hashes[key] = hash } else { hashes[key] = nil }
        self.tab = tab
        document = NotebookEditorView.Document(key: key, text: text, generation: document.generation + 1)
    }

    // MARK: - Saving

    /// A `save` from the editor: written as it is when the file on disk is still the one AKit read
    /// or last wrote; else the conflict waits for Reload / Keep Mine.
    func save(_ key: String, text: String) {
        guard let (notebook, tab) = split(key) else {
            problem = "The notebook of that tab is gone, so AKit didn't save it."
            return
        }
        if conflict?.key == key {
            conflict?.text = text
            return
        }
        // A late save of a tab deleted or renamed since: dropped, the tab stays gone.
        if hashes[key] == nil, !FileWalk.isRegularFile(notebook.file(tab)),
           !(tab == KnowledgeNotebook.firstTab && notebook.tabs().isEmpty) {
            return
        }
        do {
            let (path, outcome) = try notebook.save(tab, bytes: Data(text.utf8), expectedHash: hashes[key])
            switch outcome {
            case .saved(let hash):
                hashes[key] = hash
                knowledge.enqueueEdit(path, in: notebook.base)
                if tabs == [KnowledgeNotebook.firstTab], notebook.base == knowledge.base { tabs = notebook.tabs() }
            case .conflict:
                conflict = Conflict(key: key, text: text)
            }
        } catch {
            problem = error.message
        }
    }

    /// Before a tab change, a base switch and a quit: the editor hands over a change still waiting
    /// for its 800 ms post, and it is saved now. false when the page didn't answer or the save
    /// didn't go through.
    @discardableResult
    func forcePostDirty() async -> Bool {
        guard let editor = NotebookEditorView.Coordinator.current else { return true }
        let unsaved: (key: String, text: String)?
        do { unsaved = try await editor.takeUnsaved() } catch { return false }
        guard let unsaved else { return conflict == nil }
        let problemBefore = problem
        save(unsaved.key, text: unsaved.text)
        await knowledge.lastEnqueueDone()
        return conflict == nil && problem == problemBefore
    }

    /// Changed on disk → Reload: the disk version replaces the editor's text.
    func reloadConflict() {
        guard let conflict else { return }
        self.conflict = nil
        if let (_, tab) = split(conflict.key), tab == self.tab { open(tab) }
        notice = "Reloaded the tab from disk."
    }

    /// Changed on disk → Keep Mine: the disk version is backed up in ~/.akit/backups, then the
    /// editor's text is saved over it.
    func keepMine() {
        guard let conflict, let (notebook, tab) = split(conflict.key) else { return }
        let file = notebook.file(tab)
        self.conflict = nil
        if let disk = try? Data(contentsOf: file) {
            do {
                let backup = try Backup.save(disk, as: file, home: env.homeDirectory)
                hashes[conflict.key] = KnowledgeWrite.hash(disk)
                notice = "Kept your version; the disk copy is in \(backup.tildePath)."
            } catch {
                problem = "Couldn't back up \(file.path): \(error.localizedDescription)"
                return
            }
        } else {
            hashes[conflict.key] = nil
        }
        save(conflict.key, text: conflict.text)
    }

    /// The watcher's batch (`KnowledgeModel.changed`): the tabs again, and the tab in view, when
    /// someone else changed it, shows that version (no change waiting) or asks Reload / Keep Mine.
    func changedOnDisk(_ outside: [String]) {
        guard let notebook, let tab else { return }
        let found = notebook.tabs()
        tabs = found.isEmpty ? [KnowledgeNotebook.firstTab] : found
        guard tabs.contains(tab) else {
            if let first = tabs.first { open(first) }
            notice = "The tab \(tab) is gone from disk."
            return
        }
        guard outside.contains(notebook.path(tab)), FileWalk.isRegularFile(notebook.file(tab)) else { return }
        let key = key(tab: tab, in: notebook)
        guard KnowledgeWrite.hash(of: notebook.file(tab)) != hashes[key] else { return }
        Task {
            let unsaved: (key: String, text: String)?
            do { unsaved = try await NotebookEditorView.Coordinator.current?.takeUnsaved() } catch {
                // The page didn't answer: its text may hold an edit, so it is not replaced.
                notice = "\(tab) changed on disk; switch tabs to see that version."
                return
            }
            if let unsaved, unsaved.key == key {
                conflict = Conflict(key: key, text: unsaved.text)
                return
            }
            if let unsaved { save(unsaved.key, text: unsaved.text) }
            if conflict == nil, self.tab == tab {
                open(tab)
                notice = "\(tab) changed on disk; showing that version."
            }
        }
    }

    /// What AKit wrote itself, by base-relative path, for the watcher.
    var ownHashes: [String: String] {
        var own = assetHashes
        for (key, hash) in hashes {
            if let (notebook, tab) = split(key), notebook.base == knowledge.base { own[notebook.path(tab)] = hash }
        }
        return own
    }

    // MARK: - Tabs

    func show(_ tab: String) {
        guard tab != self.tab else { return }
        Task {
            guard await forcePostDirty() else {
                problem = "The tab's last change couldn't be saved, so AKit stayed on it."
                return
            }
            open(tab)
        }
    }

    /// The last change is saved before a tab change; false (and a problem) when it couldn't be.
    private func savedFirst() async -> Bool {
        if await forcePostDirty() { return true }
        problem = "Save the open tab first: its last change couldn't be saved, so nothing was changed."
        return false
    }

    /// New Tab…: committed at once; the new tab opens.
    func addTab(_ name: String) async -> Bool {
        guard let notebook, await savedFirst() else { return false }
        do {
            // The first tab before its first save is written now, so it keeps its place.
            if notebook.tabs().isEmpty, (try? KnowledgeNotebook.checkedName(name)) != KnowledgeNotebook.firstTab {
                try await notebook.add(tab: KnowledgeNotebook.firstTab, env: env)
            }
            let added = try await notebook.add(tab: name, env: env)
            refresh()
            open(added)
            notice = "Added the tab \(added)."
            return true
        } catch {
            problem = error.message
            return false
        }
    }

    /// Rename…: one commit; the tab keeps its place.
    func rename(_ tab: String, to new: String) async -> Bool {
        guard let notebook, await savedFirst() else { return false }
        do {
            let renamed = try await notebook.rename(tab: tab, to: new, env: env)
            hashes[key(tab: tab, in: notebook)] = nil
            refresh()
            open(renamed)
            notice = "Renamed \(tab) to \(renamed)."
            return true
        } catch {
            problem = error.message
            return false
        }
    }

    /// Delete…: the tab's file goes to the Trash; one commit.
    func delete(_ tab: String) async {
        guard let notebook, await savedFirst() else { return }
        do {
            try await notebook.delete(tab: tab, env: env)
            hashes[key(tab: tab, in: notebook)] = nil
            if self.tab == tab { self.tab = nil }
            refresh()
            notice = "Moved \(tab) to the Trash."
        } catch {
            problem = error.message
        }
    }

    /// A tab dragged onto another: it takes that tab's place. Committed at once.
    func move(_ tab: String, to target: String) async {
        guard let notebook, tab != target, let from = tabs.firstIndex(of: tab), let to = tabs.firstIndex(of: target) else { return }
        var order = tabs
        order.remove(at: from)
        order.insert(tab, at: to)
        tabs = order
        do { try await notebook.reorder(order, env: env) } catch { problem = error.message }
        refresh()
    }

    // MARK: - Editing

    /// Today (NB7): today's heading at the top of the tab in view, the cursor under it.
    func today() async {
        guard let editor = NotebookEditorView.Coordinator.current else { return }
        // Snapshots: `--tab notebook-today --query 2026-10-25` presses Today on that day.
        let day = (DebugSnapshot.options?.tab == "notebook-today" ? DebugSnapshot.options?.query : nil) ?? Self.dayFormatter.string(from: .now)
        do { try await editor.today(day) } catch {
            problem = "Today: \(error.localizedDescription)"
        }
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// A pasted or dropped image (NB5): saved in `notebook/assets/`, queued for the commit; its link.
    func upload(_ data: Data, ext: String) throws -> String {
        guard let notebook else { throw KnowledgeBase.Failure(message: "No knowledge base.") }
        let date = Self.dayFormatter.string(from: .now)
        let saved = try notebook.saveAsset(data, ext: ext, date: date)
        assetHashes[saved.path] = KnowledgeWrite.hash(data)
        knowledge.enqueueEdit(saved.path, in: notebook.base)
        return saved.link
    }

    // MARK: - Drawings (NB10)

    /// Draw…: an empty Excalidraw canvas for a new drawing; Done puts its picture at the cursor.
    func newDrawing() {
        guard let notebook else { return }
        drawingRequest = DrawingRequest(name: notebook.newDrawingName(date: Self.dayFormatter.string(from: .now)), text: NewMap.scene(), hash: nil)
    }

    /// A double click on a drawing's picture: the drawing opens in Excalidraw.
    func openDrawing(_ link: String) {
        guard let notebook, let name = KnowledgeNotebook.drawing(ofLink: link) else { return }
        let read = notebook.drawing(name)
        guard read.hash != nil else {
            notice = "The drawing \(name) is gone: notebook/drawings/\(name).excalidraw doesn't exist."
            return
        }
        drawingRequest = DrawingRequest(name: name, text: read.text, hash: read.hash)
    }

    /// Done: the scene and its picture are saved and queued for the commit; a new drawing's picture
    /// goes into the tab, an old one's pictures load again. false keeps the sheet open.
    func saveDrawing(scene: String, svg: String) async -> Bool {
        guard let notebook, let request = drawingRequest else { return false }
        do {
            let saved = try notebook.saveDrawing(request.name, scene: Data(scene.utf8), svg: Data(svg.utf8), expectedHash: request.hash)
            guard case .saved(let hash) = saved.outcome else {
                problem = "The drawing \(request.name) changed on disk while it was open; nothing was saved. Cancel and open it again."
                return false
            }
            assetHashes[saved.paths[0]] = hash
            assetHashes[saved.paths[1]] = KnowledgeWrite.hash(Data(svg.utf8))
            for path in saved.paths { knowledge.enqueueEdit(path, in: notebook.base) }
            drawingRequest = nil
            if request.hash == nil {
                await NotebookEditorView.Coordinator.current?.insertImage(saved.link)
                notice = "Added the drawing \(request.name)."
            } else {
                await NotebookEditorView.Coordinator.current?.refreshImages(saved.link)
                notice = "Saved the drawing \(request.name)."
            }
            return true
        } catch {
            problem = error.message
            return false
        }
    }

    /// The file an image link of the tab names (`assets/…`).
    func imageFile(_ link: String) -> URL? { notebook?.asset(link) }

    /// ⌘-click on a link: a web link opens in the default browser, a `[[note]]` on the Knowledge
    /// screen (true: show that screen).
    func openLink(_ link: String) -> Bool {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return false
        }
        return knowledge.openFromNotebook(trimmed)
    }
}
