import AKitBrain
import AKitFoundation
import Foundation

/// The focus of a project (K5, K12, K24): the area its sessions start from, never a wall. In this
/// order: the person's choice in `focus.json` (`akit kb focus --set`, AKit's Focus…); the first
/// area (by name) whose `area.yaml` `projects:` names the folder's remote, a `~/` path of the
/// folder or a glob that matches it; the area of the first note (by id) whose `repo:` is the
/// folder's remote or its `~/` path. Remotes are compared through `ProjectRecords.normalizedRemote`.
extension KnowledgeBase {
    public struct FocusChoice: Encodable, Equatable, Sendable {
        public enum Source: String, Encodable, Sendable {
            /// `focus.json`: the person chose it.
            case override
            /// An area's `area.yaml` names the project.
            case areaSettings = "area.yaml"
            /// A note's `repo:` is the project.
            case repo
        }

        /// nil when nothing names the folder.
        public let area: String?
        public let source: Source?

        public init(area: String?, source: Source?) {
            self.area = area
            self.source = source
        }

        public static let none = FocusChoice(area: nil, source: nil)
    }

    /// The focus of a folder whose `origin` remote is `remote` (nil without one). `override` is
    /// the area `focus.json` sets; an override naming an area the base doesn't have is ignored.
    public func focus(remote: String?, folder: URL, home: URL, override: String? = nil) -> FocusChoice {
        let areas = areas()
        if let override = override.map(Self.nfc), areas.contains(where: { $0.name == override }) {
            return FocusChoice(area: override, source: .override)
        }
        let remote = remote.flatMap(ProjectRecords.normalizedRemote)
        func names(_ project: String) -> Bool { Self.names(project: project, remote: remote, folder: folder, home: home) }
        if let area = areas.first(where: { $0.projects.contains(where: names) }) {
            return FocusChoice(area: area.name, source: .areaSettings)
        }
        let notes = (try? self.notes()) ?? []
        if let note = notes.first(where: { entry in KnowledgeNote.load(root.appending(path: entry.path))?.repo.map(names) == true }) {
            return FocusChoice(area: note.area, source: .repo)
        }
        return .none
    }

    /// The focus of `folder`: its project id (as `focus.json` keys it), and the choice.
    public func focus(folder: URL, env: HarnessEnvironment, projectsRoot: URL) async -> (project: String, choice: FocusChoice) {
        let id = await ProjectRecords.projectID(for: folder, projectsRoot: projectsRoot, env: env)
        let home = env.homeDirectory
        // `projectID` is the normalized remote when the folder has one, else `local/…`.
        let remote = id.hasPrefix("local/") ? nil : id
        let override = Focus.load(home: home).projects[id]?.area
        return (id, focus(remote: remote, folder: folder, home: home, override: override))
    }

    /// `project` (an `area.yaml` `projects:` entry or a note's `repo:`) names the repository whose
    /// normalized `origin` is `remote` (`ProjectRecords.normalizedRemote`), checked out in
    /// `folder`: a `~/` or absolute path (maybe a glob) matches the folder, anything else is a
    /// remote compared normalized. A path never matches without a folder, a remote never without one.
    public static func names(project: String, remote: String?, folder: URL?, home: URL) -> Bool {
        let project = project.trimmingCharacters(in: .whitespaces)
        if project.hasPrefix("~") || project.hasPrefix("/") { return folder.map { matches(path: project, folder: $0, home: home) } ?? false }
        return remote != nil && ProjectRecords.normalizedRemote(project) == remote
    }

    /// `pattern` (a `~/` or absolute path, maybe a glob) names `folder` or a folder it is in.
    /// Both sides are tried as written and with links resolved (`/tmp` → `/private/tmp`).
    public static func matches(path pattern: String, folder: URL, home: URL) -> Bool {
        var pattern = pattern
        while pattern.count > 1, pattern.hasSuffix("/") { pattern.removeLast() }
        let homes = Set([home.standardized.path, resolved(home)])
        let patterns: [String] = pattern == "~" ? Array(homes)
            : pattern.hasPrefix("~/") ? homes.map { $0 + pattern.dropFirst(1) } : [pattern]
        var folders: Set<String> = []
        for start in [folder.standardized.path, resolved(folder)] {
            var path = start
            while !path.isEmpty, path != "/" {
                folders.insert(path)
                path = (path as NSString).deletingLastPathComponent
            }
        }
        return patterns.contains { pattern in folders.contains { fnmatch(pattern, $0, FNM_PATHNAME) == 0 } }
    }
}

extension KnowledgeBase.Focus {
    /// Writes `focus.json` atomically (machine-local, never in a base or the brain).
    public func save(home: URL) throws(KnowledgeBase.Failure) {
        let file = KnowledgeBase.focusFile(home: home)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (encoder.encode(self) + Data("\n".utf8)).write(to: file, options: .atomic)
        } catch {
            throw KnowledgeBase.Failure(message: "Couldn't write \(file.path): \(error.localizedDescription)")
        }
    }

    /// Sets the focus area of a project together with the base it is in, so the project's
    /// commands (and its agents) read that base; nil clears both.
    public func setting(area: String?, project: String, in base: KnowledgeBase) -> KnowledgeBase.Focus {
        var copy = self
        copy.projects[project] = area.map { Entry(base: base.world ?? base.root.path, area: $0) }
        return copy
    }
}

// MARK: - neighbors and context (agent reads, K19)

extension KnowledgeIndex {
    public struct NeighborsAnswer: Encodable, Equatable, Sendable {
        public let note: String
        /// The arrows touching the note (depth 1), then those touching its neighbours (depth 2).
        public var edges: [MapGraph.Edge]
        /// Edges were left out to stay under `--max-tokens`.
        public var truncated: Bool
        public let stale: Bool
        public var tokens = 0
    }

    public struct ContextSystem: Encodable, Equatable, Sendable {
        public let note: String
        public let title: String
        /// The frontmatter `description`, else the first sentence of the note's text.
        public let line: String
        /// The system's folder on this Mac (K27), left out when it has none.
        public var local: String? = nil
    }

    public struct ContextRelation: Encodable, Equatable, Sendable {
        public let from: String
        public let kind: String?
        public let to: String

        private enum CodingKeys: String, CodingKey { case from, kind, to }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(from, forKey: .from)
            try container.encode(kind, forKey: .kind) // null without a label
            try container.encode(to, forKey: .to)
        }
    }

    public struct ContextAnswer: Encodable, Equatable, Sendable {
        public let base: String
        public let focus: String?
        /// The notes of the focus area, then their neighbours in other areas (one arrow away).
        public var systems: [ContextSystem]
        /// The arrows touching a note of the focus area (one per from, kind, to).
        public var relations: [ContextRelation]
        /// Systems or relations were left out to stay under `--max-tokens`.
        public var truncated: Bool
        public let stale: Bool
        public var tokens = 0

        private enum CodingKeys: String, CodingKey { case base, focus, systems, relations, truncated, stale, tokens }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(base, forKey: .base)
            try container.encode(focus, forKey: .focus) // null without a focus
            try container.encode(systems, forKey: .systems)
            try container.encode(relations, forKey: .relations)
            try container.encode(truncated, forKey: .truncated)
            try container.encode(stale, forKey: .stale)
            try container.encode(tokens, forKey: .tokens)
        }
    }

    /// The arrows to and from a note on every map, read from the index; with `depth` 2 also the
    /// arrows of the notes one arrow away. Cut from the end to stay under `maxTokens`.
    public func neighbors(_ name: String, depth: Int = 1, maxTokens: Int = Budget.defaultTokens) throws(Failure) -> NeighborsAnswer {
        let id: String
        do { id = try base.noteID(name) } catch { throw Failure(message: error.message) }
        let opened = try prepare(rebuild: false)
        var edges: [MapGraph.Edge] = []
        if let database = opened.database {
            do {
                let all = try Self.edges(database)
                var near: Set<String> = [id]
                for round in 1...max(1, min(depth, 2)) {
                    let found = all.filter { edge in (near.contains(edge.from) || near.contains(edge.to)) && !edges.contains(edge) }
                    edges += found
                    if round == 1 { near.formUnion(found.flatMap { [$0.from, $0.to] }) }
                }
            } catch {
                throw failure(error)
            }
        }
        var answer = NeighborsAnswer(note: id, edges: edges, truncated: false, stale: opened.stale)
        while Budget.measure(&answer, field: \.tokens) > maxTokens, !answer.edges.isEmpty {
            answer.edges.removeLast()
            answer.truncated = true
        }
        return answer
    }

    /// The card an agent reads at the start of a task (K19): the notes of `focus` (title and one
    /// line, and with `local` its folder on this Mac), the arrows touching them, and their
    /// neighbours in other areas. Cut to `maxTokens`:
    /// first the other areas' notes, then relations, then the focus area's notes, from the end.
    public func context(focus: String?, maxTokens: Int = Budget.defaultTokens, local: KnowledgeLocal? = nil) throws(Failure) -> ContextAnswer {
        let opened = try prepare(rebuild: false)
        var systems: [ContextSystem] = [], others: [ContextSystem] = [], relations: [ContextRelation] = []
        if let database = opened.database, let focus = focus.map(KnowledgeBase.nfc) {
            do {
                var titles: [String: String] = [:]
                for row in try database.rows("SELECT id, title FROM notes") { titles[row[0].text ?? ""] = row[1].text ?? "" }
                func system(_ id: String) -> ContextSystem {
                    let note = KnowledgeNote.load(base.noteFile(id))
                    return ContextSystem(note: id, title: titles[id] ?? id, line: note.map(Self.line) ?? "",
                                         local: note.flatMap { local?.label(of: $0) })
                }
                systems = titles.keys.filter { Self.area(of: $0) == focus }.sorted().map(system)
                var neighbours: Set<String> = []
                for edge in try Self.edges(database) where Self.area(of: edge.from) == focus || Self.area(of: edge.to) == focus {
                    let relation = ContextRelation(from: edge.from, kind: edge.kind, to: edge.to)
                    if !relations.contains(relation) { relations.append(relation) }
                    for end in [edge.from, edge.to] where Self.area(of: end) != focus { neighbours.insert(end) }
                }
                others = neighbours.sorted().map(system)
            } catch {
                throw failure(error)
            }
        }
        var answer = ContextAnswer(base: base.root.path, focus: focus, systems: systems + others, relations: relations,
                                   truncated: false, stale: opened.stale)
        var otherCount = others.count
        while Budget.measure(&answer, field: \.tokens) > maxTokens {
            answer.truncated = true
            if otherCount > 0 {
                answer.systems.removeLast()
                otherCount -= 1
            } else if !answer.relations.isEmpty {
                answer.relations.removeLast()
            } else if !answer.systems.isEmpty {
                answer.systems.removeLast()
            } else {
                break
            }
        }
        return answer
    }

    /// Every arrow between two notes on any map, read from the index (refreshed first), in map
    /// and arrow order; `stale` when another process holds the index lock.
    public func edges() throws(Failure) -> (edges: [MapGraph.Edge], stale: Bool) {
        let opened = try prepare(rebuild: false)
        guard let database = opened.database else { return ([], opened.stale) }
        do {
            return (try Self.edges(database), opened.stale)
        } catch {
            throw failure(error)
        }
    }

    /// Every edge of the index, in map and arrow order.
    private static func edges(_ database: SQLiteDatabase) throws -> [MapGraph.Edge] {
        try database.rows("SELECT from_note, to_note, kind, flow, map, arrow FROM edges ORDER BY map, arrow").map { row in
            MapGraph.Edge(from: row[0].text ?? "", to: row[1].text ?? "", kind: row[2].text, flow: row[3].text,
                          map: row[4].text ?? "", arrow: row[5].text ?? "")
        }
    }

    /// A note's one line: its frontmatter `description`, else the first sentence of its first
    /// paragraph of text (the title left out), at most 200 characters.
    public static func line(of note: KnowledgeNote) -> String {
        let value = note.frontmatter["description"]
        if let description = value.map({ "\($0)".trimmingCharacters(in: .whitespacesAndNewlines) }),
           !description.isEmpty, !(value is NSNull) {
            return clip(description)
        }
        guard let text = chunks(of: note).map(\.text).first(where: { !$0.isEmpty }) else { return "" }
        let paragraph = text.components(separatedBy: "\n\n")[0].split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        var end = paragraph.endIndex
        var index = paragraph.startIndex
        while index < paragraph.endIndex {
            let next = paragraph.index(after: index)
            if ".!?".contains(paragraph[index]), next == paragraph.endIndex || paragraph[next] == " " {
                end = next
                break
            }
            index = next
        }
        return clip(String(paragraph[..<end]))
    }

    private static func clip(_ text: String) -> String {
        text.count <= 200 ? text : String(text.prefix(199)) + "…"
    }
}
