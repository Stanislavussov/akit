import AKitFoundation
import AKitModel
import Foundation

/// A package listed in Pi's settings (`packages`): from npm, git or a local path.
/// Read-only: AKit never installs a package or runs its code, it only reads its files.
public struct PiPackage: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case npm, git, local }

    public var id: String { settingsFile.path + "\n" + source }
    /// As written in the settings, e.g. `npm:pi-subagents`, `git:github.com/a/b@v1`, `./tools`.
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
    /// The entry is an object (`{source, extensions?, skills?, …}`) that narrows what loads.
    public let isFiltered: Bool
    /// What Pi loads from the package after its manifest and the settings' filters.
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
/// Differences from Pi: npm packages in the old global npm folder (`npm root -g`) are not found
/// (finding it means running npm), `.gitignore` files inside packages are not applied, and
/// project packages are listed whether or not the project was trusted in Pi.
public enum PiPackages {
    enum ResourceType: String, CaseIterable {
        case extensions, skills, prompts, themes
    }

    typealias Resources = [ResourceType: [URL]]

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

    static func packages(settings: URL, scope: InstallScope, configRoot: URL, globals: [PiPackage],
                         env: HarnessEnvironment) -> [PiPackage] {
        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["packages"] as? [Any] else { return [] }
        let base: URL = switch scope {
        case .global: configRoot
        case .project(let project): project.appending(path: ".pi")
        }
        return entries.compactMap { entry in
            let filter = entry as? [String: Any]
            guard let source = (entry as? String) ?? filter?["source"] as? String else { return nil }
            return package(source: source, filter: filter, scope: scope, settings: settings, base: base,
                           configRoot: configRoot, globals: globals, env: env)
        }
    }

    static func package(source: String, filter: [String: Any]?, scope: InstallScope, settings: URL, base: URL,
                        configRoot: URL, globals: [PiPackage], env: HarnessEnvironment) -> PiPackage {
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
        }
        if let deltaBase { folder = deltaBase.folder }
        if let found = folder, !FileManager.default.fileExists(atPath: found.path) { folder = nil }

        var resources: Resources = [:]
        if let folder {
            if FileWalk.isDirectory(folder) {
                let baseResources = deltaBase.map {
                    [.extensions: $0.extensions, .skills: $0.skills, .prompts: $0.prompts, .themes: $0.themes] as Resources
                }
                // A local folder that offers nothing is loaded as one extension.
                resources = Self.resources(root: folder, filter: filter, deltaBase: baseResources)
                    ?? [.extensions: [folder]]
            } else {
                resources = [.extensions: [folder]]
            }
        }
        let manifest = folder.flatMap { Self.json($0.appending(path: "package.json")) }
        return PiPackage(source: source, kind: parsed.kindName, scope: scope, settingsFile: settings,
                         identity: parsed.identity, folder: folder,
                         name: manifest?["name"] as? String ?? parsed.fallbackName,
                         version: manifest?["version"] as? String, isFiltered: filter != nil,
                         extensions: resources[.extensions] ?? [], skills: resources[.skills] ?? [],
                         prompts: resources[.prompts] ?? [], themes: resources[.themes] ?? [])
    }

    // MARK: - Sources

    struct Source {
        enum Kind {
            case npm(name: String)
            case git(host: String, path: String)
            case local(URL)
        }

        let kind: Kind

        init(_ raw: String, base: URL, env: HarnessEnvironment) {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("npm:") {
                kind = .npm(name: Self.npmName(String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces)))
            } else if !Self.isLocal(text), let git = Self.git(text) {
                kind = .git(host: git.host, path: git.path)
            } else {
                kind = .local(Self.resolve(text, from: base, env: env))
            }
        }

        var kindName: PiPackage.Kind {
            switch kind {
            case .npm: .npm
            case .git: .git
            case .local: .local
            }
        }

        var identity: String {
            switch kind {
            case .npm(let name): "npm:\(name)"
            case .git(let host, let path): "git:\(host)/\(path)"
            case .local(let url): "local:\(url.path)"
            }
        }

        var fallbackName: String {
            switch kind {
            case .npm(let name): name
            case .git(_, let path): String(path.split(separator: "/").last ?? Substring(path))
            case .local(let url): url.lastPathComponent
            }
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
            guard !host.isEmpty, !host.contains("/"), segments.count >= 2, !segments.contains("..") else { return nil }
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

    // MARK: - Resources of one package

    /// What loads from a package folder. nil: no filter, no manifest and none of the
    /// conventional folders (Pi then loads a local folder as one extension).
    static func resources(root: URL, filter: [String: Any]?, deltaBase: Resources?) -> Resources? {
        let root = root.standardizedFileURL
        let manifest = manifest(root)
        var result: Resources = [:]
        if let filter {
            for type in ResourceType.allCases {
                let patterns = (filter[type.rawValue] as? [Any])?.compactMap { $0 as? String }
                if filter["autoload"] as? Bool == false {
                    let all = allFiles(root, type, manifest)
                    let delta = autoloadDelta(all, patterns ?? [], root: root)
                    let base = deltaBase?[type] ?? []
                    let kept = base.filter { delta[$0.path] != false }
                    let added = all.filter { file in
                        delta[file.path] == true && !base.contains { $0.path == file.path }
                    }
                    result[type] = kept + added
                } else if let patterns {
                    if patterns.isEmpty {
                        result[type] = []
                    } else {
                        let all = allFiles(root, type, manifest)
                        let enabled = apply(patterns, to: all, root: root)
                        result[type] = all.filter { enabled.contains($0.path) }
                    }
                } else if let entries = manifest?[type] {
                    result[type] = manifestFiles(entries, root: root, type)
                } else {
                    result[type] = conventional(root, type)
                }
            }
            return result
        }
        if let manifest {
            for type in ResourceType.allCases {
                result[type] = manifest[type].map { manifestFiles($0, root: root, type) } ?? []
            }
            return result
        }
        var anyFolder = false
        for type in ResourceType.allCases {
            let dir = root.appending(path: type.rawValue)
            if FileManager.default.fileExists(atPath: dir.path) { anyFolder = true }
            result[type] = conventional(root, type)
        }
        return anyFolder ? result : nil
    }

    /// The `pi` key of package.json: only lists made of strings count.
    static func manifest(_ root: URL) -> [ResourceType: [String]]? {
        guard let pi = json(root.appending(path: "package.json"))?["pi"] as? [String: Any] else { return nil }
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
    static func allFiles(_ root: URL, _ type: ResourceType, _ manifest: [ResourceType: [String]]?) -> [URL] {
        if let entries = manifest?[type], !entries.isEmpty { return manifestFiles(entries, root: root, type) }
        return conventional(root, type)
    }

    static func conventional(_ root: URL, _ type: ResourceType) -> [URL] {
        let dir = root.appending(path: type.rawValue)
        return FileManager.default.fileExists(atPath: dir.path) ? collect(dir, type) : []
    }

    /// Manifest paths and globs, then its own `!`/`+`/`-` patterns.
    static func manifestFiles(_ entries: [String], root: URL, _ type: ResourceType) -> [URL] {
        let paths = entries.filter { !isOverride($0) }.flatMap { entry -> [URL] in
            hasGlob(entry) ? expandGlob(entry, root: root) : [path(entry, in: root)]
        }
        var files: [URL] = []
        for path in paths where FileManager.default.fileExists(atPath: path.path) {
            files += FileWalk.isDirectory(path) ? collect(path, type) : [path]
        }
        let enabled = apply(entries.filter(isOverride), to: files, root: root)
        return files.filter { enabled.contains($0.path) }
    }

    // MARK: - Folder discovery (Pi's collectResourceFiles)

    static func collect(_ dir: URL, _ type: ResourceType) -> [URL] {
        switch type {
        case .skills: skillFiles(dir, depth: 0)
        case .extensions: extensionFiles(dir)
        case .prompts: files(dir, extension: "md", depth: 0)
        case .themes: files(dir, extension: "json", depth: 0)
        }
    }

    /// A folder with SKILL.md is one skill; else `.md` files directly in the root and skills in subfolders.
    static func skillFiles(_ dir: URL, depth: Int) -> [URL] {
        guard depth < 12 else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if names.contains("SKILL.md"), isFile(dir.appending(path: "SKILL.md")) { return [dir.appending(path: "SKILL.md")] }
        var result: [URL] = []
        for child in FileWalk.children(of: dir) where child.lastPathComponent != "node_modules" {
            if FileWalk.isDirectory(child) {
                result += skillFiles(child, depth: depth + 1)
            } else if depth == 0, child.pathExtension == "md", isFile(child) {
                result.append(child)
            }
        }
        return result
    }

    /// The folder's own entry (manifest `extensions`, `index.ts`, `index.js`), else `.ts`/`.js`
    /// files in it and the entries of its subfolders.
    static func extensionFiles(_ dir: URL) -> [URL] {
        if let own = extensionEntry(dir) { return own }
        var result: [URL] = []
        for child in FileWalk.children(of: dir) where child.lastPathComponent != "node_modules" {
            if FileWalk.isDirectory(child) {
                result += extensionEntry(child) ?? []
            } else if ["ts", "js"].contains(child.pathExtension), isFile(child) {
                result.append(child)
            }
        }
        return result
    }

    static func extensionEntry(_ dir: URL) -> [URL]? {
        if let listed = manifest(dir)?[.extensions], !listed.isEmpty {
            let found = listed.map { path($0, in: dir) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if !found.isEmpty { return found }
        }
        for name in ["index.ts", "index.js"] where FileManager.default.fileExists(atPath: dir.appending(path: name).path) {
            return [dir.appending(path: name)]
        }
        return nil
    }

    static func files(_ dir: URL, extension ext: String, depth: Int) -> [URL] {
        guard depth < 12 else { return [] }
        var result: [URL] = []
        for child in FileWalk.children(of: dir) where child.lastPathComponent != "node_modules" {
            if FileWalk.isDirectory(child) {
                result += files(child, extension: ext, depth: depth + 1)
            } else if child.pathExtension == ext, isFile(child) {
                result.append(child)
            }
        }
        return result
    }

    // MARK: - Patterns

    static func isOverride(_ pattern: String) -> Bool {
        pattern.hasPrefix("!") || pattern.hasPrefix("+") || pattern.hasPrefix("-")
    }

    static func hasGlob(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?")
    }

    /// Pi's applyPatterns: plain patterns include (all when there are none), `!` excludes,
    /// `+path` adds an exact path back, `-path` removes an exact path. Returns enabled paths.
    static func apply(_ patterns: [String], to files: [URL], root: URL) -> Set<String> {
        var includes: [String] = [], excludes: [String] = [], forceIn: [String] = [], forceOut: [String] = []
        for pattern in patterns {
            switch pattern.first {
            case "+": forceIn.append(String(pattern.dropFirst()))
            case "-": forceOut.append(String(pattern.dropFirst()))
            case "!": excludes.append(String(pattern.dropFirst()))
            default: includes.append(pattern)
            }
        }
        var result = includes.isEmpty ? files : files.filter { matches($0, includes, root: root) }
        if !excludes.isEmpty { result = result.filter { !matches($0, excludes, root: root) } }
        for file in files where !forceIn.isEmpty && matchesExactly(file, forceIn, root: root) {
            if !result.contains(where: { $0.path == file.path }) { result.append(file) }
        }
        if !forceOut.isEmpty { result = result.filter { !matchesExactly($0, forceOut, root: root) } }
        return Set(result.map(\.path))
    }

    /// Pi's applyAutoloadDisabledPatterns: each pattern turns the files it matches on (plain, `+`)
    /// or off (`!`, `-`); a later pattern wins. Files no pattern names are left out.
    static func autoloadDelta(_ files: [URL], _ patterns: [String], root: URL) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for pattern in patterns {
            let first = pattern.first
            let target = isOverride(pattern) ? String(pattern.dropFirst()) : pattern
            let exact = first == "+" || first == "-"
            for file in files where exact ? matchesExactly(file, [target], root: root) : matches(file, [target], root: root) {
                result[file.path] = first != "-" && first != "!"
            }
        }
        return result
    }

    /// Glob match against the path relative to the package, the file name or the absolute path;
    /// for a SKILL.md also against its folder.
    static func matches(_ file: URL, _ patterns: [String], root: URL) -> Bool {
        var candidates = [relative(file, to: root), file.lastPathComponent, file.path]
        if file.lastPathComponent == "SKILL.md" {
            let folder = file.deletingLastPathComponent()
            candidates += [relative(folder, to: root), folder.lastPathComponent, folder.path]
        }
        return patterns.contains { pattern in
            guard let regex = globRegex(pattern) else { return false }
            return candidates.contains { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        }
    }

    static func matchesExactly(_ file: URL, _ patterns: [String], root: URL) -> Bool {
        var candidates = [relative(file, to: root), file.path]
        if file.lastPathComponent == "SKILL.md" {
            let folder = file.deletingLastPathComponent()
            candidates += [relative(folder, to: root), folder.path]
        }
        return patterns.contains { pattern in
            let normalized = pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern
            return candidates.contains(normalized)
        }
    }

    static func relative(_ url: URL, to root: URL) -> String {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }

    /// A minimatch-style glob as an anchored regex: `**` any folders, `*` and `?` within one
    /// name, `[...]` classes and `{a,b}` alternatives.
    static func globRegex(_ pattern: String) -> NSRegularExpression? {
        var regex = "^"
        let chars = Array(pattern)
        var index = 0
        var braces = 0
        while index < chars.count {
            let char = chars[index]
            switch char {
            case "*":
                if index + 1 < chars.count, chars[index + 1] == "*" {
                    if index + 2 < chars.count, chars[index + 2] == "/" {
                        regex += "(?:.*/)?"
                        index += 2
                    } else {
                        regex += ".*"
                        index += 1
                    }
                } else {
                    regex += "[^/]*"
                }
            case "?": regex += "[^/]"
            case "[":
                if let close = chars[(index + 1)...].firstIndex(of: "]") {
                    var body = String(chars[(index + 1)..<close])
                    if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                    regex += "[" + body.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    index = close
                } else {
                    regex += "\\["
                }
            case "{":
                braces += 1
                regex += "(?:"
            case "}" where braces > 0:
                braces -= 1
                regex += ")"
            case "," where braces > 0:
                regex += "|"
            default:
                regex += NSRegularExpression.escapedPattern(for: String(char))
            }
            index += 1
        }
        return try? NSRegularExpression(pattern: regex + "$")
    }

    /// Paths matching a glob under `root`, sorted. Like Pi, names starting with a dot are not
    /// matched by wildcards; unlike Pi, `**` does not descend into node_modules.
    static func expandGlob(_ pattern: String, root: URL) -> [URL] {
        var pattern = pattern
        while pattern.hasPrefix("./") { pattern.removeFirst(2) }
        var current = [pattern.hasPrefix("/") ? URL(filePath: "/") : root]
        for segment in pattern.split(separator: "/").map(String.init) {
            var next: [URL] = []
            if segment == "**" {
                for dir in current { next += [dir] + descendants(dir, depth: 0) }
            } else if hasGlob(segment) || segment.contains("[") || segment.contains("{") {
                guard let regex = globRegex(segment) else { return [] }
                for dir in current where FileWalk.isDirectory(dir) {
                    next += FileWalk.children(of: dir).filter { child in
                        let name = child.lastPathComponent
                        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
                    }
                }
            } else {
                next = current.map { $0.appending(path: segment) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
            }
            current = next
        }
        var seen: Set<String> = []
        return current.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }.sorted { $0.path < $1.path }
    }

    static func descendants(_ dir: URL, depth: Int) -> [URL] {
        guard depth < 12, FileWalk.isDirectory(dir) else { return [] }
        return FileWalk.children(of: dir).filter { $0.lastPathComponent != "node_modules" }.flatMap { child in
            [child] + descendants(child, depth: depth + 1)
        }
    }

    // MARK: - Helpers

    /// Node's `resolve(root, entry)`: an absolute path stays, anything else is relative to `root`.
    static func path(_ entry: String, in root: URL) -> URL {
        (entry.hasPrefix("/") ? URL(filePath: entry) : root.appending(path: entry)).standardizedFileURL
    }

    static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func isFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }
}
