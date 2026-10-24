import AKitFoundation
import Foundation

/// What a change provides or uses across the repository's edge (R41, `<run>/boundaries.json`).
/// The brief names it with `akit_submit_boundaries`; AKit keeps it only when its quote is in a
/// file the change touches, at the reviewed commit.
public struct ReviewBoundary: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case httpAPI = "http-api", graphql, mfe, sharedLib = "shared-lib", event, dbSchema = "db-schema", infra, ci, config
    }

    public enum Direction: String, Codable, Sendable { case provides, uses }

    /// `b1`, `b2`, … in the order the brief named them.
    public var id: String
    public var kind: Kind
    public var direction: Direction
    /// What to search for in other repositories (at most 120 characters).
    public var name: String
    public var file: String
    /// Moved to the quote's line when the brief's line doesn't hold it.
    public var line: Int?
    public var quote: String
    public var note: String

    public init(id: String, kind: Kind, direction: Direction, name: String, file: String, line: Int?, quote: String, note: String = "") {
        self.id = id
        self.kind = kind
        self.direction = direction
        self.name = name
        self.file = file
        self.line = line
        self.quote = quote
        self.note = note
    }
}

/// One use of a boundary in another repository (R43, `<run>/consumers.json`), written by the
/// `impact` pass and read onto the map.
public struct ReviewConsumer: Codable, Sendable, Hashable {
    /// The `ReviewBoundary.id` it uses.
    public var boundary: String
    /// The other project's path in GitLab (`group/project`).
    public var project: String
    public var file: String
    /// The branch or commit the file was read at.
    public var ref: String?
    public var line: Int?
    public var quote: String
    /// How the file uses the boundary.
    public var usage: String
    /// Whether this change breaks the use.
    public var breaks: Bool
    public var why: String
    /// The file's GitLab link.
    public var url: String?

    public init(boundary: String, project: String, file: String, ref: String? = nil, line: Int? = nil, quote: String, usage: String,
                breaks: Bool = false, why: String = "", url: String? = nil) {
        self.boundary = boundary
        self.project = project
        self.file = file
        self.ref = ref
        self.line = line
        self.quote = quote
        self.usage = usage
        self.breaks = breaks
        self.why = why
        self.url = url
    }
}

/// AKit's check of the brief's boundaries (`<run>/passes/boundaries.json` → `boundaries.json`).
public enum ReviewBoundaries {
    static let maxName = 120

    /// The submitted boundaries whose file the change touches and whose quote is in that file at
    /// the reviewed commit. Model text is masked. Without a worktree nothing can be checked, so
    /// nothing is kept.
    static func check(folder: URL, worktree: URL?) -> [ReviewBoundary] {
        guard let object = FileWalk.jsonObject(folder.appending(path: "passes/boundaries.json")) else { return [] }
        let changed = Set((ReviewJSON.read(ReviewSnapshot.self, from: folder.appending(path: "gitlab/snapshot.json"))?.diffs ?? [])
            .filter { !$0.deletedFile }.map(\.newPath))
        return check(object["boundaries"] as? [[String: Any]] ?? [], changed: changed, worktree: worktree)
    }

    static func check(_ raw: [[String: Any]], changed: Set<String>, worktree: URL?) -> [ReviewBoundary] {
        var result: [ReviewBoundary] = []
        for item in raw {
            guard let kind = (item["kind"] as? String).flatMap(ReviewBoundary.Kind.init),
                  let direction = (item["direction"] as? String).flatMap(ReviewBoundary.Direction.init),
                  let rawFile = item["file"] as? String, let rawQuote = item["quote"] as? String else { continue }
            let file = rawFile.hasPrefix("./") ? String(rawFile.dropFirst(2)) : rawFile
            let name = String(SecretFilter.masked(item["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxName))
            let quote = SecretFilter.masked(rawQuote)
            guard !name.isEmpty, changed.contains(file), let lines = ReviewCandidates.fileLines(file, worktree: worktree),
                  let hits = ReviewCandidates.quoteHits(ReviewNotes.defused(quote), in: lines), let first = hits.first else { continue }
            var line = (item["line"] as? NSNumber).flatMap { $0.intValue >= 1 ? $0.intValue : nil }
            if line.map({ given in !hits.contains { abs($0 + 1 - given) <= 3 } }) ?? true { line = first + 1 }
            result.append(ReviewBoundary(id: "b\(result.count + 1)", kind: kind, direction: direction, name: name, file: file, line: line,
                                         quote: quote, note: SecretFilter.masked(item["note"] as? String ?? "")))
        }
        return result
    }
}

/// The change map of a run (R40, `<run>/map.json`): three lanes left to right. **This change**:
/// the changed files grouped by module, with their lines and the worst severity of their
/// findings, and faded, the unchanged files that import them. **Boundaries**: what the change
/// provides or uses across the repository's edge. **Other repositories**: the projects and
/// files that use a boundary. For the user only; never posted.
public struct ReviewMap: Codable, Sendable, Hashable {
    public enum Lane: String, Codable, Sendable, CaseIterable { case change, boundaries, others }

    public enum NodeKind: String, Codable, Sendable {
        /// The nearest folder with `package.json`, else the top folder, of changed files.
        case module
        case file
        /// An unchanged file of this repository that imports a changed file (faded).
        case dependent
        case boundary
        /// Another repository.
        case project
        /// A file of another repository that uses a boundary.
        case consumer
    }

    public struct Node: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var kind: NodeKind
        public var lane: Lane
        public var label: String
        /// The repository path of a file, module or dependent; a consumer's path in its project.
        public var path: String?
        /// The module of a file, the project of a consumer.
        public var parent: String?
        public var added: Int?
        public var removed: Int?
        /// `added`, `deleted`, `renamed` or `modified`, for a changed file.
        public var status: String?
        /// The worst final severity of the node's findings (not rejected, merged or older than the change).
        public var severity: ReviewSeverity?
        /// The ids of those findings.
        public var findings: [String]?
        public var boundary: ReviewBoundary?
        public var consumers: [ReviewConsumer]?
        /// A consumer or project that this change breaks.
        public var breaks: Bool?

        public init(id: String, kind: NodeKind, lane: Lane, label: String, path: String? = nil, parent: String? = nil) {
            self.id = id
            self.kind = kind
            self.lane = lane
            self.label = label
            self.path = path
            self.parent = parent
        }
    }

    public struct Edge: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable {
            /// `from` imports `to`.
            case imports
            /// The file `from` holds the boundary `to`.
            case declares
            /// The boundary `from` is used by the consumer `to`.
            case usedBy
        }

        public var from: String
        public var to: String
        public var kind: Kind
        public var breaks: Bool?

        public init(from: String, to: String, kind: Kind, breaks: Bool? = nil) {
            self.from = from
            self.to = to
            self.kind = kind
            self.breaks = breaks
        }
    }

    public var created: Date
    public var nodes: [Node]
    public var edges: [Edge]
    /// Why the map may miss imports: files over the scan's limit, dependents left out.
    public var notes: [String]

    public init(created: Date = .now, nodes: [Node] = [], edges: [Edge] = [], notes: [String] = []) {
        self.created = created
        self.nodes = nodes
        self.edges = edges
        self.notes = notes
    }

    public func nodes(in lane: Lane) -> [Node] { nodes.filter { $0.lane == lane } }

    // MARK: - Building

    static let maxDependents = 200

    /// The map of a run folder: the changed files of `gitlab/snapshot.json`, the findings of
    /// `findings.json`, `boundaries.json`, `consumers.json`, and the imports read in `worktree/`.
    public static func make(folder: URL) throws -> ReviewMap {
        guard let snapshot = ReviewJSON.read(ReviewSnapshot.self, from: folder.appending(path: "gitlab/snapshot.json")) else {
            throw ReviewPasses.Failure(message: "\(folder.lastPathComponent) has no gathered diff.")
        }
        let worktree = folder.appending(path: "worktree")
        let hasWorktree = FileManager.default.fileExists(atPath: worktree.appending(path: ".git").path)
        return make(diffs: snapshot.diffs, worktree: hasWorktree ? worktree : nil,
                    findings: ReviewJSON.read(ReviewFindingsFile.self, from: folder.appending(path: "findings.json"))?.findings ?? [],
                    boundaries: ReviewJSON.read([ReviewBoundary].self, from: folder.appending(path: "boundaries.json")) ?? [],
                    consumers: ReviewJSON.read([ReviewConsumer].self, from: folder.appending(path: "consumers.json")) ?? [])
    }

    static func make(diffs: [GitLabFileDiff], worktree: URL?, findings: [ReviewFinding], boundaries: [ReviewBoundary],
                     consumers: [ReviewConsumer], limits: ReviewImports.Limits = .init()) -> ReviewMap {
        var map = ReviewMap()
        let changed = diffs.map(\.newPath)
        let severities = worstSeverities(findings)

        // This change: modules, then their files.
        var modules: [String: [GitLabFileDiff]] = [:]
        for diff in diffs { modules[module(of: diff.newPath, worktree: worktree), default: []].append(diff) }
        for name in modules.keys.sorted() {
            let files = modules[name, default: []].sorted { $0.newPath < $1.newPath }
            var module = Node(id: "module:\(name)", kind: .module, lane: .change, label: name == "." ? "(root)" : name + "/", path: name)
            var fileNodes: [Node] = []
            for diff in files {
                let counts = lineCounts(diff)
                var node = Node(id: "file:\(diff.newPath)", kind: .file, lane: .change,
                                label: name == "." ? diff.newPath : String(diff.newPath.dropFirst(name.count + 1)), path: diff.newPath, parent: module.id)
                node.added = counts.added
                node.removed = counts.removed
                node.status = diff.newFile ? "added" : diff.deletedFile ? "deleted" : diff.renamedFile ? "renamed" : "modified"
                if let found = severities[diff.newPath] {
                    node.severity = found.severity
                    node.findings = found.ids
                }
                fileNodes.append(node)
            }
            module.added = fileNodes.compactMap(\.added).reduce(0, +)
            module.removed = fileNodes.compactMap(\.removed).reduce(0, +)
            module.severity = fileNodes.compactMap(\.severity).max()
            let ids = fileNodes.flatMap { $0.findings ?? [] }
            module.findings = ids.isEmpty ? nil : ids
            map.nodes.append(module)
            map.nodes += fileNodes
        }

        // Imports: between changed files, and unchanged files that import a changed one.
        if let worktree {
            let graph = ReviewImports.scan(worktree: worktree, changed: Set(changed), limits: limits)
            map.notes = graph.notes
            for edge in graph.edges.sorted(by: { ($0.from, $0.to) < ($1.from, $1.to) }) {
                map.edges.append(Edge(from: "file:\(edge.from)", to: "file:\(edge.to)", kind: .imports))
            }
            let dependents = graph.dependents.keys.sorted()
            for path in dependents.prefix(maxDependents) {
                map.nodes.append(Node(id: "dependent:\(path)", kind: .dependent, lane: .change, label: path, path: path))
                for target in graph.dependents[path, default: []].sorted() {
                    map.edges.append(Edge(from: "dependent:\(path)", to: "file:\(target)", kind: .imports))
                }
            }
            if dependents.count > maxDependents {
                map.notes.append("\(dependents.count - maxDependents) more unchanged files import the change; the map shows \(maxDependents).")
            }
        }

        // Boundaries.
        let fileIDs = Set(map.nodes.map(\.id))
        for boundary in boundaries {
            var node = Node(id: "boundary:\(boundary.id)", kind: .boundary, lane: .boundaries,
                            label: "\(boundary.direction.rawValue) \(boundary.kind.rawValue): \(boundary.name)", path: boundary.file)
            node.boundary = boundary
            map.nodes.append(node)
            if fileIDs.contains("file:\(boundary.file)") {
                map.edges.append(Edge(from: "file:\(boundary.file)", to: node.id, kind: .declares))
            }
        }

        // Other repositories: a project, its files that use a boundary.
        let boundaryIDs = Set(boundaries.map(\.id))
        let byProject = Dictionary(grouping: consumers, by: \.project)
        for project in byProject.keys.sorted() {
            let uses = byProject[project, default: []]
            var projectNode = Node(id: "project:\(project)", kind: .project, lane: .others, label: project, path: project)
            projectNode.consumers = uses
            projectNode.breaks = uses.contains(where: \.breaks) ? true : nil
            map.nodes.append(projectNode)
            let byFile = Dictionary(grouping: uses, by: \.file)
            for file in byFile.keys.sorted() {
                let fileUses = byFile[file, default: []]
                var node = Node(id: "consumer:\(project):\(file)", kind: .consumer, lane: .others, label: file, path: file, parent: projectNode.id)
                node.consumers = fileUses
                node.breaks = fileUses.contains(where: \.breaks) ? true : nil
                map.nodes.append(node)
                for boundary in Set(fileUses.map(\.boundary)).sorted() where boundaryIDs.contains(boundary) {
                    let breaks = fileUses.contains { $0.boundary == boundary && $0.breaks }
                    map.edges.append(Edge(from: "boundary:\(boundary)", to: node.id, kind: .usedBy, breaks: breaks ? true : nil))
                }
            }
        }
        return map
    }

    /// Per file: the worst final severity of its findings and their ids. Findings the verifier
    /// rejected or merged, and those already there before the change, don't count.
    static func worstSeverities(_ findings: [ReviewFinding]) -> [String: (severity: ReviewSeverity, ids: [String])] {
        var result: [String: (severity: ReviewSeverity, ids: [String])] = [:]
        for finding in findings where finding.kind != .ac && !finding.isPreExisting {
            guard let file = finding.file else { continue }
            if let verdict = finding.verifier?.verdict, verdict == .rejected || verdict == .merged { continue }
            if let known = result[file] {
                result[file] = (max(known.severity, finding.finalSeverity), known.ids + [finding.id])
            } else {
                result[file] = (finding.finalSeverity, [finding.id])
            }
        }
        return result
    }

    static func lineCounts(_ diff: GitLabFileDiff) -> (added: Int, removed: Int) {
        let lines = diff.diff.split(separator: "\n", omittingEmptySubsequences: false)
        return (lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count, lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count)
    }

    /// The nearest folder of `path` with a `package.json` in the worktree, else its top folder
    /// (`.` for a file at the top). String paths and a bound: never a walk past the top.
    static func module(of path: String, worktree: URL?) -> String {
        let parts = path.split(separator: "/").map(String.init)
        let top = parts.count > 1 ? parts[0] : "."
        guard let worktree, !parts.contains("..") else { return top }
        var folder = (path as NSString).deletingLastPathComponent
        for _ in 0...parts.count {
            let manifest = folder.isEmpty ? "package.json" : folder + "/package.json"
            if FileManager.default.fileExists(atPath: worktree.appending(path: manifest).path) { return folder.isEmpty ? "." : folder }
            if folder.isEmpty { break }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return top
    }

    // MARK: - Files

    /// `<run>/map.json`; when it is missing and the run has a worktree, the map is built and
    /// saved now. nil: no map and nothing to build one from.
    public static func load(folder: URL) -> ReviewMap? {
        if let map = ReviewJSON.read(ReviewMap.self, from: folder.appending(path: "map.json")) { return map }
        guard FileManager.default.fileExists(atPath: folder.appending(path: "worktree/.git").path),
              let map = try? make(folder: folder) else { return nil }
        try? map.save(in: folder)
        return map
    }

    public func save(in folder: URL) throws {
        try ReviewJSON.write(self, to: folder.appending(path: "map.json"))
    }

    // MARK: - Text

    /// A `flowchart LR` with the three lanes as subgraphs, modules and projects inside them.
    public var mermaid: String {
        var ids: [String: String] = [:]
        for (index, node) in nodes.enumerated() { ids[node.id] = "n\(index + 1)" }
        var lines = ["flowchart LR"]
        func text(_ node: Node) -> String {
            var text = node.label
            if node.kind == .file || node.kind == .module, let added = node.added, let removed = node.removed { text += " +\(added) −\(removed)" }
            if let severity = node.severity { text += " · \(severity.rawValue)" }
            if node.kind == .project, let uses = node.consumers { text += " · \(uses.count) use\(uses.count == 1 ? "" : "s")" }
            if node.breaks == true { text += " · breaks" }
            return "\"\(Self.escaped(text))\""
        }
        let lanes: [(lane: Lane, id: String, title: String)] = [(.change, "change", "This change"), (.boundaries, "boundaries", "Boundaries"),
                                                                (.others, "others", "Other repositories")]
        for lane in lanes {
            lines.append("  subgraph \(lane.id)[\"\(lane.title)\"]")
            // A module or a project is a subgraph of its files.
            for node in nodes(in: lane.lane) where node.parent == nil {
                guard let id = ids[node.id] else { continue }
                if node.kind == .module || node.kind == .project {
                    lines.append("    subgraph g\(id)[\(text(node))]")
                    for child in nodes where child.parent == node.id {
                        if let childID = ids[child.id] { lines.append("      \(childID)[\(text(child))]") }
                    }
                    lines.append("    end")
                } else {
                    lines.append("    \(id)[\(text(node))]")
                }
            }
            lines.append("  end")
        }
        for edge in edges {
            guard let from = ids[edge.from], let to = ids[edge.to] else { continue }
            let dependent = edge.from.hasPrefix("dependent:")
            lines.append("  \(from) \(edge.breaks == true ? "== breaks ==>" : dependent ? "-.->" : "-->") \(to)")
        }
        let faded = nodes.filter { $0.kind == .dependent }.compactMap { ids[$0.id] }
        if !faded.isEmpty {
            lines.append("  classDef dependent stroke-dasharray: 3 3,opacity:0.6")
            lines.append("  class \(faded.joined(separator: ",")) dependent")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A Mermaid label: no character that ends the label or starts markup.
    static func escaped(_ text: String) -> String {
        var result = ""
        for character in text.replacingOccurrences(of: "\n", with: " ") {
            switch character {
            case "#": result += "#35;"
            case "\"": result += "#quot;"
            case "[": result += "#91;"
            case "]": result += "#93;"
            case "(": result += "#40;"
            case ")": result += "#41;"
            case "{": result += "#123;"
            case "}": result += "#125;"
            case "<": result += "#lt;"
            case ">": result += "#gt;"
            case "`": result += "#96;"
            case "|": result += "#124;"
            default: result.append(character)
            }
        }
        return result
    }

    /// The map as a listing by lane, for a terminal.
    public var text: String {
        func severity(_ node: Node) -> String { node.severity.map { "  ● \($0.rawValue)" } ?? "" }
        func counts(_ node: Node) -> String { node.added.map { "  +\($0) −\(node.removed ?? 0)" } ?? "" }
        var lines = ["This change"]
        for module in nodes.filter({ $0.kind == .module }) {
            lines.append("  \(module.label)\(counts(module))\(severity(module))")
            for file in nodes.filter({ $0.parent == module.id }) {
                lines.append("    \(file.label)\(counts(file))\(severity(file))\(file.status.map { $0 == "modified" ? "" : "  (\($0))" } ?? "")")
            }
        }
        let dependents = nodes.filter { $0.kind == .dependent }
        if !dependents.isEmpty {
            lines.append("  Unchanged files that import it")
            for node in dependents {
                let targets = edges.filter { $0.from == node.id }.map { String($0.to.dropFirst("file:".count)) }
                lines.append("    ┄ \(node.label) → \(targets.joined(separator: ", "))")
            }
        }
        lines.append("")
        lines.append("Boundaries")
        let boundaries = nodes(in: .boundaries)
        if boundaries.isEmpty { lines.append("  none found") }
        for node in boundaries {
            guard let boundary = node.boundary else { continue }
            lines.append("  \(boundary.id) \(boundary.direction.rawValue) \(boundary.kind.rawValue): \(boundary.name)  "
                         + "(\(boundary.file)\(boundary.line.map { ":\($0)" } ?? ""))")
            if !boundary.note.isEmpty { lines.append("     \(boundary.note)") }
        }
        lines.append("")
        lines.append("Other repositories")
        let projects = nodes.filter { $0.kind == .project }
        if projects.isEmpty { lines.append("  none found") }
        for project in projects {
            let uses = project.consumers ?? []
            let broken = uses.filter(\.breaks).count
            lines.append("  \(project.label)  \(uses.count) use\(uses.count == 1 ? "" : "s")\(broken > 0 ? ", \(broken) broken" : "")")
            for use in uses.sorted(by: { ($0.file, $0.line ?? 0) < ($1.file, $1.line ?? 0) }) {
                lines.append("    \(use.file)\(use.line.map { ":\($0)" } ?? "") uses \(use.boundary)\(use.breaks ? " · breaks: \(use.why)" : "")")
            }
        }
        if !notes.isEmpty {
            lines.append("")
            lines += notes.map { "Note: \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}

/// The imports of a worktree's TS/JS files, read by AKit (`import … from`, `export … from`,
/// `require()`, `import()`): relative paths and the workspace's own package names.
enum ReviewImports {
    static let extensions = ["ts", "tsx", "js", "jsx", "mjs", "cjs"]
    static let skipped: Set<String> = ["node_modules", "dist", "build", ".git"]

    struct Limits: Sendable {
        /// TS/JS files read at most.
        var files = 20_000
        /// Entries of the worktree looked at, at most.
        var entries = 200_000
        /// Larger files are skipped (bundles, generated code).
        var bytes = 1 << 20
    }

    struct Graph {
        /// A changed file imports another changed file.
        var edges: [(from: String, to: String)] = []
        /// An unchanged file → the changed files it imports.
        var dependents: [String: Set<String>] = [:]
        var notes: [String] = []
    }

    /// A workspace package: its folder and its entry files from `package.json`.
    struct Package: Sendable, Hashable {
        var folder: String
        var entries: [String]
    }

    static func isCode(_ path: String) -> Bool { extensions.contains((path as NSString).pathExtension.lowercased()) }

    static func scan(worktree: URL, changed: Set<String>, limits: Limits) -> Graph {
        var graph = Graph()
        var code: [String] = []
        var packages: [String: Package] = [:]
        var entries = 0
        let root = worktree.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        if let walker = FileManager.default.enumerator(at: worktree, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) {
            for case let url as URL in walker {
                entries += 1
                if entries > limits.entries || code.count >= limits.files {
                    graph.notes.append("The worktree has more files than AKit reads for imports; some importers may be missing.")
                    break
                }
                let values = try? url.resourceValues(forKeys: Set(keys))
                let name = url.lastPathComponent
                if values?.isDirectory == true {
                    if skipped.contains(name) || name.hasPrefix(".") { walker.skipDescendants() }
                    continue
                }
                guard values?.isSymbolicLink != true else { continue }
                let full = url.standardizedFileURL.path
                guard full.hasPrefix(root + "/") else { continue }
                let path = String(full.dropFirst(root.count + 1))
                if ReviewExtension.isBlocked(path) { continue }
                if name == "package.json", let package = package(url, folder: (path as NSString).deletingLastPathComponent, limit: limits.bytes) {
                    packages[package.name] = package.package
                } else if isCode(path), (values?.fileSize ?? 0) <= limits.bytes {
                    code.append(path)
                }
            }
        }
        let known = Set(code).union(changed)
        for path in code {
            guard let data = FileWalk.head(of: worktree.appending(path: path), limit: limits.bytes),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let targets = Set(specifiers(in: text).compactMap { resolve($0, from: path, known: known, packages: packages) })
                .intersection(changed).subtracting([path])
            guard !targets.isEmpty else { continue }
            if changed.contains(path) {
                graph.edges += targets.sorted().map { (path, $0) }
            } else {
                graph.dependents[path] = targets
            }
        }
        return graph
    }

    static func package(_ url: URL, folder: String, limit: Int) -> (name: String, package: Package)? {
        guard let object = FileWalk.jsonObject(url, limit: limit), let name = object["name"] as? String, !name.isEmpty else { return nil }
        let entries = ["source", "module", "main", "types"].compactMap { object[$0] as? String }
        return (name, Package(folder: folder, entries: entries))
    }

    static let patterns: [NSRegularExpression] = [
        #"\b(?:import|export)\s[^;'"`]*?\bfrom\s*['"]([^'"\n]+)['"]"#,
        #"\bimport\s*['"]([^'"\n]+)['"]"#,
        #"\brequire\s*\(\s*['"]([^'"\n]+)['"]\s*\)"#,
        #"\bimport\s*\(\s*['"]([^'"\n]+)['"]\s*\)"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Every module specifier the file names, in order, once each.
    static func specifiers(in text: String) -> [String] {
        guard text.contains("import") || text.contains("require") || text.contains("export") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var result: [(Int, String)] = []
        for pattern in patterns {
            for match in pattern.matches(in: text, range: range) {
                guard let found = Range(match.range(at: 1), in: text) else { continue }
                let specifier = String(text[found])
                if seen.insert(specifier).inserted { result.append((match.range.location, specifier)) }
            }
        }
        return result.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The repository path a specifier names, when it is one of `known`: a relative path, or a
    /// workspace package's name with an optional subpath. nil for anything else.
    static func resolve(_ specifier: String, from importer: String, known: Set<String>, packages: [String: Package]) -> String? {
        if specifier.hasPrefix("./") || specifier.hasPrefix("../") || specifier == "." || specifier == ".." {
            let folder = (importer as NSString).deletingLastPathComponent
            guard let base = normalized(folder.isEmpty ? specifier : folder + "/" + specifier) else { return nil }
            return file(base, known: known)
        }
        let parts = specifier.split(separator: "/").map(String.init)
        let count = specifier.hasPrefix("@") ? 2 : 1
        guard parts.count >= count, let package = packages[parts.prefix(count).joined(separator: "/")] else { return nil }
        let prefix = package.folder.isEmpty ? "" : package.folder + "/"
        let subpath = parts.dropFirst(count).joined(separator: "/")
        if subpath.isEmpty {
            for entry in package.entries {
                if let base = normalized(prefix + entry), let found = file(base, known: known) { return found }
            }
            return file(prefix + "index", known: known) ?? file(prefix + "src/index", known: known)
        }
        guard let base = normalized(prefix + subpath) else { return nil }
        return file(base, known: known) ?? normalized(prefix + "src/" + subpath).flatMap { file($0, known: known) }
    }

    /// `base` itself, with a code extension, `base.js` written for `base.ts`, or `base/index.*`.
    static func file(_ base: String, known: Set<String>) -> String? {
        var candidates = [base]
        let ext = (base as NSString).pathExtension.lowercased()
        if ["js", "jsx", "mjs", "cjs"].contains(ext) {
            let stem = (base as NSString).deletingPathExtension
            candidates += ext == "jsx" ? [stem + ".tsx"] : [stem + ".ts", stem + ".tsx"]
        }
        candidates += extensions.map { "\(base).\($0)" } + extensions.map { "\(base)/index.\($0)" }
        return candidates.first(where: known.contains)
    }

    /// `a/./b/../c` → `a/c`; nil when it leaves the repository's top.
    static func normalized(_ path: String) -> String? {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }
}
