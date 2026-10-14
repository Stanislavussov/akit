import AKitFoundation
import AKitHarnesses
import AKitModel
import Foundation

/// Which instruction files (AGENTS.md, CLAUDE.md, …) one harness loads for a session started
/// in a project, in the order they reach the model, and the ones it skips with the reason
/// (`docs/design/instructions.md`, Facts; checked 2026-10-14 in Claude Code 2.1.299, Pi 1.0.4,
/// Codex 0.147 and OpenCode 1.18.15). Reads only.
///
/// ```
/// Claude Code  managed → ~/.claude/CLAUDE.md, rules → each folder from the top down to the project:
///              CLAUDE.md, .claude/CLAUDE.md, CLAUDE.local.md, .claude/rules; @imports after their file;
///              AGENTS.md only when no CLAUDE.md is in the project or above it
/// Pi           one file in its agent folder → one file per folder from / down to the project
///              (a worktree inside the main checkout: the main checkout's file of the same name is skipped)
/// Codex        one file in ~/.codex → one file per folder from the git root down; 32 KiB in all
/// OpenCode     the first global file → one file name for the whole tree, closest folder first
/// ```
///
/// Claude Code and OpenCode list a file once by its real path; Pi and Codex compare paths as
/// written, so a link to a file above is read twice there. Files in subfolders that load only
/// when the agent touches a file there are not listed; Claude Code rules with `paths:` are
/// listed apart (they load only for matching files).
public enum InstructionScanner {
    /// What a session in `project` (nil: only the global files) gets from `harness`.
    /// `top`: the highest folder walked (tests); nil walks to `/`. `managed`: Claude Code's
    /// managed policy file.
    public static func view(harness: HarnessID, project: URL?, env: HarnessEnvironment, top: URL? = nil,
                            managed: URL = URL(filePath: "/Library/Application Support/ClaudeCode/CLAUDE.md")) -> InstructionView {
        var scan = Scan(env: env, project: project.map(\.standardizedFileURL), byRealPath: harness == .claudeCode || harness == .openCode)
        let folders = project.map { chain(from: $0.standardizedFileURL, top: top) } ?? []
        switch harness {
        case .claudeCode: scan.claude(folders: folders, managed: managed)
        case .pi: scan.pi(folders: folders)
        case .codex: scan.codex(folders: folders)
        case .openCode: scan.openCode(folders: folders)
        default: break
        }
        return InstructionView(harness: harness, project: project, entries: scan.entries)
    }

    /// The harnesses this scanner knows.
    public static let harnesses: [HarnessID] = [.claudeCode, .pi, .codex, .openCode]

    /// Folders from the top down to `folder`, both included. String paths, bounded: a parent
    /// walk on URLs can loop at `/..`.
    static func chain(from folder: URL, top: URL?) -> [URL] {
        var path = folder.path, result: [String] = []
        let stop = top?.standardizedFileURL.path
        // One step per path component and one for `/`: always ends, never cuts a deep path short.
        for _ in 0...((path as NSString).pathComponents.count + 1) {
            result.append(path)
            if path == "/" || path == stop { break }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { break }
            path = parent
        }
        return result.reversed().map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    // MARK: - One scan

    struct Scan {
        let env: HarnessEnvironment
        let project: URL?
        /// How a file counts as already listed: its real path (Claude Code, OpenCode) or the path
        /// as written (Pi and Codex keep a list of paths, so a link is a second file).
        let byRealPath: Bool
        var entries: [InstructionEntry] = []
        var seen: Set<String> = []

        var home: URL { env.homeDirectory }

        func level(of folder: URL) -> InstructionLevel {
            folder.path == project?.path ? .project : .above(folder)
        }

        /// The file's text when it exists as a regular file (links followed).
        func read(_ url: URL) -> String? {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            return (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
        }

        /// The path with links resolved and, on a case-insensitive disk, spelled as on disk
        /// (`realpath`), so `AGENTS.MD` and `AGENTS.md` are one file.
        func real(_ url: URL) -> String {
            guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        func key(_ url: URL) -> String { byRealPath ? real(url) : url.standardizedFileURL.path }

        /// Adds the file once; false when it doesn't exist or is already listed.
        @discardableResult
        mutating func add(_ url: URL, _ level: InstructionLevel, _ status: InstructionEntry.Status, note: String? = nil, text known: String? = nil) -> Bool {
            guard let text = known ?? read(url) else { return false }
            let key = key(url)
            if status.isLoaded {
                guard seen.insert(key).inserted else { return false }
            } else if seen.contains(key) || entries.contains(where: { self.key($0.file) == key }) {
                return false
            }
            entries.append(InstructionEntry(file: url, level: level, status: status, text: text, note: note))
            return true
        }

        // MARK: Claude Code

        mutating func claude(folders: [URL], managed: URL) {
            let config = HarnessCatalog.configRoot(of: .claudeCode, in: env) ?? home.appending(path: ".claude")
            let user = config.appending(path: "CLAUDE.md")
            if env.variables["CLAUDE_CODE_DISABLE_CLAUDE_MDS"].map({ !$0.isEmpty && $0 != "0" }) == true {
                for url in [managed, user] { add(url, .global, .skipped("CLAUDE_CODE_DISABLE_CLAUDE_MDS is set: Claude Code reads no CLAUDE.md")) }
                return
            }
            if add(managed, .global, .loaded) { imports(of: managed, .global, depth: 1) }
            if add(user, .global, .loaded) { imports(of: user, .global, depth: 1) }
            for rule in rules(in: config.appending(path: "rules")) { addRule(rule, .global) }

            // Its AGENTS.md plugin reads AGENTS.md only when no CLAUDE.md is in the project or
            // above. The user file doesn't count, even where the walk passes it (`~/.claude`); a
            // link to it elsewhere (`~/CLAUDE.md`) does: compared as written.
            let userPath = user.standardizedFileURL.path
            let hasClaudeFile = folders.contains { folder in
                ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"].contains { name in
                    let url = folder.appending(path: name)
                    return read(url) != nil && url.standardizedFileURL.path != userPath
                }
            }
            for folder in folders {
                let level = level(of: folder)
                for name in ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"] {
                    let url = folder.appending(path: name)
                    if add(url, level, .loaded) { imports(of: url, level, depth: 1) }
                }
                for rule in rules(in: folder.appending(path: ".claude/rules")) { addRule(rule, level) }
                for name in ["AGENTS.md", ".claude/AGENTS.md"] {
                    let url = folder.appending(path: name)
                    if hasClaudeFile {
                        add(url, level, .skipped("Claude Code reads AGENTS.md only when no CLAUDE.md is in the project or above it (unless @AGENTS.md imports it)"))
                    } else if add(url, level, .loaded) {
                        imports(of: url, level, depth: 1)
                    }
                }
            }
            // A file imported later than its skipped listing: the import wins.
            let loaded = Set(entries.filter(\.status.isLoaded).map { key($0.file) })
            let kept = entries.filter { $0.status.isLoaded || !loaded.contains(key($0.file)) }
            entries = kept
        }

        /// A rule with `paths:` in its front matter loads only when the agent works on a
        /// matching file; the others load in every session.
        mutating func addRule(_ url: URL, _ level: InstructionLevel) {
            guard let text = read(url) else { return }
            if InstructionText.frontMatterKeys(text).contains("paths") {
                add(url, level, .onDemand("Claude Code loads this rule only when a file matching its paths: is in play"), text: text)
            } else {
                add(url, level, .loaded, text: text)
            }
        }

        /// `.claude/rules/**/*.md`, sorted, at most 3 folders deep.
        func rules(in folder: URL) -> [URL] {
            var found: [URL] = []
            func walk(_ url: URL, _ depth: Int) {
                guard depth <= 3 else { return }
                for child in FileWalk.children(of: url).sorted(by: { $0.path < $1.path }) {
                    if FileWalk.isDirectory(child) { walk(child, depth + 1) }
                    else if child.pathExtension.lowercased() == "md" { found.append(child) }
                }
            }
            if FileWalk.isDirectory(folder) { walk(folder, 0) }
            return found
        }

        /// Claude Code's `@path` imports, after the file that has them; 4 hops at most.
        mutating func imports(of file: URL, _ level: InstructionLevel, depth: Int) {
            guard depth <= 4, let text = read(file) else { return }
            for path in InstructionText.imports(in: text) {
                let target = path.hasPrefix("~/") ? home.appending(path: String(path.dropFirst(2)))
                    : path.hasPrefix("/") ? URL(filePath: path) : file.deletingLastPathComponent().appending(path: path)
                if add(target.standardizedFileURL, level, .imported(by: file)) {
                    imports(of: target.standardizedFileURL, level, depth: depth + 1)
                }
            }
        }

        // MARK: Pi

        static let piNames = ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"]

        mutating func pi(folders: [URL]) {
            let agent = HarnessCatalog.configRoot(of: .pi, in: env) ?? home.appending(path: ".pi/agent")
            oneFile(in: agent, names: Self.piNames, level: .global, harness: "Pi")
            let shadowed = piShadowed()
            for folder in folders {
                oneFile(in: folder, names: Self.piNames, level: level(of: folder), harness: "Pi", shadowed: shadowed)
            }
        }

        /// Pi 1.0.4 `findShadowedContextFile`: in a linked worktree that lies inside the main
        /// checkout (`repo/.claude/worktrees/x`), the main checkout's file with the same name as
        /// the worktree's own file is skipped, since both are the same repository's text. The
        /// real path of that file, or nil.
        func piShadowed() -> String? {
            guard let project else { return nil }
            let fm = FileManager.default
            // The nearest .git from the project up, as Pi's `findGitPaths` does.
            for folder in InstructionScanner.chain(from: project, top: nil).reversed() {
                let git = folder.appending(path: ".git")
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: git.path, isDirectory: &isDirectory) else { continue }
                var common = git
                if !isDirectory.boolValue {
                    guard let line = read(git)?.trimmingCharacters(in: .whitespacesAndNewlines), line.hasPrefix("gitdir: ") else { return nil }
                    let target = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                    let gitDir = target.hasPrefix("/") ? URL(filePath: target) : folder.appending(path: target)
                    guard fm.fileExists(atPath: gitDir.appending(path: "HEAD").path) else { return nil }
                    common = gitDir
                    if let dir = read(gitDir.appending(path: "commondir"))?.trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty {
                        common = dir.hasPrefix("/") ? URL(filePath: dir) : gitDir.appending(path: dir)
                    }
                }
                let commonPath = real(common), worktree = real(folder)
                let main = (commonPath as NSString).deletingLastPathComponent
                guard worktree.hasPrefix(main + "/"), real(URL(filePath: main).appending(path: ".git")) == commonPath else { return nil }
                guard let name = Self.piNames.first(where: { read(URL(filePath: worktree).appending(path: $0)) != nil }) else { return nil }
                return real(URL(filePath: main).appending(path: name))
            }
            return nil
        }

        /// The first existing name of the list is the folder's file; the others are skipped. A
        /// second spelling of the same file (`AGENTS.MD` on a case-insensitive disk) is not listed.
        /// `shadowed`: a file Pi skips (see `piShadowed`).
        mutating func oneFile(in folder: URL, names: [String], level: InstructionLevel, harness: String,
                              skipEmpty: Bool = false, shadowed: String? = nil) {
            var spellings: Set<String> = []
            var winner: String?
            for name in names {
                let url = folder.appending(path: name)
                guard let text = read(url), spellings.insert(real(url)).inserted else { continue }
                if skipEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    add(url, level, .skipped("Empty: \(harness) skips it"), text: text)
                } else if let winner {
                    add(url, level, .skipped("\(harness) reads one file per folder: \(winner) comes first"), text: text)
                } else {
                    // The folder's file, even when it was listed before (a link to a file above).
                    winner = name
                    if let shadowed, real(url) == shadowed {
                        add(url, level, .skipped("Pi skips the main checkout's \(name): this worktree has its own"), text: text)
                    } else {
                        add(url, level, .loaded, text: text)
                    }
                }
            }
        }

        // MARK: Codex

        static let codexNames = ["AGENTS.override.md", "AGENTS.md"]
        /// `project_doc_max_bytes`: what Codex reads of the project's files in all.
        static let codexBudget = 32 * 1024

        mutating func codex(folders: [URL]) {
            let config = HarnessCatalog.configRoot(of: .codex, in: env) ?? home.appending(path: ".codex")
            oneFile(in: config, names: Self.codexNames, level: .global, harness: "Codex", skipEmpty: true)
            // From the git root down; without one, only the project folder.
            let root = folders.lastIndex { FileManager.default.fileExists(atPath: $0.appending(path: ".git").path) }
            var remaining = Self.codexBudget
            for folder in root.map({ Array(folders[$0...]) }) ?? Array(folders.suffix(1)) {
                let before = entries.count
                oneFile(in: folder, names: Self.codexNames, level: level(of: folder), harness: "Codex", skipEmpty: true)
                // Other names in the folder are not read at all.
                for name in ["CLAUDE.md"] {
                    add(folder.appending(path: name), level(of: folder), .skipped("Codex doesn't read CLAUDE.md (unless project_doc_fallback_filenames lists it)"))
                }
                guard let index = entries[before...].firstIndex(where: \.status.isLoaded) else { continue }
                let bytes = entries[index].bytes
                if remaining <= 0 {
                    entries[index].status = .skipped("Over Codex's 32 KiB for project files (project_doc_max_bytes)")
                    seen.remove(key(entries[index].file))
                } else if bytes > remaining {
                    entries[index].note = "Codex reads only its first \(remaining) bytes: 32 KiB for all project files (project_doc_max_bytes)"
                    entries[index].limit = remaining
                }
                remaining -= bytes
            }
        }

        // MARK: OpenCode

        mutating func openCode(folders: [URL]) {
            let config = HarnessCatalog.configRoot(of: .openCode, in: env) ?? home.appending(path: ".config/opencode")
            let noClaude = ["OPENCODE_DISABLE_CLAUDE_CODE", "OPENCODE_DISABLE_CLAUDE_CODE_PROMPT"]
                .contains { env.variables[$0].map { !$0.isEmpty && $0 != "0" && $0 != "false" } == true }
            let claudeUser = (HarnessCatalog.configRoot(of: .claudeCode, in: env) ?? home.appending(path: ".claude")).appending(path: "CLAUDE.md")
            var globalFound = false
            for url in [config.appending(path: "AGENTS.md")] + (noClaude ? [] : [claudeUser]) {
                if globalFound { add(url, .global, .skipped("OpenCode reads one global file: the first of ~/.config/opencode/AGENTS.md and ~/.claude/CLAUDE.md")) }
                else if add(url, .global, .loaded) { globalFound = true }
            }
            // Up from the project to the worktree root (the git root; without one, /).
            let root = folders.lastIndex { FileManager.default.fileExists(atPath: $0.appending(path: ".git").path) } ?? 0
            let up = Array(folders[root...].reversed())
            var winner: String?
            for name in ["AGENTS.md"] + (noClaude ? [] : ["CLAUDE.md"]) + ["CONTEXT.md"] {
                for folder in up {
                    let url = folder.appending(path: name)
                    if let winner {
                        add(url, level(of: folder), .skipped("OpenCode uses one file name for the whole tree: \(winner) was found first"))
                    } else {
                        add(url, level(of: folder), .loaded)
                    }
                }
                // The name wins when a file of it exists in the tree, even one listed before.
                if winner == nil, up.contains(where: { read($0.appending(path: name)) != nil }) {
                    winner = name
                }
            }
        }
    }
}

/// Where a file sits for the session.
public enum InstructionLevel: Hashable, Sendable {
    /// The harness's own config folder (or Claude Code's managed file).
    case global
    /// A folder above the project: every session below it gets the file.
    case above(URL)
    /// The project folder itself.
    case project
}

/// One file as one harness treats it.
public struct InstructionEntry: Identifiable, Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case loaded
        /// Claude Code: brought in by `@path` in another file.
        case imported(by: URL)
        /// Found, but this harness doesn't read it; the reason.
        case skipped(String)
        /// Read only in some sessions (a Claude Code rule with `paths:`); when.
        case onDemand(String)

        /// In every request of the session.
        public var isLoaded: Bool {
            switch self {
            case .loaded, .imported: true
            case .skipped, .onDemand: false
            }
        }
    }

    public let file: URL
    public let level: InstructionLevel
    public internal(set) var status: Status
    public let text: String
    /// A limit that applies (Codex cuts the text), shown with the file.
    public internal(set) var note: String?
    /// The bytes the harness reads of it when it cuts the file; nil: all of it.
    public internal(set) var limit: Int?

    public var id: String { file.path }
    public var bytes: Int { text.utf8.count }
    /// What reaches the model: all of it, or the part before the cut.
    public var sentBytes: Int { min(bytes, limit ?? bytes) }
    public var sections: [InstructionSection] { InstructionText.sections(text) }
}

/// What one harness loads for one session.
public struct InstructionView: Sendable {
    public let harness: HarnessID
    public let project: URL?
    /// Loaded files in the order the model gets them, skipped ones where they were found.
    public let entries: [InstructionEntry]

    public init(harness: HarnessID, project: URL?, entries: [InstructionEntry]) {
        self.harness = harness
        self.project = project
        self.entries = entries
    }

    public var loaded: [InstructionEntry] { entries.filter(\.status.isLoaded) }
    /// The bytes of every loaded file that reach the model (a file Codex cuts counts its first part).
    public var loadedBytes: Int { loaded.reduce(0) { $0 + $1.sentBytes } }
}
