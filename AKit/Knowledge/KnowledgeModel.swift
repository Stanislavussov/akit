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
    /// The maps (`.excalidraw` ids, `payments/maps/overview`) of the chosen area.
    private(set) var maps: [String] = []
    /// The map in view; nil shows the note panel alone.
    private(set) var map: String?
    /// Open map tabs (ids), in the order they were opened. The tab bar shows those of the area
    /// of the map in view.
    private(set) var mapTabs: [String] = []
    /// The map in view has nothing on it: the canvas says how to start instead of staying blank.
    private(set) var mapIsEmpty = false
    /// The arrows to and from the note in view on every map (`MapGraph.relations(of:)`).
    private(set) var noteRelations: [MapGraph.Edge] = []
    /// What the canvas shows: the map's `.excalidraw` text as on disk when it was opened (or
    /// reloaded). AKit's own saves don't change it: the canvas has those edits already.
    private(set) var mapScene = MapCanvasView.Scene(key: "", text: "")
    /// The map can be edited (Edit); off is view mode, where a click on a block opens its note.
    /// Snapshots: `--tab map-edit` (and the map-add, map-add-quit, map-conflict checks).
    var mapEditing = DebugSnapshot.options?.tab.map { ["map-edit", "map-add", "map-add-quit", "map-conflict"].contains($0) } ?? false
    /// Per map opened in this run: the hash of its bytes as AKit read or last wrote them. A save
    /// writes only while the disk still has those bytes (`KnowledgeWrite.saveChecked`).
    private var mapHashes: [String: String] = [:]
    /// A save found the map changed on disk: Reload or Keep Mine. `bytes` is the latest unsaved
    /// serialization, which Keep Mine writes.
    struct MapConflict: Equatable {
        var id: String
        var bytes: Data
    }
    var mapConflict: MapConflict?
    /// Delete… of a map waiting for its confirmation. Snapshots: `--tab map-delete`.
    var mapDeleteRequest: String?
    /// A note opened from the map (a click on its block) shows beside the map.
    private(set) var noteBesideMap = false
    /// Open note tabs (ids), in the order they were opened.
    private(set) var tabs: [String] = []
    private(set) var note: String?
    /// The text of the note in view, as on disk after the last save.
    private(set) var text = ""
    var problem: String?
    /// Open in Obsidian found the base in none of Obsidian's vaults: the base folder, for the
    /// sheet that says how to open it as a vault once.
    var obsidianSetup: URL?
    /// The note panel shows the Markdown to edit (Edit). Snapshots: `--tab edit` (and `watch-edit`).
    var editing = ["edit", "watch-edit"].contains(DebugSnapshot.options?.tab)
    /// The note panel shows the Properties form (kind and fields). Snapshots: `--tab properties`.
    var showingProperties = DebugSnapshot.options?.tab == "properties"
    /// The base's kinds from `kb.yaml` (K24): the defaults without the file, or when it can't be read.
    private(set) var kindsFile = KnowledgeKinds.defaults
    /// Delete…: the note whose move to the Trash waits for confirmation. Snapshots: `--tab delete`.
    var deleteRequest: String?
    /// What the last write did, under the panel's buttons.
    var notice: String?
    private(set) var loaded = false
    /// The screen's tabs: Notes (spaces, notes, maps), Inbox (agents' proposals, 5.3), Lint (4.1).
    enum ScreenTab: String { case notes = "Notes", inbox = "Inbox", lint = "Lint" }
    /// Snapshots: `--tab lint`, `--tab inbox` (and inbox-accept, inbox-reject, inbox-arrow).
    var screenTab: ScreenTab = DebugSnapshot.options?.tab == "lint" ? .lint
        : DebugSnapshot.options?.tab?.hasPrefix("inbox") == true ? .inbox : .notes
    /// The base's lint findings (`akit kb lint`), read again with the base: the Lint tab lists
    /// them, and the note panel greys the links and paths they are about.
    private(set) var lintFindings: [KnowledgeLint.Finding] = []
    /// Where lint finds the known projects and their local copies: the app's projects folder
    /// and brain (set by the screen), `~/Projects` and `~/.akit/registry` until then.
    var projectsRoot: URL?
    var brainRoot: URL?
    /// The known projects, found once per load (Check Again finds them again).
    private var lintProjects: KnowledgeLint.Projects?
    /// Create Note… of a broken link: New Note… filled in with its area and name.
    struct NewNoteRequest: Identifiable {
        let area: String
        let name: String
        var id: String { "\(area)/\(name)" }
    }
    var newNoteRequest: NewNoteRequest?

    // Search, index, watch (3.3)
    /// The toolbar search field. Snapshots: `--query` without a `--tab` (or with `--tab watch`).
    var searchText = DebugSnapshot.options.flatMap { [nil, "watch", "watch-edit"].contains($0.tab) ? $0.query : nil } ?? ""
    /// The hits of `searchText`; nil while it is empty.
    private(set) var searchAnswer: KnowledgeIndex.SearchAnswer?
    private var searchTask: Task<Void, Never>?
    /// The index as last counted ("Index: N notes …"); nil before the first count.
    private(set) var indexStatus: KnowledgeIndex.Status?
    private(set) var indexing = false
    /// Files waiting in `inbox/` (agents' proposals, 5.x): the Inbox line under the spaces.
    var inboxCount = 0

    // Inbox (5.3); the methods are in InboxModel.swift.
    /// The proposals in `inbox/` with their checks and model marks (`akit kb inbox`), read with the
    /// base and again on every `inbox/` change the watcher sees.
    var proposals: [KnowledgeInbox.Entry] = []
    /// The proposal in view on the Inbox tab. Snapshots: `--tab inbox --select <proposal id>`.
    var proposalID: String?
    /// Accept… of a note proposal waiting for its confirmation (the plan's diff).
    var acceptRequest: KnowledgeInbox.Plan?
    /// Reject… waiting for its confirmation: the proposal id.
    var rejectRequest: String?
    /// The proposal Check Again is running for.
    var checkingProposal: String?
    /// Accept… of an arrow proposal that names no map, and its area has several: which map.
    struct ArrowMapRequest: Equatable {
        var proposal: String
        var maps: [String]
    }
    var arrowMapRequest: ArrowMapRequest?
    /// "Add an arrow?" on the map in Edit: what Add draws.
    var arrowRequest: KnowledgeInbox.ArrowPlan?
    /// Accept… of a map proposal (5.4): the draft is in Edit in the Inbox, its blocks linked, until
    /// Save Map or Cancel.
    var mapAcceptRequest: KnowledgeInbox.MapPlan?
    /// Raised by Cancel, so the draft's canvas shows the file again without the links.
    var draftGeneration = 0
    /// Draw Map with Pi… while Pi runs: the log lines, and the task (Stop cancels it).
    var drawLog: [String] = []
    var drawTask: Task<Void, Never>?
    /// The heading a search hit opened the note at; the read view scrolls to it.
    private(set) var sectionTarget: String?
    /// The note in Edit changed on disk, not by AKit: Reload or Keep Mine.
    var noteConflict: String?
    /// Per note: the hash of its bytes as AKit last read or wrote them (the own-write rule).
    private var noteHashes: [String: String] = [:]
    private var watcher: KnowledgeWatcher?
    /// The reindex and search after the watcher's last batch (snapshots wait for it).
    private(set) var watchTask: Task<Void, Never>?
    /// Focus… and Preview Agent Context…: what they show for the chosen project folder.
    private(set) var focusInfo: FocusInfo?
    private(set) var agentContext: AgentContext?

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
    /// Every note and map of the base, for resolving a map's links (P1).
    private var targets = KnowledgeLinks(notes: [], maps: [])

    /// The kinds New Note… and Properties offer: the ones in `kb.yaml`, in its order.
    var kinds: [String] { kindsFile.names }

    // MARK: - Loading

    /// Reads the bases; picks `select` (a note id, for snapshots) when given. Flushes what an
    /// earlier run left pending.
    func load(select: String? = nil) async {
        bases = KnowledgeBase.all(home: home)
        sampleBase = bases.first { KnowledgeSeed.marker(of: $0) != nil }
        lintProjects = nil
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
            if DebugSnapshot.options?.tab == "obsidian-setup", let base { obsidianSetup = base.root }
        } else if let select, targets.maps.contains(select) {
            open(map: select)
            if DebugSnapshot.options?.tab == "map-delete" { mapDeleteRequest = select }
        } else if let select, select.hasPrefix("block:") {
            openBlock(String(select.dropFirst("block:".count)))
        }
        // Snapshots: `--tab rename` asks Rename… of the selected note or map, `--query` is the new name.
        if DebugSnapshot.options?.tab == "rename", let item = map ?? note { renameRequest = item }
        // Snapshots: `--tab inbox… --select <proposal id>` shows that proposal; `--tab inbox-arrow`
        // accepts it, so its map opens in Edit with "Add an arrow?" (`--query <map id>` picks the map).
        if let tab = DebugSnapshot.options?.tab, tab.hasPrefix("inbox") {
            if let select, proposals.contains(where: { $0.id == select }) { proposalID = select }
            if tab == "inbox-arrow", let entry = selectedProposal {
                if let map = DebugSnapshot.options?.query { openArrow(entry.id, on: map) } else { requestAccept(entry) }
            }
        }
        await refreshIndex()
        if !searchText.isEmpty { await runSearch() }
    }

    /// Snapshots (`--select block:<element id>`): the map that has this element opens, and its link
    /// opens as a click on it would.
    func openBlock(_ element: String) {
        guard let base else { return }
        for id in targets.maps {
            guard case .success(let scene) = ExcalidrawFile.load(base.mapFile(id)),
                  let found = scene.live.first(where: { $0.id == element }) else { continue }
            open(map: id)
            if let link = found.link, !link.isEmpty { openLink(link) }
            return
        }
        problem = "No map has an element \(element)."
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
            (maps, map, targets) = ([], nil, KnowledgeLinks(notes: [], maps: []))
            kindsFile = .defaults
            (watcher, indexStatus, searchAnswer, inboxCount) = (nil, nil, nil, 0)
            lintFindings = []
            (proposals, proposalID, arrowRequest, mapAcceptRequest) = ([], nil, nil, nil)
            return
        }
        defer {
            lint()
            readInbox()
        }
        if watcher?.root != base.root {
            watcher = KnowledgeWatcher(root: base.root) { [weak self] paths in self?.changed(paths) }
            sweep(base)
            noteHashes = [:]
            if loaded { Task { await refreshIndex() } }
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
        targets = base.linkTargets()
        maps = Self.maps(of: area, in: targets)
        mapTabs = mapTabs.filter { targets.maps.contains($0) }
        if let map, !targets.maps.contains(map) { self.map = mapTabs.last }
        tabs = tabs.filter { id in allNotes.contains { $0.id == id } }
        if let note, !tabs.contains(note) { self.note = nil }
        if note == nil { note = tabs.last }
        readNote()
    }

    func choose(base: KnowledgeBase) {
        guard base != self.base else { return }
        let old = self.base
        Task {
            // An open map's last change is saved in the old base first (N5).
            await forcePostDirty()
            self.base = base
            (area, tabs, note, map) = (nil, [], nil, nil)
            mapTabs = []
            reload()
            await flush(old)
        }
    }

    func choose(area: String?) {
        self.area = area
        notes = allNotes.filter { $0.area == area }
        maps = Self.maps(of: area, in: targets)
    }

    static func maps(of area: String?, in targets: KnowledgeLinks) -> [String] {
        guard let area else { return [] }
        return targets.maps.filter { $0.hasPrefix(area + "/") }
    }

    // MARK: - Maps

    /// Shows a map: its file's text goes to the canvas, and its hash becomes the one a save
    /// expects. A change still waiting on the map that was open is saved under its own id (bridge.js).
    func open(map id: String) {
        guard let base, targets.maps.contains(id) else { return }
        let data: Data
        do { data = try Data(contentsOf: base.mapFile(id)) } catch {
            problem = "Can't read the map \(id): \(error.localizedDescription)"
            return
        }
        let area = String(id.split(separator: "/").first ?? "")
        if area != self.area { choose(area: area) }
        mapHashes[id] = KnowledgeWrite.hash(data)
        mapIsEmpty = Self.isEmpty(map: data)
        showScene(id, data)
        if !mapTabs.contains(id) { mapTabs.append(id) }
        map = id
        noteBesideMap = false
    }

    /// Whether a map file has no element left (an unreadable one is not empty: Lint reports it).
    static func isEmpty(map data: Data) -> Bool {
        if case .success(let file) = ExcalidrawFile.parse(data) { return file.live.isEmpty }
        return false
    }

    /// Puts the map's bytes on the canvas as a new scene.
    private func showScene(_ id: String, _ data: Data) {
        mapScene = MapCanvasView.Scene(key: id, text: String(decoding: data, as: UTF8.self), generation: mapScene.generation + 1)
    }

    /// A map's name without its area: `payments/maps/overview` → `overview`.
    static func mapName(_ id: String) -> String { id.split(separator: "/").dropFirst(2).joined(separator: "/") }

    /// The map tabs the tab bar shows: those of the area of the map in view.
    var areaMapTabs: [String] {
        guard let map else { return [] }
        let area = map.split(separator: "/").first.map(String.init)
        return mapTabs.filter { $0.split(separator: "/").first.map(String.init) == area }
    }

    /// Close Map: the map in view's tab closes. Its last change is saved first, then the queue is
    /// committed (a tab close, U2). The area's next open map shows, else the note panel.
    func closeMap() async {
        guard let map else { return }
        await close(mapTab: map)
    }

    /// Closes a map tab; for the map in view, its last change is saved first (N5).
    func close(mapTab id: String) async {
        if id == map { await forcePostDirty() }
        let others = areaMapTabs.filter { $0 != id }
        mapTabs.removeAll { $0 == id }
        if id == map {
            if let next = others.last { open(map: next) } else { (map, noteBesideMap) = (nil, false) }
        }
        await flush(base)
    }

    /// The other side of a relation, or its map, from the note panel's Relations.
    func showRelation(note id: String) {
        if map != nil { noteBesideMap = true }
        open(id)
    }

    /// A relation's map: it opens with the note in view beside it.
    func showRelation(map id: String) {
        open(map: id)
        noteBesideMap = note != nil
    }

    /// A note dragged from the list onto the map (K6): a block linking it, at the drop point (page
    /// pixels from the canvas's top left). The link is the shortest one that resolves to the note
    /// from the map; the block is saved like any other change.
    func drop(note id: String, at point: CGPoint) async {
        guard let map, let canvas = MapCanvasView.Coordinator.current, let entry = allNotes.first(where: { $0.id == id }) else { return }
        let path = "areas/\(map).excalidraw"
        let parts = id.split(separator: "/").map(String.init)
        let forms = (1...parts.count).reversed().map { parts.suffix($0).joined(separator: "/") }.reversed()
        let link = forms.map { "[[\($0)]]" }.first { targets.resolve($0, from: path) == .note(id) } ?? "akit:note/\(id)"
        let label = entry.title
        mapEditing = true
        if let element = await canvas.addLinkedBlock(link: link, label: label, at: point) {
            notice = "Added a block for \(id) (\(link))."
            if DebugSnapshot.options != nil { print("map: dropped \(id) as \(element) with \(link)") }
        } else {
            problem = "Couldn't add a block for \(id) to the map."
        }
    }

    /// A `save` from the canvas: Excalidraw's own serialization, written as it is when the file on
    /// disk is still the one AKit read or last wrote; else the conflict waits for Reload / Keep Mine.
    func saveMap(_ id: String, json: String) {
        guard let base else { return }
        let bytes = Data(json.utf8)
        if mapConflict?.id == id {
            mapConflict?.bytes = bytes
            return
        }
        guard let expected = mapHashes[id] else {
            problem = "The map \(id) wasn't opened in this run, so AKit didn't save it."
            return
        }
        do {
            let (path, outcome) = try base.saveMap(id, bytes: bytes, expectedHash: expected)
            switch outcome {
            case .saved(let hash):
                mapHashes[id] = hash
                if id == map { mapIsEmpty = Self.isEmpty(map: bytes) }
                enqueue(path, in: base)
                if let note { noteRelations = (try? base.mapGraph().relations(of: note)) ?? [] }
            case .conflict:
                mapConflict = MapConflict(id: id, bytes: bytes)
            }
        } catch {
            problem = error.message
        }
    }

    /// Before a flush (tab or map close, quit, Update), a base switch and a rename (N5): the open
    /// canvas hands over a change still waiting for its 800 ms post, and it is saved now. false when
    /// the page didn't answer or the save didn't go through (a conflict, a write error).
    @discardableResult
    func forcePostDirty() async -> Bool {
        // The Inbox's map draft (5.4) is no map of the base: its canvas is never saved this way.
        guard map != nil, let canvas = MapCanvasView.Coordinator.current, !canvas.scene.key.hasPrefix("inbox/") else { return true }
        let save: (key: String, json: String)?
        do { save = try await canvas.takeUnsaved() } catch { return false }
        guard let save else { return mapConflict == nil }
        if DebugSnapshot.options != nil { print("map: force-posted \(save.key), \(save.json.utf8.count) bytes") }
        let problemBefore = problem
        saveMap(save.key, json: save.json)
        await lastEnqueue?.value
        return mapConflict == nil && problem == problemBefore
    }

    // MARK: - Rename (R3)

    /// Rename… waiting in its sheet: the note or map id. Snapshots: `--tab rename`.
    var renameRequest: String?

    /// The rename's plan for the sheet's preview (nothing is written): the plan, or why it is refused.
    func planRename(_ id: String, to new: String) -> Result<KnowledgeRename, KnowledgeBase.Failure> {
        guard let base else { return .failure(KnowledgeBase.Failure(message: "No base.")) }
        do { return .success(try base.planRename(id, to: new)) } catch { return .failure(error) }
    }

    /// Rename…: the open map's last change is saved first (N5; refused with "Save the open map
    /// first" when that fails), then the rename is planned again on the saved files and applied in
    /// one commit. Tabs follow the new ids, and every open map whose file changed is read again.
    func rename(_ id: String, to new: String) async -> Bool {
        guard let base else { return false }
        guard await forcePostDirty() else {
            problem = "Save the open map first: its last change couldn't be saved, so nothing was renamed."
            return false
        }
        do {
            let plan = try base.planRename(id, to: new)
            try await base.apply(plan, env: env)
            let changedMaps = plan.files.filter { $0.path.hasSuffix(".excalidraw") }.map { change in
                (old: String(change.path.dropFirst("areas/".count).dropLast(".excalidraw".count)),
                 new: String(change.newPath.dropFirst("areas/".count).dropLast(".excalidraw".count)))
            }
            func moved(_ value: String) -> String { value == plan.from ? plan.to : value }
            tabs = tabs.map(moved)
            note = note.map(moved)
            mapTabs = mapTabs.map(moved)
            let visible = map.map(moved)
            map = visible
            reload()
            for change in changedMaps {
                mapHashes[change.old] = nil
                if mapTabs.contains(change.new), let data = try? Data(contentsOf: base.mapFile(change.new)) {
                    mapHashes[change.new] = KnowledgeWrite.hash(data)
                    if change.new == visible {
                        showScene(change.new, data)
                    }
                }
            }
            if let visible, !changedMaps.contains(where: { $0.new == visible }) { mapScene.key = visible }
            notice = "Renamed \(plan.from) to \(plan.to) and \(plan.linkCount) link\(plan.linkCount == 1 ? "" : "s"), committed."
            return true
        } catch {
            problem = error.message
            return false
        }
    }

    /// Changed on disk → Reload: the disk version goes on the canvas; the unsaved change is dropped.
    func reloadConflictedMap() {
        guard let conflict = mapConflict, let base else { return }
        mapConflict = nil
        guard let data = try? Data(contentsOf: base.mapFile(conflict.id)) else {
            problem = "The map \(conflict.id) is gone from disk."
            return
        }
        mapHashes[conflict.id] = KnowledgeWrite.hash(data)
        if map == conflict.id {
            showScene(conflict.id, data)
        }
        notice = "Reloaded \(conflict.id) from disk."
    }

    /// Changed on disk → Keep Mine: the disk copy is backed up (`~/.akit/backups`), then your
    /// version is written over it and queued for its commit.
    func keepMineInConflict() {
        guard let conflict = mapConflict, let base else { return }
        let file = base.mapFile(conflict.id)
        guard let disk = try? Data(contentsOf: file) else {
            mapConflict = nil
            problem = "The map \(conflict.id) is gone from disk, so there is nothing to keep it over."
            return
        }
        do {
            let backup = try Backup.save(disk, as: file, home: home)
            mapConflict = nil
            mapHashes[conflict.id] = KnowledgeWrite.hash(disk)
            saveMap(conflict.id, json: String(decoding: conflict.bytes, as: UTF8.self))
            notice = "Kept your version; the disk copy is in \(backup.tildePath)."
        } catch {
            problem = "Couldn't back up \(file.path): \(error.localizedDescription)"
        }
    }

    /// New Map…: `akit kb new-map AREA NAME`, committed at once; then it opens in Edit.
    /// Add Folder… (K27): writes and commits the planned note, then shows it.
    func addFolder(_ plan: KnowledgeFolderNote) async -> Bool {
        guard let base else { return false }
        do {
            let added = try await base.addFolder(plan, env: env)
            reload()
            await closeMap()
            choose(area: plan.area)
            open(plan.note)
            notice = "Added \(plan.note) for \(plan.path)" + (added.kindAdded ? "; kb.yaml got the kind \(plan.kind)." : ".")
            return true
        } catch {
            problem = error.message
            return false
        }
    }

    func newMap(area: String, name: String) async -> Bool {
        guard let base else { return false }
        do {
            let path = try await base.newMap(area: area, name: name, env: env)
            await forcePostDirty()
            reload()
            open(map: String(path.dropFirst("areas/".count).dropLast(".excalidraw".count)))
            mapEditing = true
            return true
        } catch {
            problem = error.message
            return false
        }
    }

    /// Delete… of a map: to the Trash, its removal committed at once (`akit kb rm <map> --yes`).
    func delete(map id: String) async {
        guard let base else { return }
        if map == id { (map, noteBesideMap) = (nil, false) }
        if mapConflict?.id == id { mapConflict = nil }
        do {
            try await base.moveToTrash(map: id, env: env)
            mapHashes[id] = nil
            reload()
            notice = "Moved the map to the Trash."
        } catch {
            problem = error.message
        }
    }

    /// A block or arrow of the map in view was opened (a click in view mode): a note link opens
    /// the note beside the map, a map link that map, a web link the default browser.
    func openLink(_ link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
            return
        }
        switch targets.resolve(trimmed, from: map ?? area ?? "") {
        case .note(let id):
            open(id)
            noteBesideMap = true
        case .map(let id):
            open(map: id)
        case .missing:
            notice = "The link \(trimmed) points to no note or map in this base."
        case .ambiguous(let ids):
            notice = "The link \(trimmed) fits more than one: \(ids.joined(separator: ", "))."
        }
    }

    // MARK: - Lint

    /// Checks the base again (`akit kb lint`); `rescan` finds the known projects again too.
    func lint(rescan: Bool = false) {
        guard let base else {
            lintFindings = []
            return
        }
        let projects = (rescan ? nil : lintProjects)
            ?? KnowledgeLint.Projects.find(home: home, projectsRoot: projectsRoot ?? home.appending(path: "Projects"),
                                           brainRoot: brainRoot ?? Brain.defaultRoot(home: home))
        lintProjects = projects
        lintFindings = KnowledgeLint.run(base, projects: projects, home: home)
    }

    /// The findings about one note (its links, `repo:`, `files:`, `kind:`).
    func lintFindings(of note: String) -> [KnowledgeLint.Finding] {
        lintFindings.filter { $0.note == note }
    }

    /// Open: the note or the map of a finding, out of the Lint tab.
    func open(finding: KnowledgeLint.Finding) async {
        screenTab = .notes
        if let id = finding.map {
            open(map: id)
        } else if let id = finding.note {
            await closeMap()
            open(id)
        }
    }

    /// Create Note… of a broken link: New Note… with the link's area and name.
    func createNote(for finding: KnowledgeLint.Finding) {
        guard let target = KnowledgeLint.newNote(for: finding) else { return }
        newNoteRequest = NewNoteRequest(area: target.area, name: target.name)
    }

    // MARK: - Tabs

    func open(_ id: String) {
        guard let entry = allNotes.first(where: { $0.id == id }) else { return }
        sectionTarget = nil
        if entry.area != area { choose(area: entry.area) }
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
            noteRelations = []
            return
        }
        // Changed on disk waits for Reload / Keep Mine: the editor keeps your text until then.
        if noteConflict != note {
            text = KnowledgeNote.load(base.noteFile(note))?.text ?? ""
            noteHashes[note] = KnowledgeWrite.hash(of: base.noteFile(note))
        }
        noteRelations = (try? base.mapGraph().relations(of: note)) ?? []
    }

    // MARK: - Writes

    /// Edit: the file is saved at once with exactly this text; the commit waits in the queue.
    func save(_ newText: String) {
        guard let base, let note, newText != text, noteConflict != note else { return }
        do {
            let path = try base.save(note: note, text: newText)
            text = newText
            noteHashes[note] = KnowledgeWrite.hash(of: base.noteFile(note))
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
        // Obsidian opens only files of its vaults; for any other it says "Unable to find a vault".
        if let known = Obsidian.knownVaults(home: home), !Obsidian.canOpen(base.noteFile(note), known: known) {
            obsidianSetup = base.root
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
            // The base's lock is waited for (up to 2 s), never on the main actor.
            let home = home
            try await Task.detached { _ = try KnowledgeSeed.remove(sample, home: home) }.value
            if base == sample { (base, area, tabs, note) = (nil, nil, [], nil) }
            await load()
            notice = "Moved the sample base to the Trash."
        } catch {
            problem = error.localizedDescription
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

    // MARK: - Search, index, watch (3.3)

    /// The search field changed: the hits follow after a short pause in typing (`kb search`).
    func search(_ text: String) {
        searchText = text
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.runSearch()
        }
    }

    /// `KnowledgeIndex.search` of the field's text in the whole base (its misses aren't logged:
    /// the miss log is about agents' searches).
    func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base, !query.isEmpty else {
            searchAnswer = nil
            return
        }
        let result: Result<KnowledgeIndex.SearchAnswer, any Error> = await Task.detached {
            do { return .success(try KnowledgeIndex(base: base).search(query, limit: 30, maxTokens: .max, logMisses: false)) } catch {
                return .failure(error)
            }
        }.value
        guard query == searchText.trimmingCharacters(in: .whitespacesAndNewlines), base == self.base else { return }
        switch result {
        case .success(let answer): searchAnswer = answer
        case .failure(let error): problem = error.localizedDescription
        }
    }

    /// A search hit: its note opens, scrolled to the hit's section.
    func open(hit: KnowledgeIndex.Hit) async {
        await closeMap()
        open(hit.note)
        sectionTarget = hit.heading
    }

    /// Brings the index up to the files (`kb index`; with `rebuild`, `kb index --rebuild`) and counts it.
    func refreshIndex(rebuild: Bool = false) async {
        guard let base, !indexing else { return }
        indexing = true
        let result: Result<KnowledgeIndex.Status, any Error> = await Task.detached {
            do { return .success(try KnowledgeIndex(base: base).refresh(rebuild: rebuild)) } catch { return .failure(error) }
        }.value
        indexing = false
        guard base == self.base else { return }
        switch result {
        case .success(let status):
            indexStatus = status
            if rebuild { notice = "Rebuilt the index: \(status.notes) notes, \(status.chunks) sections." }
        case .failure(let error): problem = error.localizedDescription
        }
    }

    /// One quiet batch from the watcher (`WatchFilter`): outside edits are queued for the batch
    /// commit and reindexed; AKit's own saves are reindexed only; `inbox/` only recounts. An open
    /// note in Edit or map in Edit changed by someone else asks Reload / Keep Mine; in read or view
    /// mode it simply shows the disk version.
    func changed(_ paths: [String]) {
        guard let base else { return }
        var own: [String: String] = [:]
        for (id, hash) in noteHashes { own[base.notePath(id)] = hash }
        for (id, hash) in mapHashes { own[base.mapPath(id)] = hash }
        let root = base.root
        let batch = WatchFilter.batch(paths, own: own) { KnowledgeWrite.hash(of: root.appending(path: $0)) }
        if DebugSnapshot.options != nil {
            print("watch: \(paths.joined(separator: ", ")) → reindex \(batch.reindex), queued \(batch.enqueue.joined(separator: ", ")), inbox \(batch.inbox)")
        }
        if batch.inbox { readInbox() }
        for path in batch.enqueue { enqueue(path, in: base) }
        if let note, editing, batch.outside.contains(base.notePath(note)), FileWalk.isRegularFile(base.noteFile(note)) {
            noteConflict = note
        }
        if let map, batch.outside.contains(base.mapPath(map)), FileWalk.isRegularFile(base.mapFile(map)), mapConflict == nil {
            mapChangedOnDisk(map)
        }
        guard batch.reindex else { return }
        reload()
        let previous = watchTask
        watchTask = Task {
            await previous?.value
            await refreshIndex()
            if !searchText.isEmpty { await runSearch() }
        }
    }

    /// The map in view changed on disk, not by AKit. In Edit: the existing Changed on disk choice,
    /// with the canvas's scene as yours. In view mode: the disk version goes on the canvas.
    private func mapChangedOnDisk(_ id: String) {
        guard mapEditing, let canvas = MapCanvasView.Coordinator.current else {
            reloadMapFromDisk(id)
            return
        }
        Task {
            if let json = (try? await canvas.call("akitSerialize")) as? String, map == id {
                mapConflict = MapConflict(id: id, bytes: Data(json.utf8))
            } else {
                reloadMapFromDisk(id)
            }
        }
    }

    private func reloadMapFromDisk(_ id: String) {
        guard let base, let data = try? Data(contentsOf: base.mapFile(id)) else { return }
        mapHashes[id] = KnowledgeWrite.hash(data)
        if map == id {
            showScene(id, data)
        }
        notice = "\(id) changed on disk; showing that version."
    }

    /// Changed on disk → Reload: the note's disk version replaces the text in the editor.
    func reloadConflictedNote() {
        guard noteConflict != nil else { return }
        noteConflict = nil
        readNote()
        notice = "Reloaded the note from disk."
    }

    /// Changed on disk → Keep Mine: the disk copy is backed up (`~/.akit/backups`), then your text
    /// is written over it and queued for its commit.
    func keepMineInNoteConflict() {
        guard let id = noteConflict, let base else { return }
        noteConflict = nil
        let file = base.noteFile(id)
        guard let disk = try? Data(contentsOf: file) else {
            problem = "The note \(id) is gone from disk, so there is nothing to keep it over."
            return
        }
        do {
            let backup = try Backup.save(disk, as: file, home: home)
            let path = try base.save(note: id, text: text)
            noteHashes[id] = KnowledgeWrite.hash(of: file)
            enqueue(path, in: base)
            notice = "Kept your version; the disk copy is in \(backup.tildePath)."
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - Focus and agent context (3.3)

    struct FocusInfo: Equatable {
        var folder: URL
        /// The id `focus.json` keys the project by (its normalized remote, else `local/…`).
        var project: String
        var choice: KnowledgeBase.FocusChoice
    }

    /// What `akit kb context FOLDER` prints for a project, and the note in view's `kb neighbors`.
    struct AgentContext: Sendable {
        var folder: URL
        var project: String
        var choice: KnowledgeBase.FocusChoice
        /// The base the CLI picks for the folder; nil when there is none.
        var base: KnowledgeBase?
        var answer: KnowledgeIndex.ContextAnswer?
        var neighbors: KnowledgeIndex.NeighborsAnswer?
        var problem: String?
    }

    /// Focus…: the project's focus in this base and where it comes from (`akit kb focus FOLDER`).
    func loadFocus(folder: URL, projectsRoot: URL) async {
        guard let base else { return }
        let (project, choice) = await base.focus(folder: folder, env: env, projectsRoot: projectsRoot)
        focusInfo = FocusInfo(folder: folder, project: project, choice: choice)
    }

    /// Focus… Save: `akit kb focus FOLDER --set AREA` (nil: `--clear`), in `focus.json` on this Mac.
    func saveFocus(area: String?, projectsRoot: URL) async -> Bool {
        guard let info = focusInfo, let base else { return false }
        do {
            try KnowledgeBase.Focus.load(home: home).setting(area: area, project: info.project, in: base).save(home: home)
        } catch {
            problem = error.message
            return false
        }
        await loadFocus(folder: info.folder, projectsRoot: projectsRoot)
        notice = area.map { "\(info.project): focus \($0)." } ?? "\(info.project): your focus choice is cleared."
        return true
    }

    /// Preview Agent Context…: `akit kb context FOLDER` exactly (the base the CLI picks for the
    /// folder, the folder's focus, the 4000-token cap), and `akit kb neighbors` of the note in view.
    func loadContext(folder: URL, projectsRoot: URL) async {
        let env = env, note = note, brain = brainRoot ?? Brain.defaultRoot(home: home)
        agentContext = await Task.detached {
            var context = AgentContext(folder: folder, project: "", choice: .none)
            do {
                guard let base = try await KnowledgeBase.choose(option: nil, folder: folder, env: env, projectsRoot: projectsRoot,
                                                                forReading: true) else {
                    context.problem = "No knowledge base on this Mac."
                    return context
                }
                context.base = base
                (context.project, context.choice) = await base.focus(folder: folder, env: env, projectsRoot: projectsRoot)
                let index = KnowledgeIndex(base: base)
                // The systems' folders as akit kb context finds them (K27).
                let local = KnowledgeLocal(projects: KnowledgeLint.Projects.find(home: env.homeDirectory, projectsRoot: projectsRoot, brainRoot: brain),
                                           home: env.homeDirectory)
                context.answer = try index.context(focus: context.choice.area, local: local)
                if let note { context.neighbors = try? index.neighbors(note) }
            } catch let error as KnowledgeIndex.Failure {
                context.problem = error.message
            } catch let error as KnowledgeBase.Failure {
                context.problem = error.message
            } catch {
                context.problem = error.localizedDescription
            }
            return context
        }.value
    }

    // MARK: - Commit queue

    /// Waits until the last save is queued (before a write that flushes the queue, like Accept).
    func lastEnqueueDone() async { await lastEnqueue?.value }

    /// A note AKit wrote outside the editor (Accept): its bytes now are AKit's own, so the watcher
    /// doesn't queue them as an outside edit.
    func markOwnWrite(note id: String) {
        guard let base else { return }
        noteHashes[id] = KnowledgeWrite.hash(of: base.noteFile(id))
    }

    /// A map AKit wrote outside the canvas (Accept of a map proposal): the same for the watcher.
    func markOwnWrite(map id: String) {
        guard let base else { return }
        mapHashes[id] = KnowledgeWrite.hash(of: base.mapFile(id))
    }

    /// The startup sweep when a base opens: what differs from its last commit under `areas/` and
    /// `kb.yaml` is queued (`KnowledgeCommitQueue.sweep`), so an edit whose enqueue was lost last
    /// time (`unqueued` lives in memory only) still gets its commit. Never `inbox/`.
    private func sweep(_ base: KnowledgeBase) {
        let queue = KnowledgeCommitQueue(base: base.root, env: env)
        let previous = lastEnqueue
        lastEnqueue = Task {
            await previous?.value
            _ = await Task.detached { await queue.sweep() }.value
        }
        scheduleIdleFlush()
    }

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
        if let current {
            await current.forcePostDirty()
            await current.flush(current.base)
        }
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
        let counts = KnowledgeLint.counts(lintFindings)
        lines.append("tab: \(screenTab.rawValue), lint \(counts.error) errors, \(counts.warning) warnings, \(counts.hint) hints, inbox \(proposals.count)")
        if screenTab == .inbox { lines += inboxManifest }
        if let arrowRequest {
            lines.append("add an arrow?: \(arrowRequest.text) on \(arrowRequest.map)" + (arrowRequest.exists ? " (already there)" : "")
                + [arrowRequest.from, arrowRequest.to].filter { $0.element == nil }.map { ", new block \($0.label) \($0.link)" }.joined())
        }
        if screenTab == .lint {
            lines += lintFindings.map { finding in
                "finding: \(finding.severity.rawValue) \(finding.rule.rawValue) \(finding.file)" + (finding.element.map { " \($0)" } ?? "")
                    + (finding.link.map { " \($0)" } ?? "") + (KnowledgeLint.newNote(for: finding) == nil ? ", Open" : ", Open, Create Note…")
            }
        }
        lines.append("areas: " + areas.map { "\($0.name)\($0.name == area ? "*" : "") (\($0.notes))" }.joined(separator: ", "))
        lines.append("notes: " + notes.map(\.id).joined(separator: ", "))
        lines.append("maps: " + maps.map { $0 == map ? "\($0)*" : $0 }.joined(separator: ", "))
        if !mapTabs.isEmpty { lines.append("map tabs: " + mapTabs.joined(separator: ", ")) }
        if let map { lines.append("map: \(map), \(mapEditing ? "Edit" : "view only")" + (mapIsEmpty ? ", empty" : "") + (noteBesideMap && note != nil ? ", note beside it" : "")) }
        if let mapConflict { lines.append("conflict: Changed on disk, \(mapConflict.id): Reload / Keep Mine") }
        lines.append("tabs: " + tabs.joined(separator: ", "))
        if let entry = noteEntry {
            lines.append("note: \(entry.title) (\(entry.id)\(entry.kind.map { ", kind \($0)" } ?? "")), \(editing ? "Edit" : "read")")
            if !noteRelations.isEmpty {
                lines.append("relations: " + noteRelations.map { edge in
                    "\(edge.from) → \(edge.to)" + (edge.kind.map { " \"\($0)\"" } ?? "") + (edge.flow.map { " flow \($0)" } ?? "") + " (\(edge.map))"
                }.joined(separator: "; "))
            }
            let sections = KnowledgeNote(text: text).sections.map(\.heading)
            if !sections.isEmpty { lines.append("sections: " + sections.joined(separator: ", ")) }
            let checks = lintFindings(of: entry.id)
            if !checks.isEmpty {
                lines.append("note checks (grey): " + checks.map { "\($0.rule.rawValue) \($0.link ?? "-")" }.joined(separator: "; "))
            }
            if showingProperties {
                lines.append("properties: kind \(entry.kind ?? "none")"
                    + noteProperties.map { "; \($0.key) \($0.value.isEmpty ? "-" : $0.value)\($0.isField ? "" : " (not a field of the kind)")" }.joined())
            }
        } else {
            lines.append("note: none")
        }
        if let renameRequest, let new = DebugSnapshot.options?.query {
            switch planRename(renameRequest, to: new) {
            case .success(let plan): lines.append("rename: \(plan.from) → \(plan.to), \(plan.linkCount) links in " + plan.files.map(\.path).joined(separator: ", "))
            case .failure(let error): lines.append("rename refused: \(error.message)")
            }
        }
        if let status = indexStatus {
            lines.append("index: \(status.notes) notes, \(status.maps) maps, \(status.chunks) sections" + (status.stale ? ", stale" : ""))
        }
        lines.append("inbox: \(inboxCount)")
        if let answer = searchAnswer {
            lines.append("search: “\(searchText)”, \(answer.results.count) hit\(answer.results.count == 1 ? "" : "s")" + (answer.stale ? ", stale" : ""))
            for hit in answer.results.prefix(10) {
                lines.append("hit: \(hit.note)" + (hit.heading.map { " ## \($0)" } ?? "") + ": \(hit.snippet)")
            }
        }
        if let sectionTarget { lines.append("section: \(sectionTarget)") }
        if let noteConflict { lines.append("conflict: Changed on disk, note \(noteConflict): Reload / Keep Mine") }
        switch DebugSnapshot.options?.tab {
        case "focus":
            if let info = focusInfo {
                lines.append("focus: \(info.folder.tildePath) → \(info.project), " + (info.choice.area.map { "\($0) (\(info.choice.source?.rawValue ?? "-"))" } ?? "none"))
            }
        case "context":
            if let context = agentContext {
                lines.append("context: \(context.folder.tildePath) → \(context.project), focus \(context.choice.area ?? "none")"
                    + (context.problem.map { ", \($0)" } ?? ""))
                if let answer = context.answer {
                    lines.append("context card: \(answer.systems.count) systems, \(answer.relations.count) relations, \(answer.tokens) of \(Budget.defaultTokens) tokens"
                        + (answer.truncated ? ", cut" : ""))
                    for system in answer.systems { lines.append("system: \(system.note): \(system.line)" + (system.local.map { " [\($0)]" } ?? "")) }
                    for relation in answer.relations { lines.append("relation: \(relation.from) → \(relation.to)" + (relation.kind.map { " \"\($0)\"" } ?? "")) }
                }
                if let neighbors = context.neighbors {
                    lines.append("neighbors of \(neighbors.note): \(neighbors.edges.count) arrows, \(neighbors.tokens) tokens")
                }
            }
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
