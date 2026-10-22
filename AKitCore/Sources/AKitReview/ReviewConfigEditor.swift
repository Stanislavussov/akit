import AKitBrain
import AKitFoundation
import Foundation

/// Changes to review's configuration files: a role, a scenario or the defaults, in the brain
/// or in a project (Review → Roles and Scenarios; `docs/design/review.md`, "Screens for
/// configuration"). Every save shows its diff first; on a work Mac a brain save also names
/// the work words it holds (R17).
public enum ReviewConfigEditor {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public enum Kind: String, Sendable, CaseIterable {
        /// `profile`: a project profile (`projects/<slug>.yaml`); its id is the slug.
        case role, scenario, defaults, profile
    }

    /// Where an item is saved: the brain layer `review`, or one project.
    public enum Level: Hashable, Sendable {
        case brain
        case project(String)

        public var title: String {
            switch self {
            case .brain: "Brain"
            case .project(let slug): "Project \(slug)"
            }
        }
    }

    public struct Save: Sendable {
        public var kind: Kind
        public var id: String
        public var level: Level
        public var file: URL
        public var old: String?
        public var new: String
        /// `-`/`+` lines.
        public var diff: [String]
        /// Hosts, project paths, organizations and e-mail addresses of the work profiles found in
        /// the text: a brain save from a work Mac shows them before it goes to the brain.
        public var workWords: [String]
    }

    public static func file(_ kind: Kind, id: String, level: Level, home: URL, brain: URL) -> URL {
        let root = switch level {
        case .brain: ReviewPaths.brainLayer(brain: brain)
        case .project(let slug): ReviewPaths(home: home).projectFolder(slug)
        }
        return switch kind {
        case .role: root.appending(path: "skills/review-\(id)/SKILL.md")
        case .scenario: root.appending(path: "scenarios/\(id).yaml")
        case .defaults: root.appending(path: "review.yaml")
        case .profile: ReviewPaths(home: home).profile(id)
        }
    }

    /// Checks the text and shows what a save would change. Nothing is written.
    public static func plan(_ kind: Kind, id: String, text: String, level: Level, home: URL, brain: URL) throws -> Save {
        if case .project = level, kind == .defaults {
            throw Failure(message: "A project's defaults live in its profile's review: block.")
        }
        if case .project(let slug) = level, !ReviewYAML.isID(slug) { throw Failure(message: "\(slug) is not a project profile id.") }
        guard kind == .defaults || ReviewYAML.isID(id) else { throw Failure(message: "\(id): use a-z, 0-9 and -.") }
        switch kind {
        case .role:
            let role = try ReviewRole.parse(text, source: .brain)
            guard role.id == id else { throw Failure(message: "The name must be review-\(id).") }
        case .scenario:
            let scenario = try ReviewScenario.parse(text, source: .brain)
            guard scenario.id == id else { throw Failure(message: "The id must be \(id).") }
        case .defaults:
            _ = try ReviewSettingsPatch.parse(ReviewYAML.map(text), where: "review.yaml")
        case .profile:
            guard level == .project(id) else { throw Failure(message: "A project profile is saved in its own project.") }
            _ = try ReviewProfile.parse(text, slug: id)
        }
        let url = file(kind, id: id, level: level, home: home, brain: brain)
        let old = try? String(contentsOf: url, encoding: .utf8)
        let diff = TextDiff.unified(TextDiff.lines(from: old ?? "", to: text))
        let words = level == .brain && MachineProfile.load(home: home).isWork ? workWords(in: text, home: home) : []
        return Save(kind: kind, id: id, level: level, file: url, old: old, new: text, diff: diff, workWords: words)
    }

    /// Writes it; a brain save is committed in the brain.
    public static func apply(_ save: Save, brain: URL, env: HarnessEnvironment) async throws {
        try FileManager.default.createDirectory(at: save.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(save.new.utf8).write(to: save.file, options: .atomic)
        if save.level == .brain {
            let path = String(save.file.resolvingSymlinksInPath().path.dropFirst(brain.resolvingSymlinksInPath().path.count + 1))
            do {
                try await BrainRemove.commit([path], "Review: \(save.old == nil ? "add" : "edit") \(save.kind.rawValue) \(save.id)", in: brain, env: env)
            } catch {
                throw Failure(message: error.message)
            }
        }
    }

    /// Duplicate to Project…: the brain's (or built-in) text as the project's own copy.
    public static func duplicate(_ kind: Kind, id: String, toProject slug: String, catalog: ReviewCatalog, home: URL, brain: URL) throws -> Save {
        let text: String? = switch kind {
        case .role: catalog.roles.first { $0.id == id }?.text
        case .scenario: catalog.scenarios.first { $0.id == id }?.text
        case .defaults, .profile: nil
        }
        guard let text else { throw Failure(message: "There is no \(kind.rawValue) \(id) in the brain to copy.") }
        return try plan(kind, id: id, text: text, level: .project(slug), home: home, brain: brain)
    }

    /// Review Settings… → Extra servers: the profile's `mcp: extra_servers:` set to `servers`,
    /// the rest of the file (comments too) as it was. Nothing is written; the save shows its diff.
    public static func extraServers(_ servers: [String], profile slug: String, home: URL, brain: URL) throws -> Save {
        for server in servers where !ReviewMCPAccess.isServerName(server) {
            throw Failure(message: "\(server) is not a Pi MCP server name (letters, digits, _ and -).")
        }
        let url = file(.profile, id: slug, level: .project(slug), home: home, brain: brain)
        guard let old = try? String(contentsOf: url, encoding: .utf8) else { throw Failure(message: "There is no project profile \(slug).") }
        let text = settingExtraServers(servers, in: old)
        // The edit may change mcp: extra_servers and nothing else.
        var parsed = try? ReviewProfile.parse(text, slug: slug)
        let before = try? ReviewProfile.parse(old, slug: slug)
        parsed?.mcp.extraServers = before?.mcp.extraServers ?? []
        guard let after = try? ReviewProfile.parse(text, slug: slug), after.mcp.extraServers == servers, let before, parsed == before else {
            throw Failure(message: "AKit couldn't change mcp: in \(url.lastPathComponent) by itself. Edit… the file and set "
                          + "mcp: extra_servers: [\(servers.joined(separator: ", "))].")
        }
        return try plan(.profile, id: slug, text: text, level: .project(slug), home: home, brain: brain)
    }

    /// A line split into its YAML and its trailing ` # comment` (kept as it was).
    static func comment(_ line: String) -> (code: String, comment: String) {
        guard var start = line.range(of: " #")?.lowerBound else { return (line, "") }
        while start > line.startIndex, line[line.index(before: start)] == " " || line[line.index(before: start)] == "\t" {
            start = line.index(before: start)
        }
        return (String(line[..<start]), String(line[start...]))
    }

    /// The YAML text with `mcp: extra_servers: [...]` set: in a block `mcp:` (its own line, or a
    /// one-line `extra_servers:` with a list under it), in a one-line `mcp: { … }`, or a new
    /// `mcp:` block at the end. Other lines stay byte for byte; a trailing comment and CRLF
    /// line ends stay too.
    static func settingExtraServers(_ servers: [String], in original: String) -> String {
        let crlf = original.contains("\r\n")
        let text = crlf ? original.replacingOccurrences(of: "\r\n", with: "\n") : original
        let result = settingExtraServersLF(servers, in: text)
        return crlf ? result.replacingOccurrences(of: "\n", with: "\r\n") : result
    }

    static func settingExtraServersLF(_ servers: [String], in text: String) -> String {
        let list = "[" + servers.joined(separator: ", ") + "]"
        var lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("mcp:") }) else {
            guard !servers.isEmpty else { return text }
            var result = text
            if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
            return result + "mcp:\n  extra_servers: \(list)\n"
        }
        let (head, headComment) = comment(lines[start])
        let rest = head.dropFirst("mcp:".count).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("{") {
            // A flow mapping on one line.
            var line = head
            if let range = line.range(of: #"extra_servers:\s*\[[^\]]*\]"#, options: .regularExpression) {
                line.replaceSubrange(range, with: "extra_servers: \(list)")
            } else if let open = line.firstIndex(of: "{"), let close = line.lastIndex(of: "}"), open < close {
                let inside = line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                let body = inside.isEmpty ? "extra_servers: \(list)" : inside + ", extra_servers: \(list)"
                line.replaceSubrange(open...close, with: "{ \(body) }")
            }
            lines[start] = line + headComment
            return lines.joined(separator: "\n")
        }
        // A block: the lines after `mcp:` that are indented, blank or comments.
        var end = start + 1
        while end < lines.count, lines[end].isEmpty || lines[end].hasPrefix(" ") || lines[end].hasPrefix("\t") || lines[end].hasPrefix("#") {
            end += 1
        }
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty || lines[end - 1].hasPrefix("#") { end -= 1 }
        let indent = lines[(start + 1)..<end].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
            .map { String($0.prefix { $0 == " " || $0 == "\t" }) } ?? "  "
        if let at = lines[(start + 1)..<end].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("extra_servers:") }) {
            let own = lines[at].prefix { $0 == " " || $0 == "\t" }.count
            var stop = at + 1
            // A block list under it: `- name` lines indented as much or more.
            while stop < end, lines[stop].trimmingCharacters(in: .whitespaces).hasPrefix("-"),
                  lines[stop].prefix(while: { $0 == " " || $0 == "\t" }).count >= own {
                stop += 1
            }
            lines.replaceSubrange(at..<stop, with: [String(lines[at].prefix(own)) + "extra_servers: \(list)" + comment(lines[at]).comment])
        } else {
            lines.insert(indent + "extra_servers: \(list)", at: start + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// Reset to Brain: the project's own copy goes to the Trash; the brain's applies again.
    public static func resetToBrain(_ kind: Kind, id: String, project slug: String, home: URL, brain: URL,
                                    trash: (URL) throws -> URL? = Trash.move) throws {
        guard kind != .profile else { throw Failure(message: "A project profile has no brain copy to reset to.") }
        let url = file(kind, id: id, level: .project(slug), home: home, brain: brain)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure(message: "\(slug) has no own \(kind.rawValue) \(id).") }
        _ = try trash(kind == .role ? url.deletingLastPathComponent() : url)
    }

    /// The first roles, scenarios and defaults (`ReviewBuiltIns`) into the brain layer `review`,
    /// for those it doesn't have yet. Committed. Returns the paths written.
    @discardableResult
    public static func addBuiltIns(brain: URL, env: HarnessEnvironment) async throws -> [String] {
        if let problem = await BrainGit.commitProblem(brain: brain, env: env) { throw Failure(message: problem) }
        var files: [(Kind, String, String)] = [(.defaults, "", ReviewBuiltIns.defaultsYAML + "\n")]
        files += ReviewBuiltIns.roleIDs.compactMap { id in ReviewBuiltIns.roleFiles[id].map { (.role, id, $0) } }
        files += ReviewBuiltIns.scenarioIDs.compactMap { id in ReviewBuiltIns.scenarioFiles[id].map { (.scenario, id, $0 + "\n") } }
        var written: [String] = []
        let root = brain.resolvingSymlinksInPath().path
        for (kind, id, text) in files {
            let url = file(kind, id: id, level: .brain, home: env.homeDirectory, brain: brain)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            written.append(String(url.resolvingSymlinksInPath().path.dropFirst(root.count + 1)))
        }
        let readme = ReviewPaths.brainLayer(brain: brain).appending(path: "README.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try Data(layerReadme.utf8).write(to: readme)
            written.append("layers/review/README.md")
        }
        guard !written.isEmpty else { return [] }
        do {
            try await BrainRemove.commit(written, "Review: add the first roles and scenarios", in: brain, env: env)
        } catch {
            throw Failure(message: error.message)
        }
        return written
    }

    static let layerReadme = """
    # AKit Review

    The generic roles (`skills/review-<id>/SKILL.md`), scenarios (`scenarios/<id>.yaml`) and defaults
    (`review.yaml`) of AKit Review. Not a layer a project picks: AKit passes these skills to review
    passes only. Work-only roles live in `~/.akit/local/review/projects/<project>/` on the work Mac.

    """

    /// Work words of every profile on this Mac found in `text`, case-insensitive; plus any
    /// e-mail address.
    public static func workWords(in text: String, home: URL) -> [String] {
        let catalog = ReviewCatalog.load(home: home, brain: nil)
        var words = Set<String>()
        for profile in catalog.profiles {
            if let host = URL(string: profile.gitlabHost)?.host() { words.insert(host) }
            words.insert(profile.gitlabProjectPath)
            if let last = profile.gitlabProjectPath.split(separator: "/").last, last.count >= 4 { words.insert(String(last)) }
            if profile.project.count >= 4 { words.insert(profile.project) }
            // MCP server names often name the company's systems.
            for server in profile.mcp.servers + profile.mcp.extraServers where server.count >= 4 && !["gitlab", "azure-devops", "jira"].contains(server.lowercased()) {
                words.insert(server)
            }
            if let tracker = profile.tracker {
                if tracker.org.count >= 3 { words.insert(tracker.org) }
                if tracker.project.count >= 4 { words.insert(tracker.project) }
            }
        }
        let lower = text.lowercased()
        var found = words.filter { lower.contains($0.lowercased()) }
        for match in text.matches(of: /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/) { found.insert(String(match.output)) }
        return found.sorted()
    }
}
