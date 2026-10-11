import AKitFoundation
import AKitHarnesses
import AKitModel
import Foundation

/// Finds skills on disk. Read-only: never writes anything.
public enum SkillScanner {
    /// Scan all skill roots of the installed harnesses and merge duplicates
    /// (the same real file reached through several roots/symlinks).
    /// `extraProjects`: folders found in the user's project roots (see ProjectFinder).
    /// `projects`, `piPackages` and `piHidden`: already computed by the caller (`projects(...)`,
    /// `PiPackages.list`, `PiPackages.skillsHidden(projects:packages:)`), so a refresh reads them
    /// once; nil = computed here.
    public static func scan(installations: [HarnessInstallation],
                            extraProjects: [URL] = [],
                            adapters: [any HarnessAdapter] = HarnessCatalog.adapters,
                            projects knownProjects: [URL]? = nil,
                            piPackages: [PiPackage]? = nil,
                            piHidden: [String: Set<String>]? = nil,
                            claudeMaxDescChars: Int? = nil,
                            in env: HarnessEnvironment) -> [Skill] {
        let installed = Set(installations.map(\.id))
        let active = adapters.filter { installed.contains($0.id) }
        let projects = knownProjects
            ?? projects(installations: installations, extraProjects: extraProjects, adapters: adapters, in: env)
        let packages = !installed.contains(.pi) ? []
            : piPackages ?? HarnessCatalog.configRoot(of: .pi, in: env).map {
                PiPackages.list(configRoot: $0, projects: projects, in: env).packages
            } ?? []

        // First root wins the scope; equal ranks keep their order (global packages before project ones).
        let roots = (active.flatMap { $0.skillRoots(in: env, projects: projects) } + PiPackages.skillRoots(packages))
            .enumerated()
            .sorted { ($0.element.scope.sortRank, $0.offset) < ($1.element.scope.sortRank, $1.offset) }
            .map(\.element)
        // Only files under Claude's own `skills/synced/` count as claude.ai skills.
        let syncedFolders = roots.compactMap(\.syncedFolder).map { $0.resolvingSymlinksInPath().path + "/" }
        let hidden = piHidden ?? PiPackages.skillsHidden(projects: projects, packages: packages)
        return merge(roots.flatMap { found(in: $0) }, lock: SkillLock.read(in: env), home: env.homeDirectory,
                     syncedFolders: syncedFolders, hiddenInProject: hidden,
                     claudeMaxDescChars: claudeMaxDescChars ?? Self.claudeMaxDescChars(in: env))
    }

    /// Project folders the installed harnesses know about plus `extraProjects`, existing ones, no duplicates.
    /// The home folder is not a project: its skill folders are the global ones.
    public static func projects(installations: [HarnessInstallation], extraProjects: [URL] = [],
                                adapters: [any HarnessAdapter] = HarnessCatalog.adapters,
                                in env: HarnessEnvironment) -> [URL] {
        let installed = Set(installations.map(\.id))
        var seen: Set<String> = [env.homeDirectory.standardizedFileURL.path]
        return (adapters.filter { installed.contains($0.id) }.flatMap { $0.knownProjects(in: env) } + extraProjects)
            .filter { FileWalk.isDirectory($0) }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    // MARK: - Walking

    /// A skill file found through one root.
    struct Hit {
        let file: URL
        let root: SkillRoot
        let isSingleFile: Bool
    }

    static func found(in root: SkillRoot) -> [Hit] {
        guard FileWalk.isDirectory(root.url) else { return [] }
        switch root.layout {
        case .flat(let rootMayBeSkill):
            if rootMayBeSkill, hasSkillFile(root.url) {
                return [Hit(file: root.url.appending(path: "SKILL.md"), root: root, isSingleFile: false)]
            }
            var hits: [Hit] = []
            for child in FileWalk.children(of: root.url) where FileWalk.isDirectory(child) {
                if let synced = root.syncedFolder, child.path == synced.path {
                    // synced/<bucket>/<name>/SKILL.md
                    for bucket in FileWalk.children(of: child) where FileWalk.isDirectory(bucket) {
                        for skill in FileWalk.children(of: bucket) where hasSkillFile(skill) {
                            hits.append(Hit(file: skill.appending(path: "SKILL.md"), root: root, isSingleFile: false))
                        }
                    }
                } else if hasSkillFile(child) {
                    hits.append(Hit(file: child.appending(path: "SKILL.md"), root: root, isSingleFile: false))
                }
            }
            return hits

        case .listed(let files):
            // A package lists its own files only; checked again here, as the list came from package data.
            return files.filter { isFile($0) && FileWalk.isInside($0, root.url) && !PiPackages.secretNames.contains($0.lastPathComponent) }
                .map { Hit(file: $0, root: root, isSingleFile: $0.lastPathComponent != "SKILL.md") }

        case .recursive(let rootMarkdown):
            var hits: [Hit] = []
            var visited = Set<String>()
            walk(root.url, depth: 0, root: root, rootMarkdown: rootMarkdown, visited: &visited, into: &hits)
            return hits
        }
    }

    /// Mirrors Pi's loader: a folder with SKILL.md is a skill (stop there);
    /// otherwise descend, skipping hidden folders and node_modules.
    /// Differences from Pi: depth is capped and .gitignore/.ignore rules are not applied.
    private static func walk(_ dir: URL, depth: Int, root: SkillRoot, rootMarkdown: Bool,
                             visited: inout Set<String>, into hits: inout [Hit]) {
        guard depth < 8, visited.insert(dir.resolvingSymlinksInPath().path).inserted else { return }
        if hasSkillFile(dir) {
            hits.append(Hit(file: dir.appending(path: "SKILL.md"), root: root, isSingleFile: false))
            return
        }
        for child in FileWalk.children(of: dir) {
            if child.lastPathComponent == "node_modules" { continue }
            if FileWalk.isDirectory(child) {
                walk(child, depth: depth + 1, root: root, rootMarkdown: rootMarkdown, visited: &visited, into: &hits)
            } else if depth == 0, rootMarkdown, child.pathExtension == "md", isFile(child) {
                hits.append(Hit(file: child, root: root, isSingleFile: true))
            }
        }
    }

    // MARK: - Merging

    static func merge(_ hits: [Hit], lock: SkillLock, home: URL, syncedFolders: [String] = [],
                      hiddenInProject: [String: Set<String>] = [:], claudeMaxDescChars: Int = defaultClaudeMaxDescChars) -> [Skill] {
        var byID: [String: Skill] = [:]
        var order: [String] = []
        var piMissingDescription = Set<String>()
        /// The description's length as each harness sends it (UTF-16 units, as their JavaScript counts).
        var lengths: [String: (claude: Int, pi: Int)] = [:]

        for hit in hits {
            let real = hit.file.resolvingSymlinksInPath()
            let id = real.path
            let place = Skill.Place(file: hit.file, base: hit.root.url.deletingLastPathComponent(), scope: hit.root.scope)
            if var existing = byID[id] {
                if !existing.visibleTo.contains(hit.root.harness) { existing.visibleTo.append(hit.root.harness) }
                if existing.places[hit.root.harness] == nil { existing.places[hit.root.harness] = place }
                byID[id] = existing
                continue
            }
            guard let text = readHead(hit.file) else { continue }
            let meta = Frontmatter.parse(text)
            let folderName = hit.file.deletingLastPathComponent().lastPathComponent
            let name = meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folderName
            let description = meta["description"] ?? ""
            if description.trimmingCharacters(in: .whitespaces).isEmpty { piMissingDescription.insert(id) }
            // Claude Code lists `description - when_to_use`; Pi only the description.
            let whenToUse = meta["when_to_use"].flatMap { $0.isEmpty ? nil : $0 }
            lengths[id] = ((whenToUse.map { "\(description) - \($0)" } ?? description).utf16.count, description.utf16.count)

            let isSynced = syncedFolders.contains { id.hasPrefix($0) }
            let scope: SkillScope = isSynced ? .synced : hit.root.scope
            var origin = hit.root.origin
            if isSynced { origin = "claude.ai" }
            if origin == nil, !hit.isSingleFile, let source = lock.source(forSkillFolder: real.deletingLastPathComponent()) {
                origin = source
            }
            byID[id] = Skill(name: name, description: description, file: hit.file, realFile: real,
                             isSingleFile: hit.isSingleFile, scope: scope, visibleTo: [hit.root.harness],
                             isReadOnly: hit.root.isReadOnly || isSynced, origin: origin, warnings: [],
                             root: hit.root.url.resolvingSymlinksInPath(),
                             disablesModelInvocation: meta["disable-model-invocation"]?.lowercased() == "true",
                             places: [hit.root.harness: place])
            order.append(id)
        }

        var skills = order.compactMap { byID[$0] }
        for index in skills.indices {
            skills[index].visibleTo.sort()
            let skill = skills[index]
            guard skill.visibleTo.contains(.pi) else { continue }
            if piMissingDescription.contains(skill.id) {
                // Pi skips a skill without a description entirely.
                skills[index].visibleTo.removeAll { $0 == .pi }
                skills[index].warnings.append("Pi ignores this skill: description is missing")
            } else {
                skills[index].warnings += PiNameRule.problems(skill.name).map { "Pi: \($0)" }
            }
        }
        for index in skills.indices {
            guard let length = lengths[skills[index].id] else { continue }
            skills[index].warnings += descriptionProblems(claude: skills[index].visibleTo.contains(.claudeCode) ? length.claude : nil,
                                                         pi: skills[index].visibleTo.contains(.pi) ? length.pi : nil,
                                                         claudeMaxDescChars: claudeMaxDescChars)
        }
        addCollisionWarnings(&skills, home: home, hiddenInProject: hiddenInProject)
        return skills
    }

    /// The skill folders the installed harnesses load from (links resolved), global ones and those
    /// of these projects; plugin, claude.ai and package folders left out (AKit never removes there).
    public static func rootFolders(projects: [URL], in env: HarnessEnvironment) -> [URL] {
        let installed = Set(HarnessCatalog.detectAll(in: env).map(\.id))
        return HarnessCatalog.adapters.filter { installed.contains($0.id) }
            .flatMap { $0.skillRoots(in: env, projects: projects) }
            .filter { root in
                switch root.scope {
                case .global, .project: !root.isReadOnly
                case .synced, .plugin, .bundled, .package: false
                }
            }
            .map { $0.url.resolvingSymlinksInPath().standardizedFileURL }
    }

    /// Claude Code's default `skillListingMaxDescChars` (2.1.296).
    public static let defaultClaudeMaxDescChars = 1536
    /// Pi warns above this many characters (1.0.4 `MAX_DESCRIPTION_LENGTH`) and still sends the whole text.
    public static let piDescriptionWarning = 1024

    /// Description lengths a harness cuts or warns about. `claude`: `description - when_to_use`, nil when
    /// Claude Code doesn't see the skill; `pi`: the description, nil when Pi doesn't.
    static func descriptionProblems(claude: Int?, pi: Int?, claudeMaxDescChars: Int) -> [String] {
        var problems: [String] = []
        if let claude, claude > claudeMaxDescChars {
            problems.append("Claude Code cuts its description at \(claudeMaxDescChars) characters (it has \(claude), with when_to_use); the rest never reaches the model")
        }
        if let pi, pi > piDescriptionWarning {
            problems.append("Pi warns: description over \(piDescriptionWarning) characters (\(pi)); Pi still sends it all")
        }
        return problems
    }

    /// `skillListingMaxDescChars` from `~/.claude/settings.json` (`CLAUDE_CONFIG_DIR` honoured), else
    /// the default. Read leniently: a file that can't be read gives the default (the skill switches report it).
    public static func claudeMaxDescChars(in env: HarnessEnvironment) -> Int {
        guard let file = HarnessCatalog.configRoot(of: .claudeCode, in: env)?.appending(path: "settings.json"),
              let read = try? SettingsFile.read(file, home: env.homeDirectory),
              case .number(let text)? = read.value.value(at: ["skillListingMaxDescChars"]), let value = Int(text), value > 0
        else { return defaultClaudeMaxDescChars }
        return value
    }

    /// The start of a skill file: enough for its frontmatter, never a whole huge file.
    static func readHead(_ file: URL, limit: Int = 256 << 10) -> String? {
        guard let data = FileWalk.head(of: file, limit: limit) else { return nil }
        // A cut may split a character; only a whole file must be valid UTF-8.
        return data.count < limit ? String(data: data, encoding: .utf8) : String(decoding: data, as: UTF8.self)
    }

    /// Two different skills with one name that a harness would load in the same session.
    /// A session sees the global skills plus ONE project, so two projects never collide.
    /// Claude namespaces plugin skills (`plugin:skill`), so they never collide for Claude.
    /// `hiddenInProject`: per project path, ids (real paths) of global Pi package skills that a
    /// session there doesn't load, because the project's settings replace or narrow that package.
    static func addCollisionWarnings(_ skills: inout [Skill], home: URL, hiddenInProject: [String: Set<String>] = [:]) {
        let projects = Set(skills.compactMap { skill -> URL? in
            switch skill.scope {
            case .project(let url), .package(_, let url?): url
            default: nil
            }
        })
        let contexts: [URL?] = projects.isEmpty ? [nil] : projects.map { Optional($0) }

        var messages: [Int: [String]] = [:]
        for harness in Set(skills.flatMap(\.visibleTo)) {
            for context in contexts {
                let hidden = context.flatMap { hiddenInProject[$0.standardizedFileURL.path] } ?? []
                let loaded = skills.indices.filter { index in
                    let skill = skills[index]
                    guard skill.visibleTo.contains(harness) else { return false }
                    switch skill.scope {
                    case .global, .synced, .bundled: return true
                    case .plugin: return harness != .claudeCode
                    case .project(let url): return url == context
                    case .package(_, let project): return project.map { $0 == context } ?? !hidden.contains(skill.id)
                    }
                }
                for (_, indices) in Dictionary(grouping: loaded, by: { skills[$0].name }) where indices.count > 1 {
                    for index in indices {
                        let others = indices.filter { $0 != index }.map { FileWalk.tilde(skills[$0].file, home: home) }
                        let message = "\(harness.displayName): name collides with \(others.joined(separator: ", "))"
                        if messages[index, default: []].contains(message) == false { messages[index, default: []].append(message) }
                    }
                }
            }
        }
        for (index, list) in messages { skills[index].warnings += list.sorted() }
    }

    // MARK: - File helpers (follow symlinks)

    /// Exact, case-sensitive `SKILL.md` (the default macOS disk ignores case, harnesses don't).
    public static func hasSkillFile(_ dir: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains("SKILL.md") && isFile(dir.appending(path: "SKILL.md"))
    }

    /// A regular file (links followed): a FIFO or device would block or never end.
    static func isFile(_ url: URL) -> Bool {
        FileWalk.isRegularFile(url)
    }
}

/// Pi's (Agent Skills spec) name rule. Claude is more lenient.
public enum PiNameRule {
    public static func problems(_ name: String) -> [String] {
        var result: [String] = []
        if name.count > 64 { result.append("name is longer than 64 characters") }
        if name.range(of: "^[a-z0-9-]+$", options: .regularExpression) == nil {
            result.append("name may only contain a-z, 0-9 and hyphens")
        }
        if name.hasPrefix("-") || name.hasSuffix("-") { result.append("name must not start or end with a hyphen") }
        if name.contains("--") { result.append("name must not contain consecutive hyphens") }
        return result
    }
}

/// Where installed skills came from: `~/.agents/.skill-lock.json` (written by `npx skills`)
/// plus AKit's own `~/.akit/skills-lock.json`.
public struct SkillLock: Sendable {
    let skillsFolder: URL
    let sources: [String: String]
    var installed = InstalledSkillLock()

    public static func read(in env: HarnessEnvironment) -> SkillLock {
        let folder = env.homeDirectory.appending(path: ".agents/skills").resolvingSymlinksInPath()
        let url = env.homeDirectory.appending(path: ".agents/.skill-lock.json")
        var sources: [String: String] = [:]
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let skills = json["skills"] as? [String: Any] {
            for (name, entry) in skills {
                if let source = (entry as? [String: Any])?["source"] as? String { sources[name] = source }
            }
        }
        var lock = SkillLock(skillsFolder: folder, sources: sources)
        lock.installed = (try? InstalledSkillLock.load(in: env)) ?? InstalledSkillLock()
        return lock
    }

    public func source(forSkillFolder folder: URL) -> String? {
        if let origin = installed.origin(forSkillFolder: folder) { return origin }
        guard folder.deletingLastPathComponent().path == skillsFolder.path else { return nil }
        return sources[folder.lastPathComponent]
    }
}
