import AKitFoundation
import Foundation

/// The files a layer setup puts into a control cell's clone before the agent starts
/// (`docs/design/layer-evals.md`, "Layer setup: on top of the project"). Rendered once when
/// the cells are queued and stored; every cell of the setup places the same overlay. A
/// `ControlPatch` is the one-file case. Neutral: it knows paths and placement rules, not
/// layers.
public struct ControlOverlay: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// The glued `AGENTS.md`: appended to the file Claude Code already reads.
        case agentsSection
        /// Another Markdown file: appended when the clone has it, else written.
        case markdown
        /// A file of the skill folder `.agents/skills/<skill>/`: skipped when the clone has that skill.
        case skillFile
        /// `.claude/skills` → `../.agents/skills`, so Claude Code finds the skills.
        case claudeSkillsLink
        /// Any other file: written when absent; present blocks the task.
        case file
    }

    public struct Entry: Codable, Sendable, Hashable {
        /// Relative to the repository root.
        public var path: String
        public var kind: Kind
        /// The skill folder's name, for `skillFile`.
        public var skill: String?
        /// SHA-256 of the bytes (in `files/<path>` next to `overlay.json`); nil for a link.
        public var sha256: String?
        /// The link's destination, for `claudeSkillsLink`.
        public var linkTarget: String?

        public init(path: String, kind: Kind, skill: String? = nil, sha256: String? = nil, linkTarget: String? = nil) {
            self.path = path
            self.kind = kind
            self.skill = skill
            self.sha256 = sha256
            self.linkTarget = linkTarget
        }
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// The placement rules this code follows. Part of the hash: a rule change gives new cells.
    public static let rulesVersion = 1
    public static let schemaVersion = 1

    public var schema = ControlOverlay.schemaVersion
    public var rulesVersion = ControlOverlay.rulesVersion
    /// What the overlay was rendered from, for people reading the file; not in the hash.
    public var layer: String?
    public var role: String?
    public var layers: [String]
    /// Sorted by path.
    public private(set) var entries: [Entry] = []
    /// The bytes of each file entry by path. Not in `overlay.json`: they live in `files/<path>`.
    public private(set) var contents: [String: Data] = [:]

    private enum CodingKeys: String, CodingKey { case schema, rulesVersion, layer, role, layers, entries }

    public init(layer: String? = nil, role: String? = nil, layers: [String] = []) {
        self.layer = layer
        self.role = role
        self.layers = layers
    }

    public mutating func add(_ path: String, kind: Kind, skill: String? = nil, data: Data) {
        insert(Entry(path: path, kind: kind, skill: skill, sha256: Checksum.sha256(data)))
        contents[path] = data
    }

    public mutating func addLink(_ path: String, to target: String) {
        insert(Entry(path: path, kind: .claudeSkillsLink, linkTarget: target))
    }

    private mutating func insert(_ entry: Entry) {
        entries.removeAll { $0.path == entry.path }
        entries.append(entry)
        entries.sort { $0.path < $1.path }
    }

    /// SHA-256 of the canonical JSON of the sorted entries (path, kind, skill, link target,
    /// hash of the bytes) and the rules version. No dates, no brain commit: the same rendered
    /// content always gives the same hash.
    public var hash: String {
        struct Canonical: Encodable {
            let rulesVersion: Int
            let entries: [Entry]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(Canonical(rulesVersion: rulesVersion, entries: entries))) ?? Data()
        return Checksum.sha256(data)
    }

    /// `folder/overlay.json` and `folder/files/<path>`.
    public func save(to folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in entries {
            guard let data = contents[entry.path] else { continue }
            guard Self.isSafe(entry.path) else { throw Failure(message: "The overlay path \(entry.path) leaves the repository.") }
            let url = folder.appending(path: "files").appending(path: entry.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: folder.appending(path: "overlay.json"), options: .atomic)
    }

    /// Reads `overlay.json` and the bytes, checking each against its hash: an overlay that
    /// changed on disk is refused rather than placed.
    public static func load(from folder: URL) throws -> ControlOverlay {
        guard let data = try? Data(contentsOf: folder.appending(path: "overlay.json")) else {
            throw Failure(message: "No overlay in \(folder.path).")
        }
        struct Header: Decodable { let schema: Int?; let rulesVersion: Int? }
        let header = try? JSONDecoder().decode(Header.self, from: data)
        if (header?.schema ?? 1) > schemaVersion || (header?.rulesVersion ?? 1) > rulesVersion {
            throw Failure(message: "The overlay in \(folder.path) was written by a newer AKit; install the app and akit together.")
        }
        var overlay: ControlOverlay
        do {
            overlay = try JSONDecoder().decode(ControlOverlay.self, from: data)
        } catch {
            throw Failure(message: "The overlay in \(folder.path) can't be read: \(error.localizedDescription)")
        }
        overlay.entries.sort { $0.path < $1.path }
        for entry in overlay.entries {
            guard isSafe(entry.path) else { throw Failure(message: "The overlay path \(entry.path) leaves the repository.") }
            guard let expected = entry.sha256 else { continue }
            guard let bytes = try? Data(contentsOf: folder.appending(path: "files").appending(path: entry.path)),
                  Checksum.sha256(bytes) == expected else {
                throw Failure(message: "The overlay file \(entry.path) in \(folder.path) is missing or changed since the eval was queued.")
            }
            overlay.contents[entry.path] = bytes
        }
        return overlay
    }

    /// A relative path that stays inside the repository and out of `.git`.
    static func isSafe(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("~")
            && !parts.contains("..") && !parts.contains("") && parts.first?.lowercased() != ".git"
    }
}

// MARK: - Placement

extension ControlOverlay {
    /// Where an overlay's entries go in one clone, or why they can't.
    public enum Placement: Sendable, Equatable {
        case writes([Write], notes: [String])
        case blocked(String)
    }

    public struct Write: Sendable, Equatable {
        public enum Action: Sendable, Equatable {
            /// Appended after a blank line to the clone's own file.
            case append
            /// A new file.
            case create
            /// A new symlink with this destination.
            case link(String)
        }

        /// Relative to the clone, links resolved, spelled as the clone spells it.
        public var path: String
        public var action: Action
        public var data: Data
    }

    /// The placement rules (`layer-evals.md`, "Layer setup: on top of the project"): append the
    /// layer's text to the file the agent already reads, write a file only when it reads none;
    /// a skill the project has wins; a file the project has blocks. The same function runs on
    /// the base commit's git tree when cells are queued and on the clone before the agent, so
    /// a task is refused before it costs anything. Paths are compared ignoring letter case
    /// (macOS does).
    public static func place(_ overlay: ControlOverlay, in files: CloneFiles) -> Placement {
        var view = files
        var writes: [Write] = []
        var notes: [String] = []
        var skipped: Set<String> = []
        for entry in overlay.entries {
            guard isSafe(entry.path) else { return .blocked("The overlay path \(entry.path) leaves the repository.") }
            let data = overlay.contents[entry.path] ?? Data()
            switch entry.kind {
            case .agentsSection:
                switch agentsTarget(view) {
                case .failure(let failure): return .blocked(failure.message)
                case .success(let target):
                    if view.exists(target.path) {
                        writes.append(Write(path: target.path, action: .append, data: data))
                        notes.append("The layer's AGENTS.md section is appended to the project's own \(target.path)\(target.why).")
                    } else {
                        writes.append(Write(path: target.path, action: .create, data: data))
                        view.add(target.path)
                    }
                }
            case .markdown:
                guard let path = view.resolve(entry.path) else { return .blocked(outside(entry.path)) }
                if view.exists(path) {
                    writes.append(Write(path: path, action: .append, data: data))
                    notes.append("The layer's \(entry.path) is appended to the project's own \(path).")
                } else {
                    writes.append(Write(path: path, action: .create, data: data))
                    view.add(path)
                }
            case .skillFile:
                let name = entry.skill ?? entry.path.split(separator: "/").dropFirst(2).first.map(String.init) ?? entry.path
                if skipped.contains(name) { continue }
                // The project's own skill, as the clone had it (not one this overlay just wrote).
                if files.has(skill: name) {
                    skipped.insert(name)
                    notes.append("The project has its own skill \(name); the layer's copy is skipped.")
                    continue
                }
                guard let path = view.resolve(entry.path) else { return .blocked(outside(entry.path)) }
                if view.exists(path) { return .blocked("\(path) is already in the project; the layer's skill file would replace it.") }
                writes.append(Write(path: path, action: .create, data: data))
                view.add(path)
            case .claudeSkillsLink:
                let target = entry.linkTarget ?? "../.agents/skills"
                let parent = (entry.path as NSString).deletingLastPathComponent
                guard let folder = parent.isEmpty ? "" : view.resolve(parent) else { return .blocked(outside(entry.path)) }
                let path = folder.isEmpty ? (entry.path as NSString).lastPathComponent
                    : folder + "/" + (entry.path as NSString).lastPathComponent
                switch view.kind(of: path) {
                case nil:
                    writes.append(Write(path: view.spelled(path), action: .link(target), data: Data()))
                case .link(let existing):
                    guard CloneFiles.normalize(existing, from: (path as NSString).deletingLastPathComponent)?.lowercased()
                        == CloneFiles.normalize(target, from: (path as NSString).deletingLastPathComponent)?.lowercased() else {
                        return .blocked("The project's \(view.spelled(path)) is a link to \(existing), not to \(target); the layer's skills can't be linked there.")
                    }
                case .folder:
                    return .blocked("The project has its own \(view.spelled(path)) folder, so the layer's skills can't be linked there (Apply refuses it too).")
                case .file:
                    return .blocked("The project has a file \(view.spelled(path)), so the layer's skills can't be linked there.")
                }
            case .file:
                guard let path = view.resolve(entry.path) else { return .blocked(outside(entry.path)) }
                if view.exists(path) { return .blocked("\(path) is already in the project; the layer's file would replace it.") }
                writes.append(Write(path: path, action: .create, data: data))
                view.add(path)
            }
        }
        return .writes(writes, notes: notes)
    }

    private static func outside(_ path: String) -> String {
        "\(path) leads out of the repository through a link (or into .git), so the layer can't write it."
    }

    /// The file the `AGENTS.md` section goes to. Claude Code reads `CLAUDE.md` and
    /// `.claude/CLAUDE.md`; an import or link resolves relative to the file that holds it
    /// (`@AGENTS.md` in `.claude/CLAUDE.md` is `.claude/AGENTS.md`). When either brings in the
    /// root `AGENTS.md`, the section goes there; else it is appended to root `CLAUDE.md`, else
    /// to `.claude/CLAUDE.md`; with neither, a new `CLAUDE.md` holds it.
    static func agentsTarget(_ files: CloneFiles) -> Result<(path: String, why: String), Failure> {
        // An AGENTS.md that is a link out of the clone is never written; Claude's own file then is.
        if let agents = files.resolve("AGENTS.md") {
            for reader in ["CLAUDE.md", ".claude/CLAUDE.md"] where files.reads(reader, file: agents) {
                return .success((agents, " (\(files.spelled(reader)) brings it in)"))
            }
        }
        for reader in ["CLAUDE.md", ".claude/CLAUDE.md"] {
            // A reader that is a link out of the clone: never written through.
            guard let path = files.resolve(reader) else {
                if files.kind(of: reader) != nil { return .failure(Failure(message: outside(reader))) }
                continue
            }
            if files.kind(of: path) != nil { return .success((path, "")) }
        }
        guard let path = files.resolve("CLAUDE.md") else { return .failure(Failure(message: outside("CLAUDE.md"))) }
        return .success((path, ""))
    }

    /// Writes the placement into the clone, then hides every written path from `git status`
    /// and `git diff`, so the agent sees a clean checkout as in the baseline.
    public static func apply(_ writes: [Write], in folder: URL, env: HarnessEnvironment) async throws {
        let fm = FileManager.default
        for write in writes {
            let url = folder.appending(path: write.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch write.action {
            case .create:
                try write.data.write(to: url)
            case .append:
                var content = (try? Data(contentsOf: url)) ?? Data()
                if !content.isEmpty { content.append(Data((content.last == UInt8(ascii: "\n") ? "\n" : "\n\n").utf8)) }
                content.append(write.data)
                try content.write(to: url)
            case .link(let target):
                // An empty folder can't be in git; the clone may still have made one.
                if (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true { try fm.removeItem(at: url) }
                try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target)
            }
        }
        await CloneHiding.hide(paths: writes.map(\.path), in: folder, env: env)
    }
}

/// Hides changes AKit made in a clone from `git status` and `git diff`: assume-unchanged for
/// tracked files, `.git/info/exclude` for new ones (resolved paths, never a link's own path).
enum CloneHiding {
    static func hide(paths: [String], in folder: URL, env: HarnessEnvironment) async {
        var excluded: [String] = []
        var seen: Set<String> = []
        for path in paths where seen.insert(path).inserted {
            if await LabGit.run(["ls-files", "--error-unmatch", "--", path], in: folder, env: env)?.succeeded == true {
                _ = await LabGit.run(["update-index", "--assume-unchanged", "--", path], in: folder, env: env)
            } else {
                excluded.append(path)
            }
        }
        guard !excluded.isEmpty else { return }
        let exclude = folder.appending(path: ".git/info/exclude")
        let old = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        // Patterns, not paths: escape what gitignore would read as a wildcard.
        let lines = excluded.map { path in
            "/" + path.map { "*?[\\".contains($0) ? "\\\($0)" : String($0) }.joined()
        }
        try? FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((old + (old.isEmpty || old.hasSuffix("\n") ? "" : "\n") + lines.joined(separator: "\n") + "\n").utf8).write(to: exclude)
    }
}

// MARK: - The clone's files

/// The files of a clone as the placement rules see them: paths, links with their
/// destinations, and the text of the Markdown files Claude Code reads at the root. Built
/// from the base commit's git tree (at queueing, no clone needed) or from a clone's folder
/// (before the agent); both give the same placement for the same commit.
public struct CloneFiles: Sendable, Equatable {
    enum Kind: Equatable {
        case file
        case folder
        case link(String)
    }

    /// Lowercased path → (spelling, kind), for every file, link and folder on the way.
    private var items: [String: (spelling: String, kind: Kind)] = [:]
    /// Text of `CLAUDE.md` and `.claude/CLAUDE.md`, by their resolved path (lowercased).
    private var texts: [String: String] = [:]

    public static func == (lhs: CloneFiles, rhs: CloneFiles) -> Bool {
        lhs.items.mapValues { "\($0.spelling)|\($0.kind)" } == rhs.items.mapValues { "\($0.spelling)|\($0.kind)" } && lhs.texts == rhs.texts
    }

    init() {}

    /// Files and links by relative path; the texts of the readers are read through `text`.
    init(files: [String], links: [String: String], text: (String) -> String?) {
        for path in files { add(path) }
        for (path, target) in links { add(path, kind: .link(target)) }
        for reader in ["CLAUDE.md", ".claude/CLAUDE.md"] {
            guard let path = resolve(reader), case .file = kind(of: path), let content = text(spelled(path)) else { continue }
            texts[path.lowercased()] = content
        }
    }

    mutating func add(_ path: String, kind: Kind = .file) {
        let parts = path.split(separator: "/").map(String.init)
        for index in parts.indices.dropLast() {
            let folder = parts[...index].joined(separator: "/")
            if items[folder.lowercased()] == nil { items[folder.lowercased()] = (folder, .folder) }
        }
        items[path.lowercased()] = (path, kind)
    }

    func kind(of path: String) -> Kind? { items[path.lowercased()]?.kind }

    func exists(_ path: String) -> Bool { resolve(path).map { kind(of: $0) != nil } ?? false }

    /// The project has a skill folder of this name, for Claude Code or shared.
    public func has(skill name: String) -> Bool { exists(".agents/skills/\(name)") || exists(".claude/skills/\(name)") }

    /// The clone's own spelling of a path (folder by folder), else the path as given.
    func spelled(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        return parts.indices.map { index in
            items[parts[...index].joined(separator: "/").lowercased()].map { ($0.spelling as NSString).lastPathComponent } ?? parts[index]
        }.joined(separator: "/")
    }

    /// The path with every link on the way followed, in the clone's spelling; nil when it
    /// leaves the clone, enters `.git`, or the links go in a circle.
    func resolve(_ path: String) -> String? {
        var current = path
        for _ in 0..<32 {
            let parts = current.split(separator: "/").map(String.init)
            var followed = false
            for index in parts.indices {
                let prefix = parts[...index].joined(separator: "/")
                guard case .link(let target) = kind(of: prefix) else { continue }
                guard let base = Self.normalize(target, from: (spelled(prefix) as NSString).deletingLastPathComponent) else { return nil }
                current = ([base] + parts[(index + 1)...]).filter { !$0.isEmpty }.joined(separator: "/")
                followed = true
                break
            }
            if !followed {
                guard !current.isEmpty, current.split(separator: "/").first?.lowercased() != ".git" else { return nil }
                return spelled(current)
            }
        }
        return nil
    }

    /// `target` read from the folder `from` (both relative to the clone), with `.` and `..`
    /// applied; nil when it is absolute or climbs out of the clone.
    static func normalize(_ target: String, from folder: String) -> String? {
        guard !target.hasPrefix("/"), !target.hasPrefix("~") else { return nil }
        var parts = folder.split(separator: "/").map(String.init)
        for part in target.split(separator: "/").map(String.init) {
            switch part {
            case ".", "": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    /// Whether Claude Code's `reader` brings in `file`: it is a link to it, or holds an
    /// import line (`@AGENTS.md`, `@./AGENTS.md`, `@../AGENTS.md` from `.claude/`) naming it.
    func reads(_ reader: String, file: String) -> Bool {
        guard let path = resolve(reader), kind(of: reader) != nil || kind(of: path) != nil else { return false }
        if path.lowercased() == file.lowercased() { return true }
        guard let text = texts[path.lowercased()] else { return false }
        let folder = (spelled(reader) as NSString).deletingLastPathComponent
        let pattern = /(?:^|[\s(])@([^\s)`]+)/
        for match in text.matches(of: pattern) {
            var name = String(match.1)
            while let last = name.last, ".,;:!?".contains(last) { name.removeLast() }

            guard let target = Self.normalize(name, from: folder), let resolved = resolve(target) else { continue }
            if resolved.lowercased() == file.lowercased() { return true }
        }
        return false
    }
}

extension CloneFiles {
    /// A clone's folder: files and links as they are (links not followed), without `.git`.
    public static func fromFolder(_ folder: URL) -> CloneFiles {
        let fm = FileManager.default
        var files: [String] = []
        var links: [String: String] = [:]
        var folders: [String] = []
        if let walker = fm.enumerator(atPath: folder.path) {
            while let path = walker.nextObject() as? String {
                switch walker.fileAttributes?[.type] as? FileAttributeType {
                case .typeDirectory?:
                    if path == ".git" { walker.skipDescendants() } else { folders.append(path) }
                case .typeSymbolicLink?:
                    links[path] = (try? fm.destinationOfSymbolicLink(atPath: folder.appending(path: path).path)) ?? ""
                default:
                    files.append(path)
                }
            }
        }
        var result = CloneFiles(files: files, links: links) { path in
            try? String(contentsOf: folder.appending(path: path), encoding: .utf8)
        }
        for path in folders where result.kind(of: path) == nil { result.add(path, kind: .folder) }
        return result
    }

    /// The tracked files of `base` in `repo`, without making a clone: `git ls-tree`, with the
    /// destinations of links and the readers' text from the objects.
    public static func fromTree(repo: URL, base: String, env: HarnessEnvironment) async throws -> CloneFiles {
        guard let listing = await LabGit.run(["ls-tree", "-r", "-z", "--full-tree", base], in: repo, env: env), listing.succeeded else {
            throw ControlOverlay.Failure(message: "Couldn't list the files of \(String(base.prefix(7))) in \(repo.path).")
        }
        var files: [String] = []
        var objects: [String: String] = [:]
        var linkObjects: [String: String] = [:]
        for record in listing.output.split(separator: "\0") {
            // "<mode> <type> <object>\t<path>"
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let fields = record[..<tab].split(separator: " ")
            let path = String(record[record.index(after: tab)...])
            guard fields.count == 3 else { continue }
            if fields[0] == "120000" {
                linkObjects[path] = String(fields[2])
            } else {
                files.append(path)
                objects[path] = String(fields[2])
            }
        }
        var links: [String: String] = [:]
        for (path, object) in linkObjects {
            links[path] = await LabGit.output(["cat-file", "-p", object], in: repo, env: env) ?? ""
        }
        // The readers' text needs the objects; read only the two files that can be readers.
        var texts: [String: String] = [:]
        let probe = CloneFiles(files: files, links: links) { _ in nil }
        for reader in ["CLAUDE.md", ".claude/CLAUDE.md"] {
            guard let path = probe.resolve(reader), let object = objects.first(where: { $0.key.lowercased() == path.lowercased() })?.value,
                  let result = await LabGit.run(["cat-file", "-p", object], in: repo, env: env), result.succeeded else { continue }
            texts[path] = result.output
        }
        return CloneFiles(files: files, links: links) { texts[$0] }
    }
}
