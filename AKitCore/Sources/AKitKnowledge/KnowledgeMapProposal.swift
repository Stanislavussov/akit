import AKitFoundation
import Foundation

/// Map proposals (5.4, K21): an agent draws a map (with `excalidraw-cli`, in its own harness) and
/// sends it with `akit kb propose --map AREA/NAME --file F.excalidraw`. The draft waits beside the
/// proposal as `inbox/<id>.excalidraw`; it is never committed or indexed. Accept is the person's,
/// in the app only: the draft opens in the canvas, each block whose label names one note gets the
/// link `[[note]]` (`MapPlan.links`), and Excalidraw's own serialization is saved to
/// `areas/AREA/maps/NAME.excalidraw` by `acceptMap` in one commit. Core never rewrites the file.
extension KnowledgeInbox {
    /// A map draft is larger than a note's text, but still small (K19).
    public static let maxMapBytes = 2 * 1024 * 1024

    /// The draft beside a map proposal: `inbox/<id>.excalidraw`.
    public static func draftPath(of id: String) -> String { "inbox/\(id).excalidraw" }

    /// What the CLI says for a map proposal: the person accepts it in the app.
    public static let mapMessage = "Open Knowledge → Inbox to accept a map."

    /// What a label names among the base's notes.
    public enum LabelMatch: Sendable, Equatable {
        case note(String)
        /// More than one note fits: the note ids.
        case ambiguous([String])
        case none
    }

    /// The note a block's label names, by the link rules (P1, the label read as `[[label]]` from
    /// the map's path), else by a note's title (ignoring case): exactly one note, else ambiguous
    /// or none. A label that names a map is none: only notes are linked.
    public static func match(label: String, map: String, targets: KnowledgeLinks, titles: [String: String]) -> LabelMatch {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("[["), !text.contains("]]") else { return .none }
        switch targets.resolve(text, from: "areas/\(map).excalidraw") {
        case .note(let id): return .note(id)
        case .ambiguous(let ids): return .ambiguous(ids)
        case .map, .missing: break
        }
        let wanted = text.lowercased()
        let titled = targets.notes.filter { titles[$0]?.trimmingCharacters(in: .whitespaces).lowercased() == wanted }
        switch titled.count {
        case 0: return .none
        case 1: return .note(titled[0])
        default: return .ambiguous(titled)
        }
    }

    /// The shortest `[[…]]` that resolves to `note` from the map, else `akit:note/<id>`.
    static func shortestLink(to note: String, map: String, targets: KnowledgeLinks) -> String {
        let parts = note.split(separator: "/").map(String.init)
        let forms = (1...max(1, parts.count)).map { parts.suffix($0).joined(separator: "/") }
        return forms.map { "[[\($0)]]" }.first { targets.resolve($0, from: "areas/\(map).excalidraw") == .note(note) } ?? "akit:note/\(note)"
    }

    /// A scene's blocks (shapes with a label) and arrows (`from -kind-> to` by the labels of the
    /// shapes they are bound to), as the proposal's body and the replace diff list them.
    static func outline(_ scene: ExcalidrawFile) -> (blocks: [String], arrows: [String]) {
        let labels = MapGraph.labels(in: scene)
        let live = scene.live
        let shapes = live.filter { !["text", "arrow", "line", "freedraw"].contains($0.type) }
        let blocks = shapes.compactMap { labels[$0.id] }
        let arrows = live.filter { $0.type == "arrow" }.map { arrow in
            let from = arrow.startBinding.flatMap { labels[$0] } ?? "?", to = arrow.endBinding.flatMap { labels[$0] } ?? "?"
            return "\(from) " + (labels[arrow.id].map { "-\($0)-> " } ?? "-> ") + to
        }
        return (blocks, arrows)
    }

    /// The body of a map proposal: the draft's blocks and arrows, for reading and the check model
    /// (Accept uses the draft itself).
    static func mapSummary(_ scene: ExcalidrawFile) -> String {
        let (blocks, arrows) = outline(scene)
        return "Blocks: " + (blocks.isEmpty ? "none" : blocks.joined(separator: ", ")) + "\n"
            + "Arrows: " + (arrows.isEmpty ? "none" : arrows.joined(separator: "; ")) + "\n"
    }

    /// What Accept of a map proposal saves (5.4): the draft, the links the canvas sets before it
    /// serializes, the labels left plain, and the map it replaces (if any).
    public struct MapPlan: Sendable, Equatable {
        /// A block that gets a link: the shape's element id (the shape that holds the label, also
        /// when the label is free text, as in an excalidraw-cli draft).
        public struct Link: Sendable, Equatable, Encodable {
            public let element: String
            public let label: String
            public let note: String
            /// `[[billing]]`: the shortest link that resolves to the note from the map.
            public let link: String
        }

        /// A block whose label names no note, or more than one: it stays plain.
        public struct Unlinked: Sendable, Equatable, Encodable {
            public let element: String
            public let label: String
            /// The notes that fit (ambiguous); empty when none does.
            public let candidates: [String]
        }

        public let proposal: KnowledgeProposal
        /// The map id (`payments/maps/flow`) and its base-relative path.
        public let map: String
        public let mapPath: String
        /// The draft's bytes as the proposal has them.
        public let draft: Data
        /// The map's bytes now; nil for a new map.
        public let original: Data?
        /// The area folder doesn't exist yet: Accept creates it (K23).
        public let newArea: Bool
        public let links: [Link]
        public let unlinked: [Unlinked]
        /// `+ block billing`, `- arrow a -> b`, `  block orders-api` (kept), against the map it replaces.
        public let changes: [String]

        /// Element id → link, for the canvas (`akitSetLinks`).
        public var linkMap: [String: String] { Dictionary(links.map { ($0.element, $0.link) }, uniquingKeysWith: { first, _ in first }) }

        /// The path, what happens to it, and the changes.
        public var diff: String {
            let head = original == nil ? "\(mapPath) (new" + (newArea ? ", in a new area" : "") + ")" : "\(mapPath) (replaces the map)"
            return ([head] + changes).joined(separator: "\n")
        }
    }

    /// What Accept of a map did.
    public struct MapAccepted: Sendable, Equatable {
        public let plan: MapPlan
        /// The committed paths (the map, and `inbox/.gitkeep` for a base made before 5.1).
        public let paths: [String]
        /// The replaced map's copy from before the write; nil for a new map.
        public let backup: URL?
    }
}

extension KnowledgeBase {
    /// Note titles by id, for block labels.
    func noteTitles() -> [String: String] {
        Dictionary(((try? notes()) ?? []).map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Map proposals (5.4)

    /// The map a map proposal names: `AREA/NAME`, `AREA/maps/NAME`, with or without `areas/` and
    /// `.excalidraw`. Refused: `..`, an absolute or `~` path, hidden parts, `inbox/`, more parts.
    /// The area may be new (K23, created on Accept); an existing map is replaced on Accept.
    func mapProposalTarget(_ name: String) throws(Failure) -> (id: String, exists: Bool, newArea: Bool) {
        var value = Self.nfc(name.trimmingCharacters(in: .whitespaces))
        let refused = "“\(name)” can't be a proposal's map:"
        if value.hasPrefix("/") || value.hasPrefix("~") || value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." }) {
            throw Failure(message: "\(refused) a map proposal names AREA/NAME under areas/, never a path that leaves it.")
        }
        if value.hasPrefix("areas/") { value.removeFirst("areas/".count) }
        if value.hasSuffix(".excalidraw") { value.removeLast(".excalidraw".count) }
        var parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, parts[1] == "maps" { parts.remove(at: 1) }
        guard parts.count == 2, parts[0] != "inbox", parts.allSatisfy(Self.validName) else {
            throw Failure(message: "\(refused) write it as AREA/NAME (like payments/flow): one area, one map name, neither hidden.")
        }
        let id = "\(parts[0])/maps/\(parts[1])"
        guard Self.isWithin(mapFile(id), areasFolder) else { throw Failure(message: "\(refused) its file is outside areas/.") }
        return (id, FileWalk.isRegularFile(mapFile(id)), (try? areaFolder(parts[0])) == nil)
    }

    /// The checks of a map proposal besides `secret`: `target` (the map: new, in a new area, or
    /// replaced) and `map` (the draft is there and is an Excalidraw scene with elements).
    func mapChecks(_ proposal: Proposal, draft: Data?) -> [KnowledgeInbox.Check] {
        var checks: [KnowledgeInbox.Check] = []
        do {
            let target = try mapProposalTarget(proposal.target ?? "")
            let area = target.id.split(separator: "/")[0]
            checks.append(.init(name: "target", status: .passed, message: target.exists ? "Replaces the map \(target.id) on Accept."
                : target.newArea ? "A new map in a new area \(area), created on Accept." : "A new map."))
        } catch {
            checks.append(.init(name: "target", status: .failed, message: error.message))
        }
        let path = KnowledgeInbox.draftPath(of: proposal.id)
        guard let draft else {
            checks.append(.init(name: "map", status: .failed, message: "The draft \(path) is missing."))
            return checks
        }
        switch ExcalidrawFile.parse(draft) {
        case .failure(let failure):
            checks.append(.init(name: "map", status: .failed, message: "The draft is \(failure.message)."))
        case .success(let scene) where scene.live.isEmpty:
            checks.append(.init(name: "map", status: .failed, message: "The draft has no elements."))
        case .success:
            checks.append(.init(name: "map", status: .passed))
        }
        return checks
    }

    /// What Accept of a map proposal saves (nothing is written): the links each block gets, the
    /// labels left plain, and the changes against the map it replaces. Refused for another kind and
    /// for a proposal whose checks fail now.
    public func planMap(_ proposal: Proposal) throws(Failure) -> KnowledgeInbox.MapPlan {
        guard proposal.kind == .map else { throw Failure(message: "\(proposal.id) is not a map proposal.") }
        let draftFile = root.appending(path: KnowledgeInbox.draftPath(of: proposal.id))
        guard let draft = try? Data(contentsOf: draftFile) else {
            throw Failure(message: "The draft \(KnowledgeInbox.draftPath(of: proposal.id)) is missing; reject the proposal.")
        }
        if let failed = checks(of: proposal, draft: draft).first(where: { $0.status == .failed }) {
            throw Failure(message: "The proposal fails its \(failed.name) check: \(failed.message ?? "")")
        }
        guard case .success(let scene) = ExcalidrawFile.parse(draft) else { throw Failure(message: "The draft can't be read.") }
        let target = try mapProposalTarget(proposal.target ?? "")
        let original = target.exists ? try? Data(contentsOf: mapFile(target.id)) : nil
        if target.exists, original == nil { throw Failure(message: "\(mapPath(target.id)) can't be read.") }

        let targets = linkTargets()
        let titles = noteTitles()
        let labels = MapGraph.labels(in: scene)
        var links: [KnowledgeInbox.MapPlan.Link] = [], unlinked: [KnowledgeInbox.MapPlan.Unlinked] = []
        for shape in scene.live where !["text", "arrow", "line", "freedraw"].contains(shape.type) {
            guard let label = labels[shape.id], shape.link?.isEmpty ?? true else { continue }
            switch KnowledgeInbox.match(label: label, map: target.id, targets: targets, titles: titles) {
            case .note(let note):
                links.append(.init(element: shape.id, label: label, note: note,
                                   link: KnowledgeInbox.shortestLink(to: note, map: target.id, targets: targets)))
            case .ambiguous(let ids): unlinked.append(.init(element: shape.id, label: label, candidates: ids))
            case .none: unlinked.append(.init(element: shape.id, label: label, candidates: []))
            }
        }

        let new = KnowledgeInbox.outline(scene)
        var changes: [String] = []
        if let original, case .success(let old) = ExcalidrawFile.parse(original) {
            let before = KnowledgeInbox.outline(old)
            for (kind, now, then) in [("block", new.blocks, before.blocks), ("arrow", new.arrows, before.arrows)] {
                changes += then.filter { !now.contains($0) }.map { "- \(kind) \($0)" }
                changes += now.map { (then.contains($0) ? "  " : "+ ") + "\(kind) \($0)" }
            }
        } else {
            changes = new.blocks.map { "+ block \($0)" } + new.arrows.map { "+ arrow \($0)" }
        }
        return KnowledgeInbox.MapPlan(proposal: proposal, map: target.id, mapPath: mapPath(target.id), draft: draft, original: original,
                                      newArea: target.newArea, links: links, unlinked: unlinked, changes: changes)
    }

    /// Saves an accepted map: `bytes` are the canvas's own serialization of the draft with its
    /// links (core never builds them). The commit queue is flushed first (U2); the map must still
    /// be as planned (a new map still absent, a replaced one still hashing to what the plan read),
    /// the proposal and the draft unchanged; a replaced map is backed up. Then the map is written
    /// (a new area's folder too), the proposal, its draft and its marks are removed, and one commit
    /// holds the map. On a commit failure everything is put back.
    @discardableResult
    public func acceptMap(_ plan: KnowledgeInbox.MapPlan, bytes: Data, env: HarnessEnvironment, now: Date = .now) async throws(Failure) -> KnowledgeInbox.MapAccepted {
        let scene: ExcalidrawFile
        switch ExcalidrawFile.parse(bytes) {
        case .success(let read): scene = read
        case .failure(let failure): throw Failure(message: "The map to save is \(failure.message); nothing was written.")
        }
        if scene.elements.flatMap({ [$0.text ?? "", $0.link ?? ""] }).contains(where: KnowledgeInbox.hasSecret) {
            throw Failure(message: "The map holds what looks like a secret (a token, a key or a password); nothing was written.")
        }
        _ = await KnowledgeCommitQueue(base: root, env: env).flush()
        let file = mapFile(plan.map)
        let proposalFile = root.appending(path: plan.proposal.path)
        let draftPath = KnowledgeInbox.draftPath(of: plan.proposal.id)
        let draftFile = root.appending(path: draftPath)
        guard (try? Data(contentsOf: file)) == plan.original else {
            throw Failure(message: "\(plan.mapPath) changed after the proposal was planned; nothing was written. Look at it again.")
        }
        guard let proposalData = try? Data(contentsOf: proposalFile),
              KnowledgeProposal.parse(String(decoding: proposalData, as: UTF8.self)) == plan.proposal,
              (try? Data(contentsOf: draftFile)) == plan.draft else {
            throw Failure(message: "\(plan.proposal.path) or its draft changed or is gone; nothing was written.")
        }
        let fm = FileManager.default
        var backup: URL?
        if let original = plan.original {
            do { backup = try backupNote(original, path: plan.mapPath, home: env.homeDirectory, now: now) } catch {
                throw Failure(message: "Couldn't back up \(plan.mapPath) (\(error.localizedDescription)); nothing was written.")
            }
        }
        let keep = root.appending(path: KnowledgeInbox.keepFile)
        let addsKeep = !fm.fileExists(atPath: keep.path)
        let createdFolder = fm.fileExists(atPath: file.deletingLastPathComponent().path) ? nil : file.deletingLastPathComponent()
        func putBack() {
            if let original = plan.original { try? original.write(to: file, options: .atomic) } else { try? fm.removeItem(at: file) }
            // The maps/ folder it made, and the area too when it was new, while they are empty.
            for folder in [createdFolder, plan.newArea ? createdFolder?.deletingLastPathComponent() : nil].compactMap(\.self)
            where (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? fm.removeItem(at: folder)
            }
            if addsKeep { try? fm.removeItem(at: keep) }
            try? fm.createDirectory(at: inboxFolder, withIntermediateDirectories: true)
            try? proposalData.write(to: proposalFile, options: .atomic)
            try? plan.draft.write(to: draftFile, options: .atomic)
        }
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: plan.original == nil ? .withoutOverwriting : .atomic)
            if addsKeep { try Data().write(to: keep) }
            try fm.removeItem(at: proposalFile)
            try fm.removeItem(at: draftFile)
        } catch {
            putBack()
            throw Failure(message: "Couldn't write \(plan.mapPath) (\(error.localizedDescription)); the map and the proposal are as they were.")
        }
        let paths = [plan.mapPath, plan.proposal.path, draftPath] + (addsKeep ? [KnowledgeInbox.keepFile] : [])
        let message = (plan.original == nil ? "Add map \(plan.map)" : "Replace map \(plan.map)") + " (accept proposal \(plan.proposal.id))"
        do { try await KnowledgeGit(base: root, env: env).commit(paths: paths, message: message) } catch {
            putBack()
            throw Failure(message: "Couldn't commit the accepted map (\(error.message)); the map and the proposal are as they were.")
        }
        removeCheck(of: plan.proposal.id)
        return KnowledgeInbox.MapAccepted(plan: plan, paths: [plan.mapPath] + (addsKeep ? [KnowledgeInbox.keepFile] : []), backup: backup)
    }
}
