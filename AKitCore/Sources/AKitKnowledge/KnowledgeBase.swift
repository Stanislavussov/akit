import AKitBrain
import AKitFoundation
import Foundation

/// A knowledge base (knowledge.md, K4, K11): one folder per world (`~/.akit/local/knowledge/<world>`)
/// holding `areas/<area>/` (notes and maps) and `inbox/` (an agent's proposals), a local git repo
/// that never has a remote. Never inside the brain: the brain goes to a personal remote.
public struct KnowledgeBase: Sendable, Hashable {
    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    public let root: URL

    /// `root` without a trailing slash, so one folder is always one equal value.
    public init(root: URL) { self.root = URL(filePath: root.standardized.path, directoryHint: .notDirectory) }

    /// The base's git lock: every git write in a base holds it (P8).
    public static let queueLockName = ".akit-queue.lock"

    /// What git leaves out of a base: the index, the locks, the commit queue, the miss log, Obsidian's settings.
    public static let gitignore = """
        .akit-index.sqlite*
        .akit-index.lock
        .akit-queue.lock
        .akit-pending.json
        .akit-misses.log
        .obsidian/

        """

    public var name: String { root.lastPathComponent }
    public var areasFolder: URL { root.appending(path: "areas", directoryHint: .isDirectory) }
    public var inboxFolder: URL { root.appending(path: "inbox", directoryHint: .isDirectory) }

    /// Where every base of this Mac lives by default: `~/.akit/local/knowledge`.
    public static func folder(home: URL) -> URL { home.appending(path: ".akit/local/knowledge", directoryHint: .isDirectory) }

    /// The base of a world in the default folder (which may not exist yet).
    public static func world(_ name: String, home: URL) -> URL { folder(home: home).appending(path: name, directoryHint: .isDirectory) }

    /// Project → base choices made in AKit (`~/.akit/local/knowledge/focus.json`).
    public static func focusFile(home: URL) -> URL { folder(home: home).appending(path: "focus.json") }

    /// A folder with `areas/` and a git repo.
    public static func isBase(_ url: URL) -> Bool {
        FileWalk.isDirectory(url.appending(path: "areas")) && FileManager.default.fileExists(atPath: url.appending(path: ".git").path)
    }

    /// The bases in `~/.akit/local/knowledge`, sorted by name.
    public static func all(home: URL) -> [KnowledgeBase] {
        FileWalk.children(of: folder(home: home)).filter(isBase).map(KnowledgeBase.init)
    }

    // MARK: - Create

    /// A world name: letters, digits, `-` and `_`, starting with a letter or digit.
    public static func validWorld(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" } && name.count <= 64
    }

    /// Creates the base of `world` in `~/.akit/local/knowledge/`.
    @discardableResult
    public static func create(world: String, env: HarnessEnvironment, brainRoot: URL? = nil) async throws(Failure) -> KnowledgeBase {
        guard validWorld(world) else {
            throw Failure(message: "“\(world)” can't name a world: use letters, digits, - and _ (like work or personal).")
        }
        return try await create(at: Self.world(world, home: env.homeDirectory), env: env, brainRoot: brainRoot)
    }

    /// Creates a base at `root`: `areas/`, `inbox/`, `.gitignore`, `kb.yaml` with the default kinds,
    /// `git init` with no remote, a git
    /// identity (P5: the user's git config when it has a name and an email, else the base's own
    /// `AKit <akit@localhost>`) and a first commit. `root` may be missing, empty, or a git repo
    /// without a remote (an Obsidian vault kept in git). Refused: inside the brain (`brainRoot`,
    /// default `~/.akit/registry`); on a work Mac outside `~/.akit/local/`; a folder with a remote;
    /// a base already; any other folder with files.
    @discardableResult
    public static func create(at root: URL, env: HarnessEnvironment, brainRoot: URL? = nil) async throws(Failure) -> KnowledgeBase {
        let home = env.homeDirectory
        let root = root.standardized
        let brain = brainRoot ?? Brain.defaultRoot(home: home)
        if isWithin(root, brain) {
            throw Failure(message: "\(root.path) is inside the brain (\(brain.path)), which goes to a remote. Pick a folder outside it, like \(world("work", home: home).path).")
        }
        if MachineProfile.load(home: home).isWork, !isWithin(root, home.appending(path: ".akit/local")) {
            throw Failure(message: "This is a work Mac, so the knowledge base stays in \(FileWalk.tilde(folder(home: home), home: home))/<world>, never elsewhere. Use akit kb init --world NAME.")
        }
        let base = KnowledgeBase(root: root)
        let fm = FileManager.default
        let isRepo = fm.fileExists(atPath: root.appending(path: ".git").path)
        if isRepo {
            let remotes = await KnowledgeGit(base: root, env: env).remotes() ?? []
            if !remotes.isEmpty {
                throw Failure(message: "\(root.path) is a git repo with a remote (\(remotes.joined(separator: ", "))); a knowledge base never has one. Pick another folder.")
            }
            if isBase(root) { throw Failure(message: "\(root.path) is a knowledge base already.") }
        } else if !((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter({ $0 != ".DS_Store" }).isEmpty {
            throw Failure(message: "\(root.path) is not empty. Pick an empty or new folder.")
        }

        do {
            try fm.createDirectory(at: base.areasFolder, withIntermediateDirectories: true)
            try fm.createDirectory(at: base.inboxFolder, withIntermediateDirectories: true)
            let ignore = root.appending(path: ".gitignore")
            if let existing = try? String(contentsOf: ignore, encoding: .utf8) {
                let missing = gitignore.split(separator: "\n").filter { line in !existing.split(separator: "\n").contains(line) }
                if !missing.isEmpty {
                    let joined = (existing.hasSuffix("\n") || existing.isEmpty ? existing : existing + "\n") + missing.joined(separator: "\n") + "\n"
                    try Data(joined.utf8).write(to: ignore, options: .atomic)
                }
            } else {
                try Data(gitignore.utf8).write(to: ignore, options: .withoutOverwriting)
            }
            // K24: the kinds are data; a vault that has its own kb.yaml keeps it.
            if !fm.fileExists(atPath: root.appending(path: KnowledgeKinds.fileName).path) {
                try Data(KnowledgeKinds.defaults.text.utf8).write(to: root.appending(path: KnowledgeKinds.fileName), options: .withoutOverwriting)
            }
        } catch {
            throw Failure(message: "Couldn't create the knowledge base in \(root.path): \(error.localizedDescription)")
        }

        let git = KnowledgeGit(base: root, env: env)
        do {
            if !isRepo { try await git.run(["init", "--quiet", "--initial-branch=main"]) }
            // P5: the user's own identity when git has one; else the base's own, as the modes repo does.
            let name = (try? await git.run(["config", "--get", "user.name"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let email = (try? await git.run(["config", "--get", "user.email"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.isEmpty || email.isEmpty {
                try await git.run(["config", "--local", "user.name", "AKit"])
                try await git.run(["config", "--local", "user.email", "akit@localhost"])
            }
            try await git.commit(paths: [".gitignore", KnowledgeKinds.fileName], message: "Create the knowledge base")
        } catch {
            throw Failure(message: "The knowledge base folder was created, but git failed: \(error.message)")
        }
        return base
    }

    /// `url` is `folder` or inside it, links resolved as far as the path exists.
    static func isWithin(_ url: URL, _ folder: URL) -> Bool {
        let path = resolved(url), base = resolved(folder)
        return path == base || path.hasPrefix(base + "/")
    }

    /// The real path of the nearest existing ancestor, with the rest of the path after it.
    static func resolved(_ url: URL) -> String {
        var existing = url.standardized
        var rest: [String] = []
        while FileWalk.realPath(existing) == nil, existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        let real = FileWalk.realPath(existing) ?? existing.path
        return ([real == "/" ? "" : real] + rest).joined(separator: "/")
    }

    // MARK: - Areas and notes

    public struct Area: Encodable, Equatable, Sendable {
        public let name: String
        public let notes: Int
        public let maps: Int
        /// From `area.yaml` (K24); nil and empty without one, or when it can't be read.
        public let title: String?
        public let description: String?
        public let projects: [String]

        private enum CodingKeys: String, CodingKey { case name, notes, maps, title, description, projects }

        public init(name: String, notes: Int, maps: Int, settings: KnowledgeArea = KnowledgeArea()) {
            self.name = name
            self.notes = notes
            self.maps = maps
            title = settings.title
            description = settings.description
            projects = settings.projects
        }

        // Unset settings are null, so every area has the same keys.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(notes, forKey: .notes)
            try container.encode(maps, forKey: .maps)
            try container.encode(title, forKey: .title)
            try container.encode(description, forKey: .description)
            try container.encode(projects, forKey: .projects)
        }
    }

    public struct NoteEntry: Codable, Equatable, Sendable {
        /// The path under `areas/` without `.md` (`payments/orders-api`): the note's id.
        public let id: String
        public let area: String
        /// Base-relative path (`areas/payments/orders-api.md`).
        public let path: String
        public let kind: String?
        public let title: String

        private enum CodingKeys: String, CodingKey { case id, area, path, kind, title }

        public init(id: String, area: String, path: String, kind: String?, title: String) {
            self.id = id
            self.area = area
            self.path = path
            self.kind = kind
            self.title = title
        }

        // `kind` is null when the note has none, so every entry has the same keys.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(area, forKey: .area)
            try container.encode(path, forKey: .path)
            try container.encode(kind, forKey: .kind)
            try container.encode(title, forKey: .title)
        }
    }

    /// The areas (folders in `areas/`), sorted by name, with their note and map counts and their
    /// `area.yaml` settings.
    public func areas() -> [Area] {
        FileWalk.children(of: areasFolder).filter(FileWalk.isDirectory).map { folder in
            let files = Self.files(in: folder)
            return Area(name: Self.nfc(folder.lastPathComponent), notes: files.filter { $0.pathExtension == "md" }.count,
                        maps: files.filter { $0.pathExtension == "excalidraw" }.count,
                        settings: (try? KnowledgeArea.load(folder: folder)) ?? KnowledgeArea())
        }
    }

    /// The notes of one area, or of every area, sorted by id.
    public func notes(area: String? = nil) throws(Failure) -> [NoteEntry] {
        var folders = FileWalk.children(of: areasFolder).filter(FileWalk.isDirectory)
        if let area {
            folders = folders.filter { Self.nfc($0.lastPathComponent) == Self.nfc(area) }
            guard !folders.isEmpty else {
                throw Failure(message: "No area “\(area)” in \(root.path). Areas: \(areas().map(\.name).joined(separator: ", ")).")
            }
        }
        return folders.flatMap { folder in
            Self.files(in: folder).filter { $0.pathExtension == "md" }.map { file in
                let id = Self.id(of: file, areas: areasFolder)
                let note = KnowledgeNote.load(file)
                return NoteEntry(id: id, area: Self.nfc(folder.lastPathComponent), path: "areas/" + id + ".md", kind: note?.kind,
                                 title: note?.title ?? file.deletingPathExtension().lastPathComponent)
            }
        }.sorted { $0.id < $1.id }
    }

    /// Every note and map id under `areas/`, for the link resolver.
    public func linkTargets() -> KnowledgeLinks {
        let files = Self.files(in: areasFolder)
        return KnowledgeLinks(notes: files.filter { $0.pathExtension == "md" }.map { Self.id(of: $0, areas: areasFolder) },
                              maps: files.filter { $0.pathExtension == "excalidraw" }.map { Self.id(of: $0, areas: areasFolder) })
    }

    /// Creates `areas/AREA/NAME.md` (the area too, when new) with a `# NAME` title and, with a kind,
    /// a `kind:` frontmatter line, and commits it at once: one commit, only that file (P8).
    @discardableResult
    public func newNote(area: String, name: String, kind: String?, env: HarnessEnvironment) async throws(Failure) -> String {
        let area = Self.nfc(area.trimmingCharacters(in: .whitespaces)), name = Self.nfc(name.trimmingCharacters(in: .whitespaces))
        for (what, value) in [("An area", area), ("A note name", name)] where !Self.validName(value) {
            throw Failure(message: "“\(value)” can't be used: \(what.lowercased()) is one folder or file name, without /, and doesn't start with a dot.")
        }
        if let kind, kind.isEmpty || kind.contains(where: { $0.isWhitespace || $0 == ":" || $0 == "#" }) {
            throw Failure(message: "“\(kind)” can't be a kind: one word, like service, flow or team.")
        }
        let stem = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        let path = "areas/\(area)/\(stem).md"
        let file = root.appending(path: path)
        if FileManager.default.fileExists(atPath: file.path) { throw Failure(message: "The note \(area)/\(stem) exists already.") }
        let text = (kind.map { "---\nkind: \($0)\n---\n" } ?? "") + "# \(stem)\n"
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .withoutOverwriting)
        } catch {
            throw Failure(message: "Couldn't write \(path): \(error.localizedDescription)")
        }
        do {
            try await KnowledgeGit(base: root, env: env).commit(paths: [path], message: "Add note \(area)/\(stem)")
        } catch {
            throw Failure(message: "\(path) was written, but not committed: \(error.message)")
        }
        return path
    }

    /// Creates the folder `areas/NAME/`. Nothing to commit: git keeps no empty folders, and the
    /// area's first note commits it.
    public func newArea(_ name: String) throws(Failure) {
        let name = Self.nfc(name.trimmingCharacters(in: .whitespaces))
        guard Self.validName(name) else {
            throw Failure(message: "“\(name)” can't be used: an area is one folder name, without /, and doesn't start with a dot.")
        }
        let folder = areasFolder.appending(path: name, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: folder.path) { throw Failure(message: "The area \(name) exists already.") }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            throw Failure(message: "Couldn't create areas/\(name): \(error.localizedDescription)")
        }
    }

    /// The file of a note id (`payments/orders-api` → `areas/payments/orders-api.md`).
    public func noteFile(_ id: String) -> URL { root.appending(path: notePath(id)) }

    /// The base-relative path of a note id.
    public func notePath(_ id: String) -> String { "areas/\(id).md" }

    /// Writes a note's whole text atomically, byte for byte (P4), and returns its base-relative
    /// path for the commit queue (U2). Only an existing note under `areas/` is written.
    @discardableResult
    public func save(note id: String, text: String) throws(Failure) -> String {
        let path = notePath(id)
        guard KnowledgeGit.isInside(path), FileWalk.isRegularFile(noteFile(id)) else {
            throw Failure(message: "No note \(id) in \(root.path).")
        }
        do { try KnowledgeNote(text: text).write(to: noteFile(id)) } catch {
            throw Failure(message: "Couldn't save \(path): \(error.localizedDescription)")
        }
        return path
    }

    /// Moves a note, or with `area` a whole area, to the Trash and commits the removal at once:
    /// one commit, only that path (P8).
    public func moveToTrash(note id: String? = nil, area: String? = nil, env: HarnessEnvironment,
                            trash: (URL) throws -> URL? = Trash.move) async throws(Failure) {
        let path: String, label: String
        if let id {
            (path, label) = (notePath(id), "note \(id)")
        } else if let area, Self.validName(area) {
            (path, label) = ("areas/\(area)", "area \(area)")
        } else {
            throw Failure(message: "Nothing to move to the Trash.")
        }
        let url = root.appending(path: path)
        guard KnowledgeGit.isInside(path), FileManager.default.fileExists(atPath: url.path) else {
            throw Failure(message: "No \(label) in \(root.path).")
        }
        do { _ = try trash(url) } catch {
            throw Failure(message: "Couldn't move \(path) to the Trash: \(error.localizedDescription)")
        }
        do {
            try await KnowledgeGit(base: root, env: env).commit(paths: [path], message: "Delete \(label)")
        } catch {
            throw Failure(message: "\(path) is in the Trash, but the removal wasn't committed: \(error.message)")
        }
    }

    /// One file or folder name: no `/`, not `.` or `..`, not hidden, not empty.
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && !name.contains(where: \.isNewline) && name.count <= 200
    }

    static func nfc(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }

    /// `…/areas/payments/flows/x.md` → `payments/flows/x`, NFC.
    static func id(of file: URL, areas: URL) -> String {
        let path = file.deletingPathExtension().standardized.path
        for prefix in [areas.standardized.path, FileWalk.realPath(areas)].compactMap(\.self) where path.hasPrefix(prefix + "/") {
            return nfc(String(path.dropFirst(prefix.count + 1)))
        }
        return nfc(file.deletingPathExtension().lastPathComponent)
    }

    /// Notes and maps in a folder and below, links not followed into other places; hidden ones skipped.
    static func files(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { ["md", "excalidraw"].contains($0.pathExtension) && FileWalk.isRegularFile($0) }
            .sorted { $0.path < $1.path }
    }

    // MARK: - Choice

    /// Which base a command uses, in this order: `--base PATH|WORLD`; the project's entry in
    /// `focus.json`; the only base of this Mac; the base named like this Mac's kind (`work` or
    /// `personal`). nil when this Mac has no base (P6: commands answer "no base", exit 0). Several
    /// bases and none of these → an error listing them.
    public static func choose(option: String?, folder: URL, env: HarnessEnvironment, projectsRoot: URL) async throws(Failure) -> KnowledgeBase? {
        let home = env.homeDirectory
        let bases = all(home: home)
        func named(_ value: String, from: String) throws(Failure) -> KnowledgeBase {
            let isPath = value.contains("/") || value.hasPrefix("~") || value.hasPrefix(".")
            let url = isPath ? (value.hasPrefix("/") || value.hasPrefix("~") ? env.expand(value) : folder.appending(path: value))
                : world(value, home: home)
            guard isBase(url) else {
                throw Failure(message: "No knowledge base at \(url.standardized.path) (\(from)). \(listing(bases, home: home))")
            }
            return KnowledgeBase(root: url.standardized)
        }
        if let option { return try named(option, from: "--base") }
        if FileManager.default.fileExists(atPath: focusFile(home: home).path) {
            let id = await ProjectRecords.projectID(for: folder, projectsRoot: projectsRoot, env: env)
            if let chosen = Focus.load(home: home).projects[id]?.base { return try named(chosen, from: "focus.json, project \(id)") }
        }
        if bases.count <= 1 { return bases.first }
        let kind = MachineProfile.load(home: home).kind.rawValue
        if let match = bases.first(where: { $0.name == kind }) { return match }
        throw Failure(message: "This Mac has several knowledge bases and none is named \(kind). \(listing(bases, home: home)) Pick one with --base PATH|WORLD.")
    }

    static func listing(_ bases: [KnowledgeBase], home: URL) -> String {
        bases.isEmpty ? "This Mac has no knowledge base (a person creates one with akit kb init)."
            : "Bases: " + bases.map { "\($0.name) (\(FileWalk.tilde($0.root, home: home)))" }.joined(separator: ", ") + "."
    }

    /// `~/.akit/local/knowledge/focus.json`: per project id, the base (a world or a path) and, later,
    /// the area its sessions start from (K5). Written by AKit's Focus… (step 3), never in the brain.
    public struct Focus: Codable, Equatable, Sendable {
        public struct Entry: Codable, Equatable, Sendable {
            public var base: String?
            public var area: String?

            public init(base: String? = nil, area: String? = nil) {
                self.base = base
                self.area = area
            }
        }

        public var projects: [String: Entry]

        public init(projects: [String: Entry] = [:]) { self.projects = projects }

        /// Empty when the file is missing or can't be read.
        public static func load(home: URL) -> Focus {
            guard let data = FileWalk.head(of: focusFile(home: home), limit: 1 << 20),
                  let focus = try? JSONDecoder().decode(Focus.self, from: data) else { return Focus() }
            return focus
        }
    }
}
