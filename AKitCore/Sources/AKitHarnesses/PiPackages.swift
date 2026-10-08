import AKitFoundation
import AKitModel
import Foundation

/// A package listed in Pi's settings (`packages`): from npm, git or a local path.
/// Read-only: AKit never installs a package or runs its code, it only reads its files.
public struct PiPackage: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case npm, git, local }

    public var id: String { "\(settingsFile.path)#\(index)" }
    /// Position of the entry in the settings' `packages` list.
    public let index: Int
    /// As written in the settings (`npm:pi-subagents`, `git:github.com/a/b@v1`, `./tools`), with a
    /// `user:password@` of a URL left out: it may hold a token.
    public let source: String
    public let kind: Kind
    /// `.global` for `<Pi dir>/settings.json`, else the project whose `.pi/settings.json` lists it.
    public let scope: InstallScope
    public let settingsFile: URL
    /// Pi's identity of the package (`npm:<name>`, `git:<host>/<path>`, `local:<path>`): a project
    /// entry replaces a global one with the same identity.
    public let identity: String
    /// The installed package folder (a file for a local extension file). nil = not installed.
    public let folder: URL?
    /// `name` from its package.json, else taken from the source.
    public let name: String
    public let version: String?
    /// The entry narrows what loads: it has resource filters or `autoload: false`.
    public let isFiltered: Bool
    /// The package has more files than AKit walks for one package; its lists are left empty.
    public let isTooLarge: Bool
    /// What Pi loads from the package after its manifest and the settings' filters. Only regular
    /// files inside the package folder (links resolved) are listed.
    public let extensions: [URL]
    public let skills: [URL]
    public let prompts: [URL]
    public let themes: [URL]

    public var isInstalled: Bool { folder != nil }
}

/// Reads Pi packages the way Pi's package manager (core/package-manager.js, 1.0.x) resolves them:
/// - npm: `<Pi dir>/npm/node_modules/<name>` (project: `.pi/npm/node_modules/<name>`);
/// - git: `<Pi dir>/git/<host>/<path>` (project: `.pi/git/<host>/<path>`);
/// - local: the path, relative to the folder of the settings file (`<Pi dir>`, `.pi`).
/// A package's `package.json` `pi` key lists `extensions`, `skills`, `prompts`, `themes` (paths
/// and globs, `!`/`+`/`-` patterns); without it the folders of those names are read.
///
/// Packages come from settings a cloned repository may bring, so nothing listed may leave the
/// package folder (links resolved), only regular files count, known secret files never show,
/// and one package is walked for at most `entryBudget` folder entries.
/// Differences from Pi: npm packages in the old global npm folder (`npm root -g`) are not found
/// (finding it means running npm), `.gitignore` files inside packages are not applied, `**`
/// skips node_modules, and project packages are listed whether or not Pi trusts the project.
public enum PiPackages {
    enum ResourceType: String, CaseIterable {
        case extensions, skills, prompts, themes
    }

    typealias Resources = [ResourceType: [URL]]

    static let entryBudget = 5_000
    /// Never listed, even inside a package.
    public static let secretNames: Set<String> = ["auth.json", "models-store.json", "settings.local.json"]

    /// Packages of the global settings, then those of each project's `.pi/settings.json`.
    public static func list(configRoot: URL, projects: [URL], in env: HarnessEnvironment) -> [PiPackage] {
        let global = packages(settings: configRoot.appending(path: "settings.json"), scope: .global,
                              configRoot: configRoot, globals: [], env: env)
        var result = global
        var seen: Set<String> = []
        for project in projects where seen.insert(project.standardizedFileURL.path).inserted {
            result += packages(settings: project.appending(path: ".pi/settings.json"), scope: .project(project),
                               configRoot: configRoot, globals: global, env: env)
        }
        return result
    }

    /// Read-only skill roots of the installed packages that have skills, global packages first.
    public static func skillRoots(_ packages: [PiPackage]) -> [SkillRoot] {
        packages.sorted { ($0.scope == .global ? 0 : 1) < ($1.scope == .global ? 0 : 1) }.compactMap { package in
            guard let folder = package.folder, !package.skills.isEmpty else { return nil }
            let project: URL? = if case .project(let url) = package.scope { url } else { nil }
            return SkillRoot(url: folder, harness: .pi, scope: .package(name: package.name, project: project),
                             layout: .listed(package.skills), isReadOnly: true,
                             origin: [package.source, package.version].compactMap { $0 }.joined(separator: " "))
        }
    }

    /// Real paths of global packages' skill files that a session in `project` does not load: the
    /// project's settings list the same package (same identity), which replaces the global entry,
    /// or narrows it with `autoload: false`.
    public static func skillsHidden(in project: URL, packages: [PiPackage]) -> Set<String> {
        let path = project.standardizedFileURL.path
        let local = packages.filter { package in
            if case .project(let url) = package.scope { url.standardizedFileURL.path == path } else { false }
        }
        guard !local.isEmpty else { return [] }
        var hidden: Set<String> = []
        for global in packages where global.scope == .global {
            guard let replacing = local.first(where: { $0.identity == global.identity }) else { continue }
            let kept = Set(replacing.skills.map { $0.resolvingSymlinksInPath().path })
            hidden.formUnion(global.skills.map { $0.resolvingSymlinksInPath().path }.filter { !kept.contains($0) })
        }
        return hidden
    }

    static func packages(settings: URL, scope: InstallScope, configRoot: URL, globals: [PiPackage],
                         env: HarnessEnvironment) -> [PiPackage] {
        guard let entries = FileWalk.jsonObject(settings)?["packages"] as? [Any] else { return [] }
        let base: URL = switch scope {
        case .global: configRoot
        case .project(let project): project.appending(path: ".pi")
        }
        return entries.enumerated().compactMap { index, entry in
            let filter = entry as? [String: Any]
            guard let source = (entry as? String) ?? filter?["source"] as? String else { return nil }
            return package(index: index, source: source, filter: filter, scope: scope, settings: settings, base: base,
                           configRoot: configRoot, globals: globals, env: env)
        }
    }

    static func package(index: Int, source: String, filter: [String: Any]?, scope: InstallScope, settings: URL,
                        base: URL, configRoot: URL, globals: [PiPackage], env: HarnessEnvironment) -> PiPackage {
        let parsed = Source(source, base: base, env: env)
        // A project entry with `autoload: false` is a delta over the global entry of the same package.
        let deltaBase = filter?["autoload"] as? Bool == false
            ? globals.first { $0.identity == parsed.identity } : nil

        var folder: URL?
        switch parsed.kind {
        case .npm(let name):
            let root = scope == .global ? configRoot : base
            folder = root.appending(path: "npm/node_modules/\(name)")
        case .git(let host, let path):
            let root = scope == .global ? configRoot : base
            folder = root.appending(path: "git/\(host)/\(path)")
        case .local(let url):
            folder = url
        case .invalid:
            folder = nil
        }
        if let deltaBase { folder = deltaBase.folder }
        if let found = folder, !FileManager.default.fileExists(atPath: found.path) { folder = nil }

        var resources: Resources = [:]
        var tooLarge = false
        var manifest: [String: Any]?
        if let folder {
            if FileWalk.isDirectory(folder) {
                let walk = Walk(root: folder)
                let baseResources = deltaBase.map {
                    [.extensions: $0.extensions, .skills: $0.skills, .prompts: $0.prompts, .themes: $0.themes] as Resources
                }
                let found = walk.resources(filter: filter, deltaBase: baseResources)
                if walk.exhausted {
                    tooLarge = true
                } else if let found {
                    resources = found
                } else if case .local = parsed.kind {
                    // Only a local folder that offers nothing is loaded as one extension.
                    resources = [.extensions: [folder]]
                }
                manifest = FileWalk.jsonObject(folder.appending(path: "package.json"))
            } else if FileWalk.isRegularFile(folder), extensionFile(folder) {
                resources = [.extensions: [folder]]
            }
        }
        let filterKeys = ResourceType.allCases.map(\.rawValue) + ["autoload"]
        return PiPackage(index: index, source: Source.withoutCredentials(source), kind: parsed.kindName, scope: scope,
                         settingsFile: settings, identity: parsed.identity, folder: folder,
                         name: manifest?["name"] as? String ?? parsed.fallbackName,
                         version: manifest?["version"] as? String,
                         isFiltered: filter.map { entry in filterKeys.contains { entry[$0] != nil } } ?? false,
                         isTooLarge: tooLarge,
                         extensions: resources[.extensions] ?? [], skills: resources[.skills] ?? [],
                         prompts: resources[.prompts] ?? [], themes: resources[.themes] ?? [])
    }

    /// A local source that is a single file: listed only as a script, never as a secret.
    static func extensionFile(_ url: URL) -> Bool {
        ["ts", "js", "mts", "cts", "mjs", "cjs"].contains(url.pathExtension) && !secretNames.contains(url.lastPathComponent)
    }

    // MARK: - Sources

    struct Source {
        enum Kind {
            case npm(name: String)
            case git(host: String, path: String)
            case local(URL)
            /// An npm name that would leave the npm folder (`..`).
            case invalid
        }

        let kind: Kind
        private let raw: String

        init(_ raw: String, base: URL, env: HarnessEnvironment) {
            self.raw = raw
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("npm:") {
                let name = Self.npmName(String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces))
                let parts = name.split(separator: "/", omittingEmptySubsequences: false)
                let safe = !name.isEmpty && !name.hasPrefix("/") && parts.count <= 2
                    && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\\") }
                kind = safe ? .npm(name: name) : .invalid
            } else if !Self.isLocal(text), let git = Self.git(text) {
                kind = .git(host: git.host, path: git.path)
            } else {
                kind = .local(Self.resolve(text, from: base, env: env))
            }
        }

        var kindName: PiPackage.Kind {
            switch kind {
            case .npm, .invalid: .npm
            case .git: .git
            case .local: .local
            }
        }

        var identity: String {
            switch kind {
            case .npm(let name): "npm:\(name)"
            case .git(let host, let path): "git:\(host)/\(path)"
            case .local(let url): "local:\(url.path)"
            case .invalid: "invalid:\(raw)"
            }
        }

        var fallbackName: String {
            switch kind {
            case .npm(let name): name
            case .git(_, let path): String(path.split(separator: "/").last ?? Substring(path))
            case .local(let url): url.lastPathComponent
            case .invalid: Self.withoutCredentials(raw)
            }
        }

        /// `https://user:token@host/a/b` → `https://host/a/b`, also after a `git:` prefix.
        static func withoutCredentials(_ source: String) -> String {
            source.replacingOccurrences(of: #"([A-Za-z][A-Za-z0-9+.-]*://)[^/@\s]*@"#, with: "$1",
                                        options: .regularExpression)
        }

        /// `@scope/name@1.2` → `@scope/name`.
        static func npmName(_ spec: String) -> String {
            let pattern = /^(@?[^@]+(?:\/[^@]+)?)(?:@(.+))?$/
            return (try? pattern.wholeMatch(in: spec)).map { String($0.output.1) } ?? spec
        }

        static func isLocal(_ text: String) -> Bool {
            !["npm:", "git:", "github:", "http:", "https:", "ssh:", "builtin:"].contains { text.hasPrefix($0) }
        }

        /// `git:github.com/a/b@v1`, `git:git@github.com:a/b`, `https://host/a/b.git` → host and path
        /// without the ref. Without `git:` only URLs with a scheme are git sources.
        static func git(_ text: String) -> (host: String, path: String)? {
            var url = text
            let prefixed = url.hasPrefix("git:")
            if prefixed { url = String(url.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            let shorthands = ["github:": "github.com", "gitlab:": "gitlab.com", "bitbucket:": "bitbucket.org"]
            if prefixed, let (prefix, host) = shorthands.first(where: { url.hasPrefix($0.key) }) {
                url = host + "/" + url.dropFirst(prefix.count)
            }
            let hasScheme = url.range(of: "^(https?|ssh|git)://", options: [.regularExpression, .caseInsensitive]) != nil
            guard prefixed || hasScheme else { return nil }

            var host: String
            var path: String
            if let match = try? /^git@([^:]+):(.+)$/.wholeMatch(in: url) {
                host = String(match.output.1)
                path = String(match.output.2)
            } else if hasScheme, let parts = URLComponents(string: url), let name = parts.host {
                host = name
                path = parts.path
            } else {
                guard let slash = url.firstIndex(of: "/") else { return nil }
                host = String(url[..<slash])
                path = String(url[url.index(after: slash)...])
                guard host.contains(".") || host == "localhost" else { return nil }
            }
            if let at = path.firstIndex(of: "@") { path = String(path[..<at]) }
            if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
            while path.hasPrefix("/") { path.removeFirst() }
            if path.hasSuffix(".git") { path.removeLast(4) }
            host = host.lowercased()
            let segments = path.split(separator: "/")
            guard !host.isEmpty, !host.contains("/"), host != "..", segments.count >= 2,
                  !segments.contains(where: { $0 == ".." || $0 == "." || $0.contains("\\") }) else { return nil }
            return (host, path)
        }

        static func resolve(_ path: String, from base: URL, env: HarnessEnvironment) -> URL {
            var path = path
            if path.hasPrefix("file://") { path = URL(string: path)?.path ?? path }
            if path == "~" || path.hasPrefix("~/") { return env.expand(path).standardizedFileURL }
            if path.hasPrefix("/") { return URL(filePath: path).standardizedFileURL }
            return base.appending(path: path).standardizedFileURL
        }
    }

    // MARK: - Walking one package

    /// Everything read from one package folder: what its manifest and folders offer (Pi's
    /// collectPackageResources), kept inside the folder and within the entry budget.
    final class Walk {
        let root: URL
        private let rootReal: String
        private var budget = PiPackages.entryBudget
        private(set) var exhausted = false
        private var globs: [String: Glob] = [:]
        private lazy var manifest: [ResourceType: [String]]? = Self.manifest(root)

        init(root: URL) {
            self.root = root.standardizedFileURL
            rootReal = FileWalk.realPath(root) ?? root.standardizedFileURL.path
        }

        /// nil: no filter, no manifest and none of the conventional folders.
        func resources(filter: [String: Any]?, deltaBase: Resources?) -> Resources? {
            var result: Resources = [:]
            if let filter {
                for type in ResourceType.allCases {
                    let patterns = (filter[type.rawValue] as? [Any])?.compactMap { $0 as? String }
                    if filter["autoload"] as? Bool == false {
                        let all = allFiles(type)
                        let delta = autoloadDelta(all, patterns ?? [])
                        let base = deltaBase?[type] ?? []
                        let kept = base.filter { delta[$0.path] != false }
                        result[type] = unique(kept + all.filter { delta[$0.path] == true })
                    } else if let patterns {
                        if patterns.isEmpty {
                            result[type] = []
                        } else {
                            let all = allFiles(type)
                            let enabled = apply(patterns, to: all)
                            result[type] = all.filter { enabled.contains($0.path) }
                        }
                    } else if let entries = manifest?[type] {
                        result[type] = manifestFiles(entries, type)
                    } else {
                        result[type] = conventional(type)
                    }
                }
                return result
            }
            if let manifest {
                for type in ResourceType.allCases {
                    result[type] = manifest[type].map { manifestFiles($0, type) } ?? []
                }
                return result
            }
            var anyFolder = false
            for type in ResourceType.allCases {
                if FileManager.default.fileExists(atPath: root.appending(path: type.rawValue).path) { anyFolder = true }
                result[type] = conventional(type)
            }
            return anyFolder ? result : nil
        }

        /// The `pi` key of package.json: only lists made of strings count.
        static func manifest(_ folder: URL) -> [ResourceType: [String]]? {
            guard let pi = FileWalk.jsonObject(folder.appending(path: "package.json"))?["pi"] as? [String: Any] else {
                return nil
            }
            var result: [ResourceType: [String]] = [:]
            for type in ResourceType.allCases {
                if let list = pi[type.rawValue] as? [Any] {
                    let strings = list.compactMap { $0 as? String }
                    if strings.count == list.count { result[type] = strings }
                }
            }
            return result
        }

        /// Every file the package offers of this type before the settings' filters.
        func allFiles(_ type: ResourceType) -> [URL] {
            if let entries = manifest?[type], !entries.isEmpty { return manifestFiles(entries, type) }
            return conventional(type)
        }

        func conventional(_ type: ResourceType) -> [URL] {
            collect(root.appending(path: type.rawValue), type)
        }

        /// Manifest paths and globs, then its own `!`/`+`/`-` patterns.
        func manifestFiles(_ entries: [String], _ type: ResourceType) -> [URL] {
            let entries = Array(entries.prefix(256))
            let paths = entries.filter { !PiPackages.isOverride($0) }.flatMap { entry -> [URL] in
                PiPackages.hasGlob(entry) ? expandGlob(entry) : [PiPackages.path(entry, in: root)]
            }
            var files: [URL] = []
            for path in paths where !exhausted {
                if directory(path) != nil {
                    files += collect(path, type)
                } else if isFile(path) {
                    files.append(path)
                }
            }
            let enabled = apply(entries.filter(PiPackages.isOverride), to: files)
            return unique(files.filter { enabled.contains($0.path) })
        }

        // MARK: Containment and budget

        /// Real path of a folder inside the package.
        func directory(_ url: URL) -> String? {
            guard let real = inside(url), FileWalk.isDirectory(URL(filePath: real)) else { return nil }
            return real
        }

        /// A regular file inside the package that isn't a known secret.
        func isFile(_ url: URL) -> Bool {
            guard let real = inside(url), FileWalk.isRegularFile(URL(filePath: real)) else { return false }
            return !PiPackages.secretNames.contains(url.lastPathComponent)
                && !PiPackages.secretNames.contains((real as NSString).lastPathComponent)
        }

        private func inside(_ url: URL) -> String? {
            guard let real = FileWalk.realPath(url) else { return nil }
            return real == rootReal || real.hasPrefix(rootReal == "/" ? "/" : rootReal + "/") ? real : nil
        }

        /// Visible entries of a folder; each one costs one unit of the budget.
        private func children(_ dir: URL) -> [URL] {
            guard !exhausted else { return [] }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            budget -= names.count + 1
            if budget < 0 {
                exhausted = true
                return []
            }
            return names.filter { !$0.hasPrefix(".") }.sorted().map { dir.appending(path: $0) }
        }

        private func unique(_ files: [URL]) -> [URL] {
            var seen: Set<String> = []
            return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
        }

        // MARK: Folder discovery (Pi's collectResourceFiles)

        func collect(_ dir: URL, _ type: ResourceType) -> [URL] {
            var visited: Set<String> = []
            return switch type {
            case .skills: skillFiles(dir, depth: 0, visited: &visited)
            case .extensions: extensionFiles(dir)
            case .prompts: files(dir, extension: "md", depth: 0, visited: &visited)
            case .themes: files(dir, extension: "json", depth: 0, visited: &visited)
            }
        }

        /// A folder with SKILL.md is one skill; else `.md` files directly in the root and skills in subfolders.
        private func skillFiles(_ dir: URL, depth: Int, visited: inout Set<String>) -> [URL] {
            guard depth < 12, let real = directory(dir), visited.insert(real).inserted else { return [] }
            let entries = children(dir)
            let skill = dir.appending(path: "SKILL.md")
            if entries.contains(where: { $0.lastPathComponent == "SKILL.md" }), isFile(skill) { return [skill] }
            var result: [URL] = []
            for child in entries where child.lastPathComponent != "node_modules" {
                if directory(child) != nil {
                    result += skillFiles(child, depth: depth + 1, visited: &visited)
                } else if depth == 0, child.pathExtension == "md", isFile(child) {
                    result.append(child)
                }
            }
            return result
        }

        /// The folder's own entry (manifest `extensions`, `index.ts`, `index.js`), else `.ts`/`.js`
        /// files in it and the entries of its subfolders.
        private func extensionFiles(_ dir: URL) -> [URL] {
            guard directory(dir) != nil else { return [] }
            if let own = extensionEntry(dir) { return own }
            var result: [URL] = []
            for child in children(dir) where child.lastPathComponent != "node_modules" {
                if directory(child) != nil {
                    result += extensionEntry(child) ?? []
                } else if ["ts", "js"].contains(child.pathExtension), isFile(child) {
                    result.append(child)
                }
            }
            return result
        }

        private func extensionEntry(_ dir: URL) -> [URL]? {
            if let listed = Self.manifest(dir)?[.extensions], !listed.isEmpty {
                let found = listed.prefix(256).map { PiPackages.path($0, in: dir) }.filter(isFile)
                if !found.isEmpty { return found }
            }
            for name in ["index.ts", "index.js"] where isFile(dir.appending(path: name)) {
                return [dir.appending(path: name)]
            }
            return nil
        }

        private func files(_ dir: URL, extension ext: String, depth: Int, visited: inout Set<String>) -> [URL] {
            guard depth < 12, let real = directory(dir), visited.insert(real).inserted else { return [] }
            var result: [URL] = []
            for child in children(dir) where child.lastPathComponent != "node_modules" {
                if directory(child) != nil {
                    result += files(child, extension: ext, depth: depth + 1, visited: &visited)
                } else if child.pathExtension == ext, isFile(child) {
                    result.append(child)
                }
            }
            return result
        }

        // MARK: Globs

        /// Paths matching a relative glob inside the package, sorted. Like Pi, a result with a
        /// segment starting with a dot is dropped. An absolute glob matches nothing: every result
        /// would have to lie inside the package anyway.
        func expandGlob(_ pattern: String) -> [URL] {
            var pattern = pattern
            while pattern.hasPrefix("./") { pattern.removeFirst(2) }
            guard pattern.count <= 512, !pattern.hasPrefix("/"), !pattern.hasPrefix("~") else { return [] }
            var current = [root]
            for segment in pattern.split(separator: "/").map(String.init) {
                guard !exhausted else { return [] }
                var next: [URL] = []
                if segment == "**" {
                    var visited: Set<String> = []
                    for dir in current { next += [dir] + descendants(dir, depth: 0, visited: &visited) }
                } else if PiPackages.hasGlob(segment) || segment.contains("[") || segment.contains("{") {
                    guard let glob = glob(segment) else { return [] }
                    for dir in current where directory(dir) != nil {
                        next += children(dir).filter { glob.matches($0.lastPathComponent) }
                    }
                } else {
                    next = current.map { $0.appending(path: segment) }
                        .filter { FileManager.default.fileExists(atPath: $0.path) }
                }
                current = next
            }
            return unique(current.map(\.standardizedFileURL))
                .filter { url in
                    let relative = PiPackages.relative(url, to: root)
                    return !relative.split(separator: "/").contains { $0.hasPrefix(".") && $0 != ".." }
                }
                .sorted { $0.path < $1.path }
        }

        private func descendants(_ dir: URL, depth: Int, visited: inout Set<String>) -> [URL] {
            guard depth < 12, let real = directory(dir), visited.insert(real).inserted else { return [] }
            var result: [URL] = []
            for child in children(dir) where child.lastPathComponent != "node_modules" {
                result.append(child)
                result += descendants(child, depth: depth + 1, visited: &visited)
            }
            return result
        }

        private func glob(_ pattern: String) -> Glob? {
            if let cached = globs[pattern] { return cached }
            guard let compiled = Glob(pattern) else { return nil }
            globs[pattern] = compiled
            return compiled
        }

        // MARK: Patterns

        /// Pi's applyPatterns: plain patterns include (all when there are none), `!` excludes,
        /// `+path` adds an exact path back, `-path` removes an exact path. Returns enabled paths.
        func apply(_ patterns: [String], to files: [URL]) -> Set<String> {
            var includes: [String] = [], excludes: [String] = [], forceIn: [String] = [], forceOut: [String] = []
            for pattern in patterns.prefix(256) {
                switch pattern.first {
                case "+": forceIn.append(String(pattern.dropFirst()))
                case "-": forceOut.append(String(pattern.dropFirst()))
                case "!": excludes.append(String(pattern.dropFirst()))
                default: includes.append(pattern)
                }
            }
            var result = includes.isEmpty ? files : files.filter { matches($0, includes) }
            if !excludes.isEmpty { result = result.filter { !matches($0, excludes) } }
            if !forceIn.isEmpty {
                let present = Set(result.map(\.path))
                result += files.filter { !present.contains($0.path) && matchesExactly($0, forceIn) }
            }
            if !forceOut.isEmpty { result = result.filter { !matchesExactly($0, forceOut) } }
            return Set(result.map(\.path))
        }

        /// Pi's applyAutoloadDisabledPatterns: each pattern turns the files it matches on (plain, `+`)
        /// or off (`!`, `-`); a later pattern wins. Files no pattern names are left out.
        func autoloadDelta(_ files: [URL], _ patterns: [String]) -> [String: Bool] {
            var result: [String: Bool] = [:]
            for pattern in patterns.prefix(256) {
                let first = pattern.first
                let target = PiPackages.isOverride(pattern) ? String(pattern.dropFirst()) : pattern
                let exact = first == "+" || first == "-"
                for file in files where exact ? matchesExactly(file, [target]) : matches(file, [target]) {
                    result[file.path] = first != "-" && first != "!"
                }
            }
            return result
        }

        /// Glob match against the path relative to the package, the file name or the absolute path;
        /// for a SKILL.md also against its folder.
        func matches(_ file: URL, _ patterns: [String]) -> Bool {
            var candidates = [PiPackages.relative(file, to: root), file.lastPathComponent, file.path]
            if file.lastPathComponent == "SKILL.md" {
                let folder = file.deletingLastPathComponent()
                candidates += [PiPackages.relative(folder, to: root), folder.lastPathComponent, folder.path]
            }
            return patterns.contains { pattern in
                guard let glob = glob(pattern) else { return false }
                return candidates.contains { glob.matches($0) }
            }
        }

        func matchesExactly(_ file: URL, _ patterns: [String]) -> Bool {
            var candidates = [PiPackages.relative(file, to: root), file.path]
            if file.lastPathComponent == "SKILL.md" {
                let folder = file.deletingLastPathComponent()
                candidates += [PiPackages.relative(folder, to: root), folder.path]
            }
            return patterns.contains { pattern in
                candidates.contains(pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern)
            }
        }
    }

    // MARK: - Helpers

    static func isOverride(_ pattern: String) -> Bool {
        pattern.hasPrefix("!") || pattern.hasPrefix("+") || pattern.hasPrefix("-")
    }

    static func hasGlob(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?")
    }

    static func relative(_ url: URL, to root: URL) -> String {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }

    /// Node's `resolve(root, entry)`: an absolute path stays, anything else is relative to `root`.
    /// Whether the result stays inside the package is checked by the caller.
    static func path(_ entry: String, in root: URL) -> URL {
        (entry.hasPrefix("/") ? URL(filePath: entry) : root.appending(path: entry)).standardizedFileURL
    }

    /// A minimatch-style glob: `**` any folders, `*` and `?` within one name, `[...]` classes
    /// and `{a,b}` alternatives. Matched without backtracking (one pass per token over the text),
    /// so a package's pattern can't make it slow. Too long patterns or too many alternatives
    /// match nothing.
    struct Glob {
        enum Token: Equatable {
            case literal(Character)
            /// `?`: one character except `/`.
            case one
            /// `*`: any characters except `/`.
            case star
            /// `**` not followed by `/`: any characters.
            case any
            /// `**/`: nothing, or anything ending in `/`.
            case folders
            case set([ClosedRange<Character>], negated: Bool)
        }

        let alternatives: [[Token]]

        init?(_ pattern: String) {
            guard pattern.count <= 512, let expanded = Self.expandBraces(pattern, limit: 64) else { return nil }
            alternatives = expanded.map(Self.tokens)
        }

        func matches(_ text: String) -> Bool {
            let chars = Array(text)
            return alternatives.contains { Self.match($0, chars) }
        }

        /// `a{b,c}d` → `abd`, `acd` (nested too). nil: unbalanced or more than `limit` results.
        static func expandBraces(_ pattern: String, limit: Int) -> [String]? {
            let chars = Array(pattern)
            guard let open = chars.firstIndex(of: "{") else {
                return chars.contains("}") ? nil : [pattern]
            }
            var depth = 0
            var parts: [String] = []
            var current = ""
            var close: Int?
            for index in (open + 1)..<chars.count {
                let char = chars[index]
                if char == "{" { depth += 1 }
                if char == "}" {
                    if depth == 0 { close = index; break }
                    depth -= 1
                }
                if char == ",", depth == 0 {
                    parts.append(current)
                    current = ""
                } else {
                    current.append(char)
                }
            }
            guard let close else { return nil }
            parts.append(current)
            let head = String(chars[..<open])
            let tail = String(chars[(close + 1)...])
            var result: [String] = []
            for part in parts {
                guard let expanded = expandBraces(head + part + tail, limit: limit) else { return nil }
                result += expanded
                if result.count > limit { return nil }
            }
            return result
        }

        static func tokens(_ pattern: String) -> [Token] {
            let chars = Array(pattern)
            var tokens: [Token] = []
            var index = 0
            while index < chars.count {
                let char = chars[index]
                switch char {
                case "*":
                    var end = index
                    while end + 1 < chars.count, chars[end + 1] == "*" { end += 1 }
                    if end > index, end + 1 < chars.count, chars[end + 1] == "/" {
                        tokens.append(.folders)
                        end += 1
                    } else if end > index {
                        tokens.append(.any)
                    } else if tokens.last != .star {
                        tokens.append(.star)
                    }
                    index = end
                case "?":
                    tokens.append(.one)
                case "[":
                    if let close = chars[(index + 1)...].firstIndex(of: "]"), close > index + 1 {
                        var body = Array(chars[(index + 1)..<close])
                        let negated = body.first == "!" || body.first == "^"
                        if negated { body.removeFirst() }
                        var ranges: [ClosedRange<Character>] = []
                        var at = 0
                        while at < body.count {
                            if at + 2 < body.count, body[at + 1] == "-", body[at] <= body[at + 2] {
                                ranges.append(body[at]...body[at + 2])
                                at += 3
                            } else {
                                ranges.append(body[at]...body[at])
                                at += 1
                            }
                        }
                        tokens.append(.set(ranges, negated: negated))
                        index = close
                    } else {
                        tokens.append(.literal("["))
                    }
                default:
                    tokens.append(.literal(char))
                }
                index += 1
            }
            return tokens
        }

        /// The set of text positions reachable after each token, carried left to right.
        static func match(_ tokens: [Token], _ text: [Character]) -> Bool {
            let count = text.count
            var reach = [Bool](repeating: false, count: count + 1)
            reach[0] = true
            for token in tokens {
                var next = [Bool](repeating: false, count: count + 1)
                var carry = false
                for index in 0...count {
                    switch token {
                    case .literal(let char):
                        if index < count, reach[index], text[index] == char { next[index + 1] = true }
                    case .one:
                        if index < count, reach[index], text[index] != "/" { next[index + 1] = true }
                    case .set(let ranges, let negated):
                        if index < count, reach[index], text[index] != "/",
                           ranges.contains(where: { $0.contains(text[index]) }) != negated {
                            next[index + 1] = true
                        }
                    case .star:
                        carry = reach[index] || (carry && text[index - 1] != "/")
                        next[index] = carry
                    case .any:
                        carry = carry || reach[index]
                        next[index] = carry
                    case .folders:
                        carry = carry || reach[index]
                        if reach[index] { next[index] = true }
                        if index < count, carry, text[index] == "/" { next[index + 1] = true }
                    }
                }
                reach = next
                if !reach.contains(true) { return false }
            }
            return reach[count]
        }
    }
}
