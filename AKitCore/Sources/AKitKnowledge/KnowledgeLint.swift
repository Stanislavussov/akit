import AKitBrain
import AKitFoundation
import Foundation

/// The checks of a base (4.1): what in its notes and maps points nowhere, or at something this
/// Mac doesn't have. `akit kb lint`, the Lint tab of the Knowledge screen and the grey links of
/// the note panel all read the same findings. Only `areas/` is checked, never `inbox/`.
///
/// | Rule | Severity | Finding |
/// |---|---|---|
/// | `broken-link` | error | a `[[link]]` / `akit:` link in a note or on a map that resolves to nothing |
/// | `map-parse` | error | a `.excalidraw` file that isn't an Excalidraw scene |
/// | `ambiguous-link` | warning | a link that fits more than one note (P1) |
/// | `block-without-note` | warning | a shape on a map with a label but no link |
/// | `unbound-arrow` | warning | an arrow not bound to a block at both ends (no relation) |
/// | `unknown-repo` | warning | a note's `repo:` remote that isn't among the known projects (K12) |
/// | `missing-file` | warning | a `files:` path that the local copy of the note's repo doesn't have |
/// | `missing-home-path` | warning | a `~/` path in `repo:` or `files:`, or a `path:` folder, that doesn't exist |
/// | `unrelated-area` | hint | a block for a note of another area that no map of this area jumps to or from (R-SEP) |
/// | `unknown-kind` | hint | a note's `kind:` that `kb.yaml` doesn't list (K24) |
///
/// Known projects (K12): the `origin` remotes of the git repos in the projects root (and one
/// folder below), the project ids of the project store (the brain's `projects/` and
/// `~/.akit/local/projects/`), and the remotes in any area's `area.yaml` `projects:`. A remote is
/// compared through `ProjectRecords.normalizedRemote`; a local copy is a repo found in the
/// projects root.
public enum KnowledgeLint {
    public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
        case error, warning, hint

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    public enum Rule: String, Codable, Sendable, CaseIterable {
        case brokenLink = "broken-link"
        case mapParse = "map-parse"
        case ambiguousLink = "ambiguous-link"
        case blockWithoutNote = "block-without-note"
        case unboundArrow = "unbound-arrow"
        case unknownRepo = "unknown-repo"
        case missingFile = "missing-file"
        case missingHomePath = "missing-home-path"
        case unrelatedArea = "unrelated-area"
        case unknownKind = "unknown-kind"

        public var severity: Severity {
            switch self {
            case .brokenLink, .mapParse: .error
            case .unrelatedArea, .unknownKind: .hint
            default: .warning
            }
        }
    }

    public struct Finding: Codable, Sendable, Equatable, Hashable {
        public let rule: Rule
        public let severity: Severity
        /// Base-relative: `areas/payments/orders-api.md`, `areas/payments/maps/overview.excalidraw`.
        public let file: String
        /// The element id on a map.
        public let element: String?
        /// The link, `repo:` value or path the finding is about, as written.
        public let link: String?
        public let message: String
        /// What to do about it.
        public let fix: String?

        public init(rule: Rule, file: String, element: String? = nil, link: String? = nil, message: String, fix: String? = nil) {
            self.rule = rule
            severity = rule.severity
            self.file = file
            self.element = element
            self.link = link
            self.message = message
            self.fix = fix
        }

        /// The note id when the file is a note, else nil.
        public var note: String? {
            guard file.hasPrefix("areas/"), file.hasSuffix(".md") else { return nil }
            return String(file.dropFirst("areas/".count).dropLast(".md".count))
        }

        /// The map id when the file is a map, else nil.
        public var map: String? {
            guard file.hasPrefix("areas/"), file.hasSuffix(".excalidraw") else { return nil }
            return String(file.dropFirst("areas/".count).dropLast(".excalidraw".count))
        }
    }

    public struct Counts: Codable, Sendable, Equatable {
        public let error: Int
        public let warning: Int
        public let hint: Int
    }

    /// `akit kb lint --json`.
    public struct Answer: Encodable, Sendable {
        public let base: String
        public let findings: [Finding]
        public let counts: Counts

        public init(base: String, findings: [Finding]) {
            self.base = base
            self.findings = findings
            counts = KnowledgeLint.counts(findings)
        }
    }

    public static func counts(_ findings: [Finding]) -> Counts {
        Counts(error: findings.filter { $0.severity == .error }.count, warning: findings.filter { $0.severity == .warning }.count,
               hint: findings.filter { $0.severity == .hint }.count)
    }

    // MARK: - Known projects

    /// The projects this Mac knows (K12), for `repo:` and `files:`.
    public struct Projects: Sendable, Equatable {
        /// Normalized remotes and project ids: `example.com/shop/orders-api`.
        public var known: Set<String>
        /// Normalized remote → the folder of its local copy.
        public var copies: [String: URL]

        public init(known: Set<String> = [], copies: [String: URL] = [:]) {
            self.known = known.union(copies.keys)
            self.copies = copies
        }

        /// The repos in `projectsRoot` (and one folder below) by their `origin` remote, and the
        /// project ids of the brain's and the local project store.
        public static func find(home: URL, projectsRoot: URL, brainRoot: URL?) -> Projects {
            var copies: [String: URL] = [:]
            func look(_ folder: URL, depth: Int) {
                for child in FileWalk.children(of: folder) where FileWalk.isDirectory(child) && !child.lastPathComponent.hasPrefix(".") {
                    if FileManager.default.fileExists(atPath: child.appending(path: ".git").path) {
                        if let remote = GitCheckout.originURL(of: child), let id = ProjectRecords.normalizedRemote(remote), copies[id] == nil {
                            copies[id] = child
                        }
                    } else if depth > 0 {
                        look(child, depth: depth - 1)
                    }
                }
            }
            look(projectsRoot, depth: 1)
            var known: Set<String> = []
            let stores = [brainRoot.map(ProjectStore.brain), ProjectStore.local(home: home)].compactMap(\.self).map(\.root)
            for store in stores {
                guard let walker = FileManager.default.enumerator(at: store, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                else { continue }
                for case let file as URL in walker where ["lock.json", "answers.json"].contains(file.lastPathComponent) {
                    let folder = file.deletingLastPathComponent().standardized.path
                    let root = store.standardized.path
                    if folder.hasPrefix(root + "/") { known.insert(String(folder.dropFirst(root.count + 1)).lowercased()) }
                }
            }
            return Projects(known: known, copies: copies)
        }
    }

    // MARK: - Run

    /// Every finding of the base, errors first, then by file and element.
    public static func run(_ base: KnowledgeBase, projects: Projects, home: URL) -> [Finding] {
        var findings: [Finding] = []
        let targets = base.linkTargets()
        let kinds = (try? base.kinds()) ?? .defaults
        var projects = projects
        for area in base.areas() {
            for project in area.projects where isRemote(project) {
                if let id = ProjectRecords.normalizedRemote(project) { projects.known.insert(id) }
            }
        }
        let files = KnowledgeBase.files(in: base.areasFolder)
        for file in files where file.pathExtension == "md" {
            let id = KnowledgeBase.id(of: file, areas: base.areasFolder)
            guard let note = KnowledgeNote.load(file) else { continue }
            findings += check(note: note, path: "areas/\(id).md", targets: targets, kinds: kinds, projects: projects, home: home)
        }
        var graphs: [MapGraph.Map] = []
        var scenes: [String: ExcalidrawFile] = [:]
        for file in files where file.pathExtension == "excalidraw" {
            let id = KnowledgeBase.id(of: file, areas: base.areasFolder)
            let path = "areas/\(id).excalidraw"
            let read = ExcalidrawFile.load(file)
            switch read {
            case .failure(let failure):
                findings.append(Finding(rule: .mapParse, file: path, message: "The map doesn't parse: \(failure.message).",
                                        fix: "Restore it from the base's git history, or open the file in Excalidraw and save it again."))
            case .success(let scene):
                scenes[id] = scene
                graphs.append(MapGraph.map(id: id, file: read, targets: targets))
            }
        }
        for graph in graphs {
            guard let scene = scenes[graph.id] else { continue }
            findings += check(map: graph, scene: scene, targets: targets)
        }
        findings += unrelatedAreas(graphs)
        return findings.sorted { ($0.severity, $0.file, $0.element ?? "", $0.link ?? "") < ($1.severity, $1.file, $1.element ?? "", $1.link ?? "") }
    }

    /// A git remote rather than a `~/` or absolute path or a glob.
    static func isRemote(_ value: String) -> Bool {
        !value.hasPrefix("~") && !value.hasPrefix("/") && !value.contains("*")
    }

    /// A link to something outside the base (`https://…`, `mailto:`), not checked.
    static func isOutside(_ link: String) -> Bool {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("[["), let scheme = URL(string: trimmed)?.scheme?.lowercased() else { return false }
        return scheme != "akit"
    }

    /// `[[image.png]]` (an embed of a file that is no note or map), not checked.
    static func isAttachment(_ link: String) -> Bool {
        var target = link
        if target.hasPrefix("[["), target.hasSuffix("]]") { target = String(target.dropFirst(2).dropLast(2)) }
        if let cut = target.firstIndex(where: { $0 == "|" || $0 == "#" }) { target = String(target[..<cut]) }
        let ext = (target.split(separator: "/").last.map(String.init) ?? "").split(separator: ".").dropFirst().last?.lowercased()
        guard let ext else { return false }
        return !["md", "excalidraw"].contains(ext) && ext.count <= 5 && ext.allSatisfy(\.isLetter)
    }

    static func linkFinding(_ link: String, resolution: KnowledgeLinks.Resolution, file: String, element: String?) -> Finding? {
        let subject = element.map { "The element \($0) links \(link), which" } ?? "The link \(link)"
        switch resolution {
        case .note, .map:
            return nil
        case .missing:
            return Finding(rule: .brokenLink, file: file, element: element, link: link,
                           message: "\(subject) points to no note or map in the base.",
                           fix: "Create the note (Create Note…, or akit kb new-note AREA NAME), or correct the link.")
        case .ambiguous(let ids):
            return Finding(rule: .ambiguousLink, file: file, element: element, link: link,
                           message: "\(subject) fits more than one note: \(ids.joined(separator: ", ")).",
                           fix: "Write the path of the one you mean, like [[\(ids[0])]].")
        }
    }

    static func check(note: KnowledgeNote, path: String, targets: KnowledgeLinks, kinds: KnowledgeKinds, projects: Projects,
                      home: URL) -> [Finding] {
        var findings: [Finding] = []
        var seen: Set<String> = []
        for token in KnowledgeRename.noteTokens(note.text) where !seen.contains(token.value) && !isAttachment(token.value) {
            seen.insert(token.value)
            if let finding = linkFinding(token.value, resolution: targets.resolve(token.value, from: path), file: path, element: nil) {
                findings.append(finding)
            }
        }
        if let kind = note.kind, kinds.kind(kind) == nil {
            findings.append(Finding(rule: .unknownKind, file: path, link: kind,
                                    message: "The kind “\(kind)” isn't in kb.yaml (\(kinds.names.joined(separator: ", "))). The note works; Properties shows no fields for it.",
                                    fix: "Add the kind with Kinds… (akit kb kinds add \(kind)), or pick a listed one in Properties."))
        }
        func homePath(_ value: String) -> URL? {
            value == "~" ? home : value.hasPrefix("~/") ? home.appending(path: String(value.dropFirst(2))) : nil
        }
        var copy: URL?
        if let repo = note.repo {
            if let url = homePath(repo) {
                if FileManager.default.fileExists(atPath: url.path) {
                    copy = url
                } else {
                    findings.append(Finding(rule: .missingHomePath, file: path, link: repo, message: "The repo: path \(repo) doesn't exist on this Mac.",
                                            fix: "Clone the repository there, or set repo: to its git remote URL."))
                }
            } else if let id = ProjectRecords.normalizedRemote(repo), projects.known.contains(id) {
                copy = projects.copies[id]
            } else {
                findings.append(Finding(rule: .unknownRepo, file: path, link: repo,
                                        message: "The repo: \(repo) is not among the known projects (the repos in your projects folder, AKit's project records, the areas' projects).",
                                        fix: "Clone it into your projects folder, add it to the area's projects (Area Settings…), or correct repo:."))
            }
        }
        if let value = note.path {
            if let url = KnowledgeLocal.url(value, home: home), FileWalk.isDirectory(url) {
                copy = url
            } else {
                let absolute = KnowledgeLocal.url(value, home: home) != nil
                findings.append(Finding(rule: .missingHomePath, file: path, link: value,
                                        message: absolute ? "The path: folder \(value) doesn't exist on this Mac."
                                            : "The path: \(value) is not a folder path: write it as ~/… or /….",
                                        fix: "Correct path: (Properties, or akit kb set NOTE path=~/…), or remove it."))
            }
        }
        for file in note.files where !file.contains("*") {
            if let url = homePath(file) {
                if !FileManager.default.fileExists(atPath: url.path) {
                    findings.append(Finding(rule: .missingHomePath, file: path, link: file, message: "The path \(file) in files: doesn't exist on this Mac.",
                                            fix: "Correct the path, or remove it from files:."))
                }
            } else if let copy, !file.hasPrefix("/"), !FileManager.default.fileExists(atPath: copy.appending(path: file).path) {
                findings.append(Finding(rule: .missingFile, file: path, link: file,
                                        message: "The file \(file) is not in the local copy of the repo (\(FileWalk.tilde(copy, home: home))).",
                                        fix: "Correct the path in files: (the file may have moved), or pull the repo."))
            }
        }
        return findings
    }

    static func check(map: MapGraph.Map, scene: ExcalidrawFile, targets: KnowledgeLinks) -> [Finding] {
        var findings: [Finding] = []
        let labels = MapGraph.labels(in: scene)
        for element in scene.live {
            let link = element.link?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if link.isEmpty {
                if ["rectangle", "ellipse", "diamond"].contains(element.type), let label = labels[element.id] {
                    findings.append(Finding(rule: .blockWithoutNote, file: map.path, element: element.id,
                                            message: "The block “\(label)” links no note, so agents don't know what it stands for.",
                                            fix: "Link it to a note (drag the note onto the map, or set the shape's link to [[note]]), or Create Note… for it."))
                }
                continue
            }
            if isOutside(link) { continue }
            if let finding = linkFinding(link, resolution: targets.resolve(link, from: map.path), file: map.path, element: element.id) {
                findings.append(finding)
            }
        }
        for arrow in map.unbound {
            let name = arrow.label.map { "“\($0)”" } ?? arrow.arrow
            let ends = arrow.start == nil && arrow.end == nil ? "neither end is" : arrow.start == nil || arrow.end == nil ? "one end isn't" : "an end is bound to a shape that links no note, so it isn't"
            findings.append(Finding(rule: .unboundArrow, file: map.path, element: arrow.arrow,
                                    message: "The arrow \(name) is no relation: \(ends) bound to a block.",
                                    fix: "In Edit, drag both ends of the arrow onto blocks, or delete it."))
        }
        return findings
    }

    /// R-SEP: a block on a map of area A for a note of area B, when no map of A jumps to a map of
    /// B or back. Unrelated areas share no blocks; it is a hint, not an error.
    static func unrelatedAreas(_ graphs: [MapGraph.Map]) -> [Finding] {
        var related: Set<[String]> = []
        for graph in graphs {
            for jump in graph.jumps {
                let other = String(jump.map.split(separator: "/").first ?? "")
                related.insert([graph.area, other].sorted())
            }
        }
        var findings: [Finding] = []
        for graph in graphs {
            for block in graph.blocks {
                let area = String(block.note.split(separator: "/").first ?? "")
                guard area != graph.area, !related.contains([graph.area, area].sorted()) else { continue }
                findings.append(Finding(rule: .unrelatedArea, file: graph.path, element: block.element, link: block.note,
                                        message: "The block for \(block.note) is on a map of \(graph.area), and no map of \(graph.area) jumps to one of \(area) or back. Unrelated systems belong in their own area.",
                                        fix: "Link a map of \(graph.area) to a map of \(area) if they are related; else draw this block on a map of \(area)."))
            }
        }
        return findings
    }

    /// Where Create Note… puts a note for a broken link: the area named in the link, else the
    /// linking file's area, and the link's last part as the name. nil for a map link.
    public static func newNote(for finding: Finding) -> (area: String, name: String)? {
        guard finding.rule == .brokenLink, var target = finding.link else { return nil }
        if target.hasPrefix("akit:map/") { return nil }
        if target.hasPrefix("akit:note/") { target = String(target.dropFirst("akit:note/".count)) }
        if target.hasPrefix("[["), target.hasSuffix("]]") { target = String(target.dropFirst(2).dropLast(2)) }
        if let cut = target.firstIndex(where: { $0 == "|" || $0 == "#" }) { target = String(target[..<cut]) }
        target = KnowledgeLinks.withoutExtension(target.trimmingCharacters(in: .whitespaces))
        if target.hasPrefix("areas/") { target = String(target.dropFirst("areas/".count)) }
        let parts = target.split(separator: "/").map(String.init)
        guard let name = parts.last, !name.isEmpty, !parts.dropLast().contains("maps") else { return nil }
        let area = parts.count > 1 ? parts[0] : KnowledgeLinks.area(of: finding.file)
        return area.isEmpty ? nil : (area, name)
    }
}
