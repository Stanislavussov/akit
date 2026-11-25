import AKitFoundation
import AKitHarnesses
import AKitModel
import Foundation

/// A skill's mode in one project (skill-modes.md): Auto (listed to the model), Manual (only
/// `/skill:x` runs it) or Off (not listed, `/skill:x` refused). The same words in the file, the
/// command and the screen.
public enum SkillMode: String, CaseIterable, Codable, Hashable, Sendable {
    case auto, manual, off

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .manual: "Manual"
        case .off: "Off"
        }
    }
}

/// `~/.akit/local/skill-modes.json`: per project id, a mode per skill name. One file per Mac,
/// never in the brain or a repository. Pi's extension asks `akit skills resolve`, which reads
/// it with `read` and answers with `resolve`; nothing here writes (see `SkillModesWrite.swift`).
///
/// ```json
/// {"version": 1, "projects": {"github.com/owner/repo": {"tdd": "auto", "review": "off"}}}
/// ```
public enum SkillModes {
    public static let version = 1
    /// The name a personal skill gets in a project whose own skill of that name hides it.
    public static let renamePrefix = "my-"
    /// The largest file AKit reads; a real one holds a few hundred bytes per project.
    static let limit = 1 << 20

    public static func file(home: URL) -> URL { home.appending(path: ".akit/local/skill-modes.json") }

    // MARK: - Reading

    /// Something in the file that doesn't apply, or a skill that can't be renamed.
    public struct Problem: Codable, Hashable, Sendable {
        /// `file`: nothing in the file applies; `entry`: one entry is skipped; `rename`: a
        /// personal skill isn't added under its `my-` name.
        public let kind: String
        public let message: String
        public var project: String?
        public var name: String?

        public init(kind: String, message: String, project: String? = nil, name: String? = nil) {
            self.kind = kind
            self.message = message
            self.project = project
            self.name = name
        }
    }

    /// The file as read: the entries that apply, and what was skipped.
    public struct Reading: Sendable, Equatable {
        /// Project id → skill name → mode; only entries that apply.
        public var projects: [String: [String: SkillMode]] = [:]
        public var problems: [Problem] = []
        /// The file is there.
        public var exists = false
        /// false: the file doesn't parse, isn't an object or has another version; nothing in it
        /// applies and AKit doesn't rewrite it.
        public var usable = true

        public init(projects: [String: [String: SkillMode]] = [:], problems: [Problem] = [], exists: Bool = false, usable: Bool = true) {
            self.projects = projects
            self.problems = problems
            self.exists = exists
            self.usable = usable
        }

        /// The entries of one project; none for nil (a folder outside git).
        public func entries(for project: String?) -> [String: SkillMode] { project.flatMap { projects[$0] } ?? [:] }
    }

    /// Reads the file. A missing file is an empty reading; problems never throw.
    public static func read(_ url: URL, home: URL) -> Reading {
        let shown = FileWalk.tilde(url, home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return Reading() }
        guard let data = FileWalk.head(of: url, limit: limit + 1) else {
            return Reading(problems: [Problem(kind: "file", message: "\(shown) can't be read; no skill modes apply.")], exists: true, usable: false)
        }
        guard data.count <= limit else {
            return Reading(problems: [Problem(kind: "file", message: "\(shown) is larger than AKit reads (1 MB); no skill modes apply.")],
                           exists: true, usable: false)
        }
        return read(data: data, shown: shown)
    }

    /// Reads the file's bytes, entry by entry: an entry AKit can't use is skipped and reported,
    /// the rest apply. Only text that isn't a JSON object, or another `version`, makes the whole
    /// file unusable. `shown`: the file's name in messages.
    public static func read(data: Data, shown: String = "skill-modes.json") -> Reading {
        var reading = Reading(exists: true)
        func unusable(_ message: String) -> Reading {
            Reading(problems: [Problem(kind: "file", message: "\(shown) \(message); no skill modes apply. Fix the file (AKit won't change it).")],
                    exists: true, usable: false)
        }
        let value: JSONValue
        do {
            value = try JSONValue.parse(data)
        } catch {
            return unusable("is not valid JSON (\(error.message))")
        }
        guard let top = value.objectMembers else { return unusable("is not a JSON object") }
        guard case .number(let number)? = top["version"], Int(number) == version else {
            return unusable(top["version"] == nil ? "has no version" : "has version \(top["version"]!.compact), not \(version)")
        }
        guard let projects = top["projects"] else { return reading }
        guard let members = projects.objectMembers else { return unusable("has a \"projects\" that is not an object") }
        for (project, entries) in members.sorted(by: { $0.key < $1.key }) {
            guard let names = entries.objectMembers else {
                reading.problems.append(Problem(kind: "entry", message: "\(project): not an object of skill names; skipped.", project: project))
                continue
            }
            var modes: [String: SkillMode] = [:]
            for (name, raw) in names.sorted(by: { $0.key < $1.key }) {
                guard case .string(let word) = raw, let mode = SkillMode(rawValue: word) else {
                    reading.problems.append(Problem(kind: "entry", message: "\(project) \(name): \(raw.compact) is not auto, manual or off; skipped.",
                                                    project: project, name: name))
                    continue
                }
                modes[name] = mode
            }
            if !modes.isEmpty { reading.projects[project] = modes }
        }
        return reading
    }

    // MARK: - Resolving

    /// A skill Pi loaded, as the extension reports it (`sourceInfo.scope`, `sourceInfo.origin`,
    /// `filePath`).
    public struct LoadedSkill: Codable, Hashable, Sendable {
        public let name: String
        /// `user`, `project` or `temporary` (`--skill`, flows).
        public var scope: String?
        /// `top-level` or `package`.
        public var origin: String?
        public var path: String?

        public init(name: String, scope: String?, origin: String?, path: String?) {
            self.name = name
            self.scope = scope
            self.origin = origin
            self.path = path
        }

        /// A skill of the user's own folders (not a package's).
        public var isUsers: Bool { scope == "user" && origin != "package" }
    }

    /// A personal skill that a project's skill of the same name hides, added as `my-<name>`.
    public struct Rename: Codable, Hashable, Sendable {
        /// The name it hides behind (the project's skill keeps it).
        public let original: String
        /// Its SKILL.md and folder, as Pi would load them.
        public let file: String
        public let baseDir: String
        public let description: String
        /// The project's entry for `my-<name>`, else the file's own frontmatter.
        public let mode: SkillMode
        /// `project` (an entry) or `skill` (its SKILL.md).
        public let from: String
    }

    /// `akit skills resolve`'s answer: modes by skill name (only names with a project entry that
    /// a loaded, non-temporary skill or a rename has), renames by their `my-` name, problems.
    public struct Resolution: Codable, Hashable, Sendable {
        public var version = SkillModes.version
        public var project: String?
        public var modes: [String: SkillMode] = [:]
        public var renames: [String: Rename] = [:]
        public var problems: [Problem] = []

        public init(project: String?) { self.project = project }

        enum CodingKeys: String, CodingKey { case version, project, modes, renames, problems }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(project, forKey: .project)  // null outside git, not left out
            try container.encode(modes, forKey: .modes)
            try container.encode(renames, forKey: .renames)
            try container.encode(problems, forKey: .problems)
        }

        /// One line of JSON, keys sorted: what the extension reads.
        public var json: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
    }

    /// A folder Pi loads the user's own skills from, in Pi's order (the first name wins).
    public struct UserFolder: Hashable, Sendable {
        public let url: URL
        /// Lone `.md` files at its top are skills too (`~/.pi/agent/skills`, not `~/.agents/skills`).
        public let rootMarkdown: Bool

        public init(url: URL, rootMarkdown: Bool) {
            self.url = url
            self.rootMarkdown = rootMarkdown
        }
    }

    /// Pi's auto-discovered user skill folders (core/package-manager.js): `<agent dir>/skills`
    /// (`~/.pi/agent`, or PI_CODING_AGENT_DIR), then `~/.agents/skills`.
    public static func piUserFolders(in env: HarnessEnvironment) -> [UserFolder] {
        [UserFolder(url: env.piAgentDirectory.appending(path: "skills"), rootMarkdown: true),
         UserFolder(url: env.homeDirectory.appending(path: ".agents/skills"), rootMarkdown: false)]
    }

    /// The modes of a run in a project: the project's entries for the loaded skills (never a
    /// `temporary` one), and a `my-` rename for each personal skill a project's or package's skill
    /// of the same name hides. Reads only the user's skill folders, and only when a loaded skill
    /// isn't the user's.
    public static func resolve(file: Reading, skills: [LoadedSkill], projectID: String?, userFolders: [UserFolder]) -> Resolution {
        var result = Resolution(project: projectID)
        result.problems = file.problems
        let entries = file.usable ? file.entries(for: projectID) : [:]
        let loaded = Dictionary(skills.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        // Personal skills hidden behind a loaded skill of the same name at another path.
        let hiding = skills.filter { !$0.isUsers && $0.scope != "temporary" }
        if !hiding.isEmpty {
            let personal = personalSkills(in: userFolders, named: Set(hiding.map(\.name)))
            for skill in hiding {
                guard let mine = personal[skill.name], !samePath(mine.file, skill.path) else { continue }
                let renamed = renamePrefix + skill.name
                if loaded[renamed] != nil {
                    result.problems.append(Problem(kind: "rename", message: "Your \(skill.name) is hidden by the project's, and a skill named \(renamed) is loaded already; your \(skill.name) is not added.",
                                                   name: skill.name))
                    continue
                }
                let entry = entries[renamed]
                result.renames[renamed] = Rename(original: skill.name, file: mine.file.path, baseDir: mine.file.deletingLastPathComponent().path,
                                                 description: mine.description, mode: entry ?? (mine.manual ? .manual : .auto),
                                                 from: entry == nil ? "skill" : "project")
            }
        }
        for (name, mode) in entries where result.renames[name] == nil {
            guard let skill = loaded[name], skill.scope != "temporary" else { continue }
            result.modes[name] = mode
        }
        return result
    }

    /// The skills Pi loads in `folder`, in Pi's order of precedence (project, yours, packages; the
    /// first of a name wins), as the extension would report them. Scans the skill folders, so it is
    /// for the list and Doctor, not for `resolve`.
    public static func piSkills(in folder: URL, env: HarnessEnvironment) -> [LoadedSkill] {
        let installations = HarnessCatalog.detectAll(in: env).filter { $0.id == .pi }
        guard !installations.isEmpty else { return [] }
        let here = folder.standardizedFileURL.path
        func isHere(_ url: URL?) -> Bool { url.map { $0.standardizedFileURL.path == here } ?? false }
        var ranked: [(rank: Int, skill: LoadedSkill)] = []
        for skill in SkillScanner.scan(installations: installations, projects: [folder], in: env) where skill.visibleTo.contains(.pi) {
            let place = skill.places[.pi]
            let path = (place?.file ?? skill.file).path
            switch place?.scope ?? skill.scope {
            case .project(let url) where isHere(url):
                ranked.append((0, .init(name: skill.name, scope: "project", origin: "top-level", path: path)))
            case .global:
                ranked.append((1, .init(name: skill.name, scope: "user", origin: "top-level", path: path)))
            case .package(_, let project) where project == nil || isHere(project):
                ranked.append((2, .init(name: skill.name, scope: project == nil ? "user" : "project", origin: "package", path: path)))
            default:
                continue
            }
        }
        var seen = Set<String>()
        return ranked.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element.skill).filter { seen.insert($0.name).inserted }
    }

    /// Two paths name the same file (links resolved).
    static func samePath(_ file: URL, _ path: String?) -> Bool {
        guard let path else { return false }
        return file.resolvingSymlinksInPath().standardizedFileURL.path == URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    struct Personal {
        let file: URL
        let description: String
        let manual: Bool
    }

    /// The first skill of each wanted name in the user's folders, in Pi's order, read as Pi reads
    /// it: the SKILL.md `name` (else its folder's), a description that isn't empty.
    static func personalSkills(in folders: [UserFolder], named wanted: Set<String>) -> [String: Personal] {
        var found: [String: Personal] = [:]
        for folder in folders {
            var files: [URL] = []
            var visited = Set<String>()
            walk(folder.url, depth: 0, rootMarkdown: folder.rootMarkdown, visited: &visited, into: &files)
            for file in files {
                guard let data = FileWalk.head(of: file, limit: 256 << 10) else { continue }
                let text = String(decoding: data, as: UTF8.self)
                let fields = Frontmatter.parse(text)
                let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 }
                    ?? file.deletingLastPathComponent().lastPathComponent
                guard wanted.contains(name), found[name] == nil,
                      let description = fields["description"], !description.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                found[name] = Personal(file: file, description: description, manual: Frontmatter.disablesModelInvocation(text))
            }
        }
        return found
    }

    /// Pi's walk (core/skills.js): a folder with SKILL.md is a skill and the walk stops there;
    /// otherwise its folders (not hidden ones or node_modules), and lone `.md` files at the top
    /// when `rootMarkdown`. Depth is capped; ignore files are not read.
    static func walk(_ dir: URL, depth: Int, rootMarkdown: Bool, visited: inout Set<String>, into files: inout [URL]) {
        guard depth < 8, FileWalk.isDirectory(dir), visited.insert(dir.resolvingSymlinksInPath().path).inserted else { return }
        let skill = dir.appending(path: "SKILL.md")
        if FileWalk.isRegularFile(skill) {
            files.append(skill)
            return
        }
        for child in FileWalk.children(of: dir) where child.lastPathComponent != "node_modules" {
            if FileWalk.isDirectory(child) {
                walk(child, depth: depth + 1, rootMarkdown: rootMarkdown, visited: &visited, into: &files)
            } else if depth == 0, rootMarkdown, child.pathExtension == "md", FileWalk.isRegularFile(child) {
                files.append(child)
            }
        }
    }
}
