import AKitFoundation
import Foundation

/// Port to Pi: a Claude Code skill rewritten as a Pi skill (`docs/design/skill-port.md`). This is
/// the deterministic pass: the folder's files read into memory, the frontmatter cut down to the
/// fields Pi reads, plain path and command replacements, and the OMC role prompts the skill names
/// copied into `references/`. The model pass (AKitLab `SkillPortModel`) rewrites what needs
/// judgment; `SkillPortCheck` validates the result; `install` writes it after a preview.
public enum SkillPort {
    public static let skillFile = "SKILL.md"
    /// Frontmatter fields Pi reads (the Agent Skills standard plus `disable-model-invocation`);
    /// every other field (`allowed-tools`, `model`, `agent`, `context`, `hooks`, `argument-hint`,
    /// `user-invocable`, …) is Claude Code's and is dropped.
    public static let keptFields: Set<String> = ["name", "description", "license", "compatibility", "metadata", "disable-model-invocation"]
    /// OMC roles named in prose (not only in `subagent_type=`) whose prompt is copied.
    public static let proseRoles = ["architect", "critic", "planner", "analyst", "executor", "verifier"]
    /// A skill folder bigger than this is not read: a skill is a few files.
    static let maxFiles = 400
    static let maxBytes = 8_000_000

    /// A ported skill in memory: every text file as ported, the original texts, and the files
    /// copied unchanged.
    public struct Draft: Sendable, Hashable {
        /// The `name` of the SKILL.md (else the folder name): the Pi folder's name.
        public var name: String
        public var source: URL
        /// Relative path → ported text, for every text file and each added role prompt.
        public var texts: [String: String]
        /// Relative path → the source's text.
        public var originals: [String: String]
        /// Relative paths copied as they are (not UTF-8 text).
        public var binaries: [String]
        /// What the passes changed, one line each.
        public var changes: [String]
        /// Role prompts copied into `references/<role>.md`.
        public var roles: [String]

        public var skillText: String { texts[SkillPort.skillFile] ?? "" }
        /// Every path of the port.
        public var paths: Set<String> { Set(texts.keys).union(binaries) }
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    // MARK: Reading

    /// Reads the skill folder and runs the deterministic pass.
    public static func port(folder: URL, env: HarnessEnvironment) throws -> Draft {
        let files = try read(folder)
        guard let skill = files.texts[skillFile] else { throw Failure("\(folder.path) has no \(skillFile).") }
        let name = Frontmatter.parse(skill)["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
        var draft = Draft(name: name, source: folder, texts: [:], originals: files.texts, binaries: files.binaries, changes: [], roles: [])
        var notes: [String: Int] = [:]
        for (path, text) in files.texts {
            let result = transform(text, path: path)
            draft.texts[path] = result.text
            for note in result.notes { notes[note, default: 0] += 1 }
            if path == skillFile, !result.dropped.isEmpty {
                draft.changes.append("Frontmatter: dropped \(result.dropped.joined(separator: ", ")) (Claude Code only)")
            }
        }
        draft.changes += notes.keys.sorted().map { notes[$0]! > 1 ? "\($0) (\(notes[$0]!) files)" : $0 }
        for role in roles(in: Array(files.texts.values)) where draft.texts["references/\(role).md"] == nil && !draft.binaries.contains("references/\(role).md") {
            guard let file = roleFile(role, near: folder, env: env), let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            draft.texts["references/\(role).md"] = transform(text, path: "references/\(role).md").text
            draft.roles.append(role)
        }
        if !draft.roles.isEmpty {
            draft.changes.append("Copied role prompts into references/: \(draft.roles.map { "\($0).md" }.joined(separator: ", "))")
        }
        return draft
    }

    /// The text files (UTF-8, no NUL) and the other files of a folder, by relative path; hidden
    /// files and folders (`.git`, `.DS_Store`) are left out.
    public static func read(_ folder: URL) throws -> (texts: [String: String], binaries: [String]) {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw Failure("\(folder.path) is not a folder.")
        }
        let base = folder.resolvingSymlinksInPath().standardizedFileURL
        guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { throw Failure("Can't read \(folder.path).") }
        var texts: [String: String] = [:]
        var binaries: [String] = []
        var bytes = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            guard texts.count + binaries.count < maxFiles else { throw Failure("\(folder.path) has more than \(maxFiles) files: not a skill to port.") }
            bytes += values?.fileSize ?? 0
            guard bytes <= maxBytes else { throw Failure("\(folder.path) holds more than \(maxBytes / 1_000_000) MB: not a skill to port.") }
            let path = String(url.standardizedFileURL.path.dropFirst(base.path.count + 1))
            let data = (try? Data(contentsOf: url)) ?? Data()
            if !data.contains(0), let text = String(data: data, encoding: .utf8) {
                texts[path] = text
            } else {
                binaries.append(path)
            }
        }
        return (texts, binaries.sorted())
    }

    // MARK: Transforms

    /// The deterministic pass on one file: frontmatter (SKILL.md only), replacements (tool names
    /// in Markdown only). Running it twice changes nothing more.
    public static func transform(_ text: String, path: String) -> (text: String, notes: [String], dropped: [String]) {
        var result = text
        var dropped: [String] = []
        if path == skillFile {
            (result, dropped) = portFrontmatter(result)
        }
        var notes: [String] = []
        for replacement in replacements where !replacement.markdownOnly || path.lowercased().hasSuffix(".md") {
            let changed = replace(replacement.pattern, in: result, with: replacement.template)
            if changed != result { notes.append(replacement.note) }
            result = changed
        }
        return (result, notes, dropped)
    }

    /// The header with only `keptFields`; nil-safe: a text without a header comes back as it is.
    /// A field is its top-level line plus the indented, empty and comment lines under it.
    public static func portFrontmatter(_ text: String) -> (text: String, dropped: [String]) {
        var lines = text.components(separatedBy: "\n")
        guard let header = Frontmatter.header(in: lines) else { return (text, []) }
        var kept: [String] = []
        var dropped: [String] = []
        var keep = true
        for line in lines[header] {
            if let first = line.first, first != " ", first != "\t", first != "#", let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                keep = keptFields.contains(key)
                if !keep { dropped.append(key) }
            }
            if keep { kept.append(line) }
        }
        guard !dropped.isEmpty else { return (text, []) }
        lines.replaceSubrange(header, with: kept)
        return (lines.joined(separator: "\n"), dropped)
    }

    struct Replacement {
        let pattern: String
        /// `$1`… are the pattern's groups.
        let template: String
        let note: String
        var markdownOnly = false
    }

    /// In order: longer paths before their prefixes.
    static let replacements: [Replacement] = [
        Replacement(pattern: #"(?<![\w/.:~-])/[a-z0-9][a-z0-9-]*:([a-z0-9][a-z0-9-]*)"#, template: "/skill:$1",
                    note: "Commands /plugin:name → /skill:name"),
        Replacement(pattern: #"~/\.claude/skills"#, template: "~/.pi/agent/skills", note: "Paths ~/.claude/skills → ~/.pi/agent/skills"),
        Replacement(pattern: #"(?<![\w~/])\.claude/skills"#, template: ".pi/skills", note: "Paths .claude/skills → .pi/skills"),
        Replacement(pattern: #"(?<![\w.])\.omc/state/"#, template: ".pi/state/", note: "State .omc/ → .pi/state/"),
        Replacement(pattern: #"(?<![\w.])\.omc/"#, template: ".pi/state/", note: "State .omc/ → .pi/state/"),
        Replacement(pattern: #"\b(?:Read|Write|Edit|Bash)\("#, template: "", note: "Tool calls Read/Write/Edit/Bash → read/write/edit/bash",
                    markdownOnly: true),
        Replacement(pattern: #"`?\b(Read|Write|Edit|Bash|Glob|Grep)\b`? tool"#, template: "", note: "Tool names → Pi's read/write/edit/bash",
                    markdownOnly: true),
    ]

    /// Pi's tool for a Claude Code tool named in prose: Glob and Grep become commands run with bash.
    static let piTools = ["Read": "`read` tool", "Write": "`write` tool", "Edit": "`edit` tool", "Bash": "`bash` tool",
                          "Glob": "`find` command via the `bash` tool", "Grep": "`grep` command via the `bash` tool"]

    static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        guard !template.isEmpty else {
            // Tool names: computed per match.
            var result = ""
            var last = text.startIndex
            for match in regex.matches(in: text, range: range) {
                guard let whole = Range(match.range, in: text) else { continue }
                result += text[last..<whole.lowerBound]
                let found = String(text[whole])
                if found.hasSuffix("(") {
                    result += found.dropLast().lowercased() + "("
                } else if match.numberOfRanges > 1, let tool = Range(match.range(at: 1), in: text) {
                    result += piTools[String(text[tool])] ?? found
                } else {
                    result += found
                }
                last = whole.upperBound
            }
            return result + text[last...]
        }
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    // MARK: Roles

    /// OMC roles the texts name: `subagent_type="…:role"`, `oh-my-claudecode:role`, and the
    /// `proseRoles` as words. Only those with a prompt file are copied.
    public static func roles(in texts: [String]) -> [String] {
        var found = Set<String>()
        let patterns = [#"subagent_type\s*[=:]\s*["']?(?:[\w-]+:)?([a-z][\w-]*)"#, #"oh-my-claudecode:([a-z][\w-]*)"#,
                        #"\b(\#(proseRoles.joined(separator: "|")))\b"#]
        for text in texts {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let range = Range(match.range(at: 1), in: text) { found.insert(String(text[range])) }
                }
            }
        }
        return found.sorted()
    }

    /// The prompt file of an OMC role: `agents/<role>.md` of the plugin the skill is in (up to
    /// three folders above it, never the home folder or above), else the newest one under
    /// `~/.claude/plugins` (at most 7 levels deep).
    public static func roleFile(_ role: String, near folder: URL, env: HarnessEnvironment) -> URL? {
        let fm = FileManager.default
        let home = env.homeDirectory.standardizedFileURL.path
        var parent = folder.standardizedFileURL
        for _ in 0..<3 {
            parent = parent.deletingLastPathComponent()
            guard parent.path.hasPrefix(home + "/"), parent.path != home else { break }
            let file = parent.appending(path: "agents/\(role).md")
            if fm.fileExists(atPath: file.path) { return file }
        }
        let plugins = env.homeDirectory.appending(path: ".claude/plugins", directoryHint: .isDirectory)
        guard let walker = fm.enumerator(at: plugins, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        var best: (url: URL, date: Date)?
        for case let url as URL in walker {
            if walker.level > 7 { walker.skipDescendants(); continue }
            guard url.lastPathComponent == "\(role).md", url.deletingLastPathComponent().lastPathComponent == "agents" else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || date > best!.date { best = (url, date) }
        }
        return best?.url
    }

    // MARK: Writing

    public enum Target: Hashable, Sendable {
        /// `~/.pi/agent/skills/<name>`.
        case global
        /// `<project>/.pi/skills/<name>`.
        case project(URL)
    }

    public static func folder(for target: Target, name: String, env: HarnessEnvironment) -> URL {
        switch target {
        case .global: env.homeDirectory.appending(path: ".pi/agent/skills/\(name)", directoryHint: .isDirectory)
        case .project(let project): project.appending(path: ".pi/skills/\(name)", directoryHint: .isDirectory)
        }
    }

    /// What installing writes: the folder, whether one is there (it goes to the Trash), and the
    /// diff of its SKILL.md (from empty when there is none).
    public struct InstallPlan: Sendable {
        public let folder: URL
        public let replaces: Bool
        public let diff: [TextDiff.Line]
        /// Paths whose text differs from the folder there now (all of them for a new folder).
        public let changed: [String]
    }

    public static func plan(_ draft: Draft, target: Target, env: HarnessEnvironment) -> InstallPlan {
        let folder = folder(for: target, name: draft.name, env: env)
        let replaces = FileManager.default.fileExists(atPath: folder.path)
        let old = replaces ? (try? read(folder)) : nil
        let oldSkill = old?.texts[skillFile] ?? ""
        let changed = draft.paths.sorted().filter { path in
            guard let old else { return true }
            if let text = draft.texts[path] { return old.texts[path] != text }
            return !old.binaries.contains(path)
        }
        return InstallPlan(folder: folder, replaces: replaces, diff: TextDiff.lines(from: oldSkill, to: draft.skillText), changed: changed)
    }

    /// Writes the draft into a hidden folder next to the target, moves the folder there now to
    /// the Trash (`trash`), then puts the new one in its place. Refuses when the target appeared or
    /// went away since the plan. Returns where the old folder went.
    @discardableResult
    public static func install(_ draft: Draft, plan: InstallPlan, trash: (URL) throws -> URL? = Trash.move) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: plan.folder.path) == plan.replaces else {
            throw Failure("\(plan.folder.path) changed since the preview. Run the port again.")
        }
        let parent = plan.folder.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(path: ".\(draft.name).akit-port-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        do {
            try write(draft, to: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw Failure("Couldn't write the port: \(error.localizedDescription)")
        }
        var trashed: URL?
        if plan.replaces {
            do { trashed = try trash(plan.folder) } catch {
                try? fm.removeItem(at: staging)
                throw Failure("Couldn't move the old \(plan.folder.path) to the Trash: \(error.localizedDescription)")
            }
        }
        try fm.moveItem(at: staging, to: plan.folder)
        return trashed
    }

    /// The draft's files in `folder` (made): texts as ported, the other files copied from the source.
    public static func write(_ draft: Draft, to folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, text) in draft.texts {
            let file = folder.appending(path: path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            if let mode = try? fm.attributesOfItem(atPath: draft.source.appending(path: path).path)[.posixPermissions] {
                try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
            }
        }
        for path in draft.binaries {
            let file = folder.appending(path: path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: draft.source.appending(path: path), to: file)
        }
    }
}
