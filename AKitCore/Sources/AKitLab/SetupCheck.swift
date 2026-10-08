import AKitFoundation
import AKitSessions
import Foundation

/// What a control cell's setup must and must not show its agent (`docs/design/layer-evals.md`,
/// "Isolation check"): a removed skill or text never leaks into the wrong setup. Checked after
/// the clone and its overlay are ready and before the agent starts (no model call), in the clone
/// and wherever else Claude Code reads skills and instructions from for the cell (the clone's
/// parent folders, `~/.claude`); a violation stops the cell. After the agent, the skills its
/// transcript listed are checked too. Neutral: it knows names, texts and paths, not layers.
public struct SetupCheck: Codable, Sendable, Hashable {
    public struct Skill: Codable, Sendable, Hashable {
        public var name: String
        /// Started by the user only: its SKILL.md carries `disable-model-invocation: true`, and
        /// the model's listing leaves it out.
        public var manual: Bool
        /// Not started by the user: its SKILL.md carries `user-invocable: false`, and Claude
        /// Code's list of slash-invocable skills (the stream's init `skills`) leaves it out.
        public var hidden: Bool

        public init(name: String, manual: Bool, hidden: Bool = false) {
            self.name = name
            self.manual = manual
            self.hidden = hidden
        }

        private enum CodingKeys: String, CodingKey { case name, manual, hidden }

        /// Checks stored before `hidden` existed read as user-invocable.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            manual = try container.decode(Bool.self, forKey: .manual)
            hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        }

        /// From a rendered SKILL.md: manual with `disable-model-invocation: true` (or `manual`, the
        /// layer's mode), hidden with `user-invocable: false`.
        public static func of(_ name: String, skillFile text: String, manual: Bool = false) -> Skill {
            let header = SetupCheck.header(of: text)
            func value(_ key: String) -> String? { header.first { $0.key == key }?.value.lowercased() }
            return Skill(name: name, manual: manual || value("disable-model-invocation") == "true", hidden: value("user-invocable") == "false")
        }
    }

    public struct Text: Codable, Sendable, Hashable {
        /// "the swiftui layer's AGENTS.md text".
        public var label: String
        /// Trimmed of line breaks, as the render glues it.
        public var text: String
        /// Where the render puts it: `AGENTS.md` means a file Claude Code reads (`CLAUDE.md` or
        /// what it imports); any other path is that file.
        public var path: String

        public init(label: String, text: String, path: String) {
            self.label = label
            self.text = text
            self.path = path
        }
    }

    public struct File: Codable, Sendable, Hashable {
        public var path: String
        public var sha256: String

        public init(path: String, sha256: String) {
            self.path = path
            self.sha256 = sha256
        }
    }

    /// Skills the agent must find in the clone (`.claude/skills/<name>/SKILL.md`), with their mode.
    public var skills: [Skill]
    /// Skill names that must be nowhere the agent reads: another setup's skills, skills the
    /// layer turns off or its answers drop.
    public var absentSkills: [String]
    /// Texts that must be where the agent reads them.
    public var texts: [Text]
    /// Texts that must be in no instruction file the agent reads.
    public var absentTexts: [Text]
    /// Files of another setup that must not be in the clone with these bytes.
    public var absentFiles: [File]

    public init(skills: [Skill] = [], absentSkills: [String] = [], texts: [Text] = [], absentTexts: [Text] = [], absentFiles: [File] = []) {
        self.skills = skills
        self.absentSkills = absentSkills
        self.texts = texts
        self.absentTexts = absentTexts
        self.absentFiles = absentFiles
    }

    /// One thing of the check where it must not be: the clone's relative path, or an absolute
    /// path outside it.
    public struct Finding: Sendable, Hashable {
        public var what: String
        public var path: String
        /// The skill or command name, when the finding is one.
        public var skill: String?
    }

    // MARK: - Before the agent

    /// What the clone holds before any patch or overlay: the project's own files, which both
    /// setups have. They don't count as a leak (the overlap warning names such skills), and a
    /// skill the project has is the project's copy, not the layer's.
    public func projectContent(in clone: URL, home: URL) -> (findings: Set<Finding>, skills: Set<String>) {
        let scan = Self.scan(clone: clone, home: home, extra: absentTexts.map(\.path))
        return (Set(leaks(in: scan, clone: clone)), Set(scan.skills.map(\.name)))
    }

    /// Every way the prepared clone breaks the check, as lines naming the path and the skill,
    /// text or file; empty when it holds. `writes`: the overlay's placement, each of which must
    /// be in the clone as written. `projectContent`: `projectContent(in:)` before the overlay.
    public func problems(clone: URL, home: URL, writes: [ControlOverlay.Write],
                         projectContent: (findings: Set<Finding>, skills: Set<String>)) -> [String] {
        var problems: [String] = []
        let scan = Self.scan(clone: clone, home: home, extra: absentTexts.map(\.path) + texts.map(\.path))
        for finding in leaks(in: scan, clone: clone) where !projectContent.findings.contains(finding) {
            problems.append("\(finding.path) holds \(finding.what), which this setup must not have")
        }
        problems += outsideProblems(of: clone, home: home)
        // The overlay's writes, as placed.
        for write in writes {
            let url = clone.appending(path: write.path)
            switch write.action {
            case .link(let target):
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != target {
                    problems.append("\(write.path) is not the link to \(target) the overlay made")
                }
            case .create:
                if (try? Data(contentsOf: url)) != write.data { problems.append("\(write.path) doesn't hold the file the overlay wrote") }
            case .append:
                if write.data.isEmpty { continue }
                if (try? Data(contentsOf: url))?.range(of: write.data) == nil {
                    problems.append("\(write.path) doesn't hold the text the overlay appended")
                }
            }
        }
        // Skills where Claude Code finds them; the project's own copy wins over the layer's.
        for skill in skills where !projectContent.skills.contains(skill.name) {
            let path = ".claude/skills/\(skill.name)/SKILL.md"
            guard let text = try? String(contentsOf: clone.appending(path: path), encoding: .utf8) else {
                problems.append("the skill \(skill.name) is missing (\(path))")
                continue
            }
            if skill.manual, !Self.header(of: text).contains(where: { $0.key == "disable-model-invocation" && $0.value == "true" }) {
                problems.append("\(path) lacks disable-model-invocation: true, but \(skill.name) is a manual skill")
            }
        }
        // Texts where Claude Code reads them.
        for text in texts where !text.text.isEmpty {
            if text.path.lowercased() == "agents.md" {
                if !scan.readers.values.contains(where: { $0.contains(text.text) }) {
                    problems.append("\(text.label) is in no file Claude Code reads (CLAUDE.md, .claude/CLAUDE.md, CLAUDE.local.md and their imports)")
                }
            } else if !(scan.instructions[text.path] ?? "").contains(text.text) {
                problems.append("\(text.path) doesn't hold \(text.label)")
            }
        }
        return problems
    }

    /// What breaks the check outside a clone: in the parent folders Claude Code walks up
    /// through and in `~/.claude` (instructions, rules, skills and commands). Both setups share
    /// them, so a layer's skill or text there leaks into the setup without it. The queue checks
    /// this before any cell is paid.
    public func outsideProblems(of clone: URL, home: URL) -> [String] {
        outsideFindings(of: clone, home: home).map { finding in
            "\(finding.path) holds \(finding.what), which this setup must not have ("
                + (finding.skill != nil ? "move \(finding.path) elsewhere while the eval runs)" : "take that text out of it while the eval runs)")
        }
    }

    /// `outsideProblems` as findings: absolute paths.
    public func outsideFindings(of clone: URL, home: URL) -> [Finding] {
        leaks(in: Self.outsideScan(of: clone, home: home), clone: nil)
    }

    private func leaks(in scan: Scan, clone: URL?) -> [Finding] {
        var found: [Finding] = []
        let absent = Set(absentSkills)
        for skill in scan.skills where absent.contains(skill.name) {
            found.append(Finding(what: "the \(skill.command ? "command" : "skill") \(skill.name)", path: skill.path, skill: skill.name))
        }
        for (path, content) in scan.instructions.sorted(by: { $0.key < $1.key }) {
            for text in absentTexts where !text.text.isEmpty && content.contains(text.text) { found.append(Finding(what: text.label, path: path)) }
        }
        if let clone {
            for file in absentFiles {
                guard let data = try? Data(contentsOf: clone.appending(path: file.path)), Checksum.sha256(data) == file.sha256 else { continue }
                found.append(Finding(what: "the file \(file.path) of another setup", path: file.path))
            }
        }
        // Folder listings come in no fixed order.
        return found.sorted { ($0.path, $0.what) < ($1.path, $1.what) }
    }

    // MARK: - After the agent

    /// Checks what Claude Code loaded, from two sources: `loaded`, the `skills` of the stream's
    /// `system/init` (the slash-invocable skills: manual ones too, no `user-invocable: false`
    /// ones, no commands), and `listed`, the names of the transcript's `skill_listing` (what the
    /// model saw: no manual skills, hidden ones and commands too; synced and plugin skills carry a
    /// `prefix:`). Neither may name one of `absentSkills`; `loaded` must name every skill of the
    /// setup that isn't hidden; `listed` must name every one that isn't manual and none that is. A missing source is skipped; both missing is "not checked", never a
    /// failure. `projectSkills`: the project's own skills, which may show in any setup.
    public func afterRun(listed: Set<String>?, loaded: Set<String>? = nil, projectSkills: Set<String> = []) -> SetupCheckResult {
        guard listed != nil || loaded != nil else {
            return SetupCheckResult(status: .notChecked, detail: "the stream and the transcript name no skills; checked before the agent only")
        }
        let seen = (listed ?? []).union(loaded ?? [])
        var wrong: [String] = []
        let leaked = absentSkills.filter { seen.contains($0) && !projectSkills.contains($0) }.sorted()
        if !leaked.isEmpty { wrong.append("Claude Code loaded \(leaked.joined(separator: ", ")), which this setup must not have") }
        // The init's list holds the slash-invocable skills only: a hidden one isn't there, and
        // one both manual and hidden is in neither list, so only the check before the agent sees it.
        if let loaded {
            let missing = skills.filter { !$0.hidden && !loaded.contains($0.name) }.map(\.name).sorted()
            if !missing.isEmpty { wrong.append("Claude Code didn't load \(missing.joined(separator: ", "))") }
        }
        if let listed {
            let unlisted = skills.filter { !$0.manual && !listed.contains($0.name) }.map(\.name).sorted()
            if !unlisted.isEmpty { wrong.append("Claude Code didn't list \(unlisted.joined(separator: ", ")) to the model") }
            let manual = skills.filter { $0.manual && listed.contains($0.name) && !projectSkills.contains($0.name) }.map(\.name).sorted()
            if !manual.isEmpty { wrong.append("Claude Code listed the manual \(manual.joined(separator: ", ")) to the model") }
        }
        guard wrong.isEmpty else { return SetupCheckResult(status: .failed, detail: wrong.joined(separator: "; ")) }
        let sources = [loaded == nil ? nil : "the skills Claude Code loaded", listed == nil ? nil : "the skills it listed"].compactMap { $0 }
        return SetupCheckResult(status: .passed, detail: "before the agent, and " + sources.joined(separator: " and "))
    }

    /// The skill names of every `skill_listing` attachment in a Claude Code transcript (the
    /// session's own lines, not a subagent's); nil when it has none.
    public static func listedSkills(in transcript: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: transcript),
              let objects = try? JSONLines.objects(in: data, where: { JSONLines.contains($0, Data("skill_listing".utf8)) }) else { return nil }
        var names: Set<String>?
        for object in objects where object["type"] as? String == "attachment" && object["isSidechain"] as? Bool != true {
            guard let attachment = object["attachment"] as? JSONLines.Object, attachment["type"] as? String == "skill_listing" else { continue }
            names = (names ?? []).union(ClaudeLogFormat.listedSkills(attachment).map(\.name))
        }
        return names
    }

    // MARK: - Reading what Claude Code reads

    struct Scan {
        /// Skill folders by name (the folder's, and its SKILL.md `name:`) and command files
        /// (`commands/**.md`: the file name, `dir:name` in a subfolder), with their paths.
        var skills: [(name: String, path: String, command: Bool)] = []
        /// Instruction files and what they import, by path.
        var instructions: [String: String] = [:]
        /// The files Claude Code reads at the clone's root when it starts: `CLAUDE.md`,
        /// `.claude/CLAUDE.md`, `CLAUDE.local.md` and their imports.
        var readers: [String: String] = [:]
    }

    /// Folders never searched: build output and dependencies (a clone's own `.git` too).
    static let skipped: Set<String> = [".git", ".build", ".swiftpm", "node_modules", "Pods", "DerivedData", "__pycache__", "venv", ".venv"]
    static let instructionNames: Set<String> = ["claude.md", "claude.local.md", "agents.md"]
    /// An instruction file or import larger than this is not read (a log or data file someone imported).
    static let largestFile = 1 << 20

    /// The clone's skill folders (`.claude/skills/*` and `.agents/skills/*` in any folder, links
    /// followed one level), commands (`.claude/commands/**.md` in any folder) and instruction
    /// files (`CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md` in any folder, `.claude/rules/**.md`,
    /// and what they import; `@~/…` from `home`). `extra`: more files to read.
    static func scan(clone: URL, home: URL, extra: [String] = []) -> Scan {
        var scan = Scan()
        let fm = FileManager.default
        var instructionPaths = Set(extra.filter { !$0.isEmpty })
        if let walker = fm.enumerator(atPath: clone.path) {
            while let path = walker.nextObject() as? String {
                let type = walker.fileAttributes?[.type] as? FileAttributeType
                let parts = path.split(separator: "/").map(String.init)
                let name = parts.last ?? path
                if type == .typeDirectory, skipped.contains(name) {
                    walker.skipDescendants()
                    continue
                }
                let parent = parts.dropLast().suffix(2).map { $0.lowercased() }
                if parent == [".claude", "skills"] || parent == [".agents", "skills"], type == .typeDirectory || type == .typeSymbolicLink {
                    addSkill(at: clone.appending(path: path), path: path, to: &scan)
                } else if name == "skills", parts.dropLast().last.map({ [".claude", ".agents"].contains($0.lowercased()) }) == true,
                          type == .typeSymbolicLink {
                    // `.claude/skills` → `../.agents/skills`: the skills Claude Code finds through it.
                    for child in (try? fm.contentsOfDirectory(atPath: clone.appending(path: path).path)) ?? [] where !child.hasPrefix(".") {
                        addSkill(at: clone.appending(path: path).appending(path: child), path: path + "/" + child, to: &scan)
                    }
                }
                let lower = path.lowercased()
                if type != .typeDirectory, let range = lower.range(of: ".claude/commands/"), range.lowerBound == lower.startIndex
                    || lower[lower.index(before: range.lowerBound)] == "/" {
                    addCommand(String(path[range.upperBound...]), path: path, to: &scan)
                }
                if type != .typeDirectory, instructionNames.contains(name.lowercased())
                    || (lower.hasSuffix(".md") && (lower.hasPrefix(".claude/rules/") || lower.contains("/.claude/rules/"))) {
                    instructionPaths.insert(path)
                }
            }
        }
        for path in instructionPaths.sorted() {
            read(clone.appending(path: path), key: path, clone: clone, home: home, into: &scan.instructions, depth: 0)
        }
        for reader in ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"] {
            read(clone.appending(path: reader), key: reader, clone: clone, home: home, into: &scan.readers, depth: 0)
        }
        for path in scan.instructions.keys where path.lowercased().hasPrefix(".claude/rules/") {
            scan.readers[path] = scan.instructions[path]
        }
        return scan
    }

    /// Outside a clone: the parent folders Claude Code walks up through, links resolved
    /// (`CLAUDE.md`, `CLAUDE.local.md`, `.claude/CLAUDE.md`, `.claude/skills`, `.claude/commands`),
    /// and the user's `~/.claude` (`CLAUDE.md` and its imports, `rules/**.md`, `skills/*`,
    /// `commands/**.md`), by absolute path. Left out: plugin skills (`plugin:skill`) and the
    /// claude.ai skills in `skills/synced/` (`anthropic-skills:<name>`), whose names never equal
    /// a layer skill's; the overlap warning names them.
    static func outsideScan(of clone: URL, home: URL) -> Scan {
        var scan = Scan()
        let fm = FileManager.default
        func skills(in folder: URL) {
            for child in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where !child.hasPrefix(".") && child != "synced" {
                addSkill(at: folder.appending(path: child), path: folder.appending(path: child).path, to: &scan)
            }
        }
        func commands(in folder: URL) {
            guard let walker = fm.enumerator(atPath: folder.path) else { return }
            while let path = walker.nextObject() as? String {
                addCommand(path, path: folder.appending(path: path).path, to: &scan)
            }
        }
        // String paths with a bound: `URL("/").deletingLastPathComponent()` never stops. The
        // temporary folder is a link (`/var` → `/private/var`); Claude Code walks the real path.
        var folder = realPath(clone)
        for _ in 0..<64 {
            let parent = (folder as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != folder else { break }
            folder = parent
            let url = URL(filePath: folder, directoryHint: .isDirectory)
            for name in ["CLAUDE.md", "CLAUDE.local.md", ".claude/CLAUDE.md"] {
                read(url.appending(path: name), key: url.appending(path: name).path, clone: nil, home: home, into: &scan.instructions, depth: 0)
            }
            skills(in: url.appending(path: ".claude/skills"))
            // The home folder's own `.claude/commands` comes below, once.
            if folder != realPath(home) {
                commands(in: url.appending(path: ".claude/commands"))
            }
        }
        let claude = home.appending(path: ".claude", directoryHint: .isDirectory)
        read(claude.appending(path: "CLAUDE.md"), key: claude.appending(path: "CLAUDE.md").path, clone: nil, home: home,
             into: &scan.instructions, depth: 0)
        if let walker = fm.enumerator(atPath: claude.appending(path: "rules").path) {
            while let path = walker.nextObject() as? String {
                guard path.lowercased().hasSuffix(".md") else { continue }
                let url = claude.appending(path: "rules").appending(path: path)
                read(url, key: url.path, clone: nil, home: home, into: &scan.instructions, depth: 0)
            }
        }
        if !scan.skills.contains(where: { $0.path.hasPrefix(claude.appending(path: "skills").path + "/") }) {
            skills(in: claude.appending(path: "skills"))
        }
        commands(in: claude.appending(path: "commands"))
        return scan
    }

    /// The path with every link resolved by `realpath(3)`, `/private` included (Foundation's
    /// `resolvingSymlinksInPath` drops it again). The clone may not exist yet (at queueing): its
    /// nearest existing folder is resolved and the rest appended. Bounded string walk.
    static func realPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL.path
        var rest: [String] = []
        for _ in 0..<64 {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                return ([String(cString: resolved)] + rest.reversed()).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
            }
            let parent = (existing as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != existing else { break }
            rest.append((existing as NSString).lastPathComponent)
            existing = parent
        }
        return url.standardizedFileURL.path
    }

    private static func addSkill(at folder: URL, path: String, to scan: inout Scan) {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { return }
        let name = folder.lastPathComponent
        scan.skills.append((name, path, false))
        if let text = try? String(contentsOf: folder.appending(path: "SKILL.md"), encoding: .utf8),
           let declared = header(of: text).first(where: { $0.key == "name" })?.value, !declared.isEmpty, declared != name {
            scan.skills.append((declared, path, false))
        }
    }

    /// A command file, `relative` to its `commands` folder: `review.md` is `review`,
    /// `git/commit.md` is `git:commit`, as Claude Code names it.
    private static func addCommand(_ relative: String, path: String, to scan: inout Scan) {
        guard relative.lowercased().hasSuffix(".md") else { return }
        let name = String(relative.dropLast(3)).split(separator: "/").joined(separator: ":")
        guard !name.isEmpty else { return }
        scan.skills.append((name, path, true))
    }

    /// Reads an instruction file and, up to 5 levels deep, the files its `@path` lines import
    /// (relative to the file, or `@~/…` from the home folder). Keys: the clone's relative path
    /// when inside `clone`, else the absolute path. Files over `largestFile` are skipped, and a
    /// file that can't be read (a protected folder) is left out silently.
    private static func read(_ url: URL, key: String, clone: URL?, home: URL, into files: inout [String: String], depth: Int) {
        guard depth <= 5, files[key] == nil,
              ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) <= largestFile,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        files[key] = text
        let folder = url.deletingLastPathComponent()
        for match in text.matches(of: /(?:^|[\s(])@([^\s)`]+)/) {
            var name = String(match.1)
            while let last = name.last, ".,;:!?".contains(last) { name.removeLast() }
            guard !name.isEmpty, !name.contains("@") else { continue }
            let target: URL
            if name.hasPrefix("~/") {
                target = home.appending(path: String(name.dropFirst(2)))
            } else if name.hasPrefix("/") {
                target = URL(filePath: name)
            } else {
                target = folder.appending(path: name).standardizedFileURL
            }
            var imported = target.path
            if let clone {
                let root = clone.standardizedFileURL.path + "/"
                if imported.hasPrefix(root) { imported = String(imported.dropFirst(root.count)) }
            }
            read(target, key: imported, clone: clone, home: home, into: &files, depth: depth + 1)
        }
    }

    /// The `key: value` lines of a Markdown file's `---` header, keys and values trimmed (quotes too).
    public static func header(of text: String) -> [(key: String, value: String)] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) == "---"
        else { return [] }
        var pairs: [(key: String, value: String)] = []
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") else { continue }
            let quotes = CharacterSet(charactersIn: "\"'").union(.whitespaces)
            pairs.append((String(line[..<colon]).trimmingCharacters(in: quotes), String(line[line.index(after: colon)...]).trimmingCharacters(in: quotes)))
        }
        return pairs
    }
}

/// The setup check of a finished layer cell (`ControlOutcome.setupCheck`): the clone was
/// checked before the agent (a cell that failed that never ran), and the transcript's skill
/// listing after it. A failed one is left out of the comparison and the verdict.
public struct SetupCheckResult: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        case passed
        /// The listing named a skill the setup must not have, or missed one it must have.
        case failed
        /// The transcript has no skill listing: only the check before the agent ran.
        case notChecked = "not-checked"
    }

    public var status: Status
    /// What was checked, or what was wrong.
    public var detail: String

    public init(status: Status, detail: String) {
        self.status = status
        self.detail = detail
    }

    /// "setup check failed: Claude Code listed swiftui-expert, which this setup must not have".
    public var line: String {
        switch status {
        case .passed: "setup check passed (\(detail))"
        case .failed: "setup check failed: \(detail)"
        case .notChecked: "setup check: not checked after the agent (\(detail))"
        }
    }
}
