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
/// Codex        one file in ~/.codex → one file per folder from the git root down; 32 KiB in all
/// OpenCode     the first global file → one file name for the whole tree, closest folder first
/// ```
///
/// Files in subfolders that load only when the agent touches a file there are not listed.
public enum InstructionScanner {
    /// What a session in `project` (nil: only the global files) gets from `harness`.
    /// `top`: the highest folder walked (tests); nil walks to `/`. `managed`: Claude Code's
    /// managed policy file.
    public static func view(harness: HarnessID, project: URL?, env: HarnessEnvironment, top: URL? = nil,
                            managed: URL = URL(filePath: "/Library/Application Support/ClaudeCode/CLAUDE.md")) -> InstructionView {
        var scan = Scan(env: env, project: project.map(\.standardizedFileURL))
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
        for _ in 0..<64 {
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

        func real(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

        /// Adds the file once (by real path); false when it doesn't exist or is already listed.
        @discardableResult
        mutating func add(_ url: URL, _ level: InstructionLevel, _ status: InstructionEntry.Status, note: String? = nil, text known: String? = nil) -> Bool {
            guard let text = known ?? read(url) else { return false }
            let key = real(url)
            if status.isLoaded {
                guard seen.insert(key).inserted else { return false }
            } else if seen.contains(key) || entries.contains(where: { real($0.file) == key }) {
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
            for rule in rules(in: config.appending(path: "rules")) { add(rule, .global, .loaded) }

            // Its AGENTS.md plugin reads AGENTS.md only when no CLAUDE.md is in the project or above.
            let userKey = real(user)
            let hasClaudeFile = folders.contains { folder in
                ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"].contains { name in
                    let url = folder.appending(path: name)
                    return read(url) != nil && real(url) != userKey
                }
            }
            for folder in folders {
                let level = level(of: folder)
                for name in ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"] {
                    let url = folder.appending(path: name)
                    if add(url, level, .loaded) { imports(of: url, level, depth: 1) }
                }
                for rule in rules(in: folder.appending(path: ".claude/rules")) { add(rule, level, .loaded) }
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
            let loaded = Set(entries.filter(\.status.isLoaded).map { real($0.file) })
            let kept = entries.filter { $0.status.isLoaded || !loaded.contains(real($0.file)) }
            entries = kept
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
            for folder in folders { oneFile(in: folder, names: Self.piNames, level: level(of: folder), harness: "Pi") }
        }

        /// The first existing name of the list is loaded; the others in the folder are skipped.
        /// Names as the folder lists them: on a case-insensitive disk `AGENTS.MD` would open
        /// `AGENTS.md` too, so a name counts only when a file is spelled that way.
        mutating func oneFile(in folder: URL, names: [String], level: InstructionLevel, harness: String, skipEmpty: Bool = false) {
            let present = Set(FileWalk.children(of: folder).map(\.lastPathComponent))
            var winner: String?
            for name in names where present.contains(name) {
                let url = folder.appending(path: name)
                guard let text = read(url) else { continue }
                if skipEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    add(url, level, .skipped("Empty: \(harness) skips it"), text: text)
                } else if let winner {
                    add(url, level, .skipped("\(harness) reads one file per folder: \(winner) comes first"), text: text)
                } else if add(url, level, .loaded, text: text) {
                    winner = name
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
                    seen.remove(real(entries[index].file))
                } else if bytes > remaining {
                    entries[index].note = "Codex reads only its first \(remaining) bytes: 32 KiB for all project files (project_doc_max_bytes)"
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
                if winner == nil, entries.contains(where: { $0.status.isLoaded && $0.file.lastPathComponent == name && $0.level != .global }) {
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

        public var isLoaded: Bool {
            if case .skipped = self { false } else { true }
        }
    }

    public let file: URL
    public let level: InstructionLevel
    public internal(set) var status: Status
    public let text: String
    /// A limit that applies (Codex cuts the text), shown with the file.
    public internal(set) var note: String?

    public var id: String { file.path }
    public var bytes: Int { text.utf8.count }
    public var sections: [InstructionSection] { InstructionText.sections(text) }
}

/// What one harness loads for one session.
public struct InstructionView: Sendable {
    public let harness: HarnessID
    public let project: URL?
    /// Loaded files in the order the model gets them, skipped ones where they were found.
    public let entries: [InstructionEntry]

    public var loaded: [InstructionEntry] { entries.filter(\.status.isLoaded) }
    /// The bytes of every loaded file (a file Codex cuts counts in full).
    public var loadedBytes: Int { loaded.reduce(0) { $0 + $1.bytes } }
}
