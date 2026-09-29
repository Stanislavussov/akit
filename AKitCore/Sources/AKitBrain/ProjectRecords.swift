import AKitFoundation
import Foundation

/// What AKit keeps about a project in the project store (the brain's `projects/<id>/`, or a
/// local folder on a work Mac, see `ProjectStore`): its id, the lock of written files and the
/// answers of the last Apply.
public enum ProjectRecords {
    /// What AKit wrote into a project, stored in `<project store>/<id>/lock.json`.
    public struct Lock: Codable, Hashable, Sendable {
        public struct Entry: Codable, Hashable, Sendable {
            /// Content hash of a written file; nil for a link.
            public var sha256: String?
            /// Destination of a written link.
            public var link: String?
            public var layers: [String]

            public init(sha256: String?, link: String?, layers: [String]) {
                self.sha256 = sha256
                self.link = link
                self.layers = layers
            }
        }

        /// Brain commit the files were rendered from.
        public var brainCommit: String?
        /// The brain had uncommitted changes, so the commit alone doesn't reproduce the render.
        public var brainDirty: Bool
        public var files: [String: Entry]
        /// Project-owned files (AGENTS.md, templates): hash of the layers' version when it
        /// was last written or offered. A suggestion appears only when that version changes.
        public var templates: [String: String]?

        public init(brainCommit: String?, brainDirty: Bool, files: [String: Entry], templates: [String: String]? = nil) {
            self.brainCommit = brainCommit
            self.brainDirty = brainDirty
            self.files = files
            self.templates = templates
        }
    }

    // MARK: - Home

    /// The id of this machine's home folder: `home/<machine name or host name>`, one lock per Mac.
    public static func homeID(hostName: String = ProcessInfo.processInfo.hostName, machineName: String? = nil) -> String {
        var host = (machineName.flatMap { $0.isEmpty ? nil : $0 } ?? hostName).lowercased()
        if host.hasSuffix(".local") { host.removeLast(".local".count) }
        let name = cleanPath(host.replacingOccurrences(of: "/", with: "-"))
        return "home/" + (name.isEmpty ? "mac" : name)
    }

    // MARK: - Project id

    /// `github.com/owner/repo` from the `origin` remote, else `local/<path under the projects root>`.
    public static func projectID(for project: URL, projectsRoot: URL, env: HarnessEnvironment) async -> String {
        if let git = env.findExecutable("git"),
           let result = await ProcessRunner.run(git, arguments: ["remote", "get-url", "origin"], directory: project,
                                                environment: env.variables.merging(["PATH": env.pathForChildProcesses]) { $1 },
                                                timeout: 10),
           result.succeeded, let id = normalizedRemote(result.output) {
            return id
        }
        return localID(path: project.standardizedFileURL.path, projectsRoot: projectsRoot.standardizedFileURL.path)
    }

    /// `local/<path under the projects root>`, for a project without a git remote.
    public static func localID(path: String, projectsRoot root: String) -> String {
        if path.hasPrefix(root + "/") { return "local/" + cleanPath(String(path.dropFirst(root.count + 1))) }
        // Outside the projects root: the folder name plus a short hash, so two "app" folders differ.
        return "local/" + cleanPath((path as NSString).lastPathComponent) + "-" + Checksum.sha256(Data(path.utf8)).prefix(8)
    }

    /// `git@github.com:Owner/Repo.git`, `https://user@github.com/owner/repo`, `ssh://git@host:22/o/r.git`
    /// → `github.com/owner/repo`.
    public static func normalizedRemote(_ remote: String) -> String? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        } else if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") {
            text.replaceSubrange(colon...colon, with: "/")  // scp form host:path
        }
        // user[:password]@ before the host; a password may itself hold "/", so cut at the last "@".
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        var parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        if let colon = parts[0].firstIndex(of: ":") { parts[0] = String(parts[0][..<colon]) }  // port
        if parts[parts.count - 1].hasSuffix(".git") { parts[parts.count - 1].removeLast(4) }
        let id = cleanPath(parts.joined(separator: "/").lowercased())
        return id.isEmpty ? nil : id
    }

    /// Only `[a-z0-9._-]` per component; no `.`/`..` components.
    private static func cleanPath(_ path: String) -> String {
        path.split(separator: "/")
            .map { component in
                String(component.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" })
            }
            .filter { $0 != "." && $0 != ".." && $0 != ".git" && !$0.isEmpty }
            .joined(separator: "/")
    }

    /// Answers saved by the last Apply, to prefill the form.
    public static func savedAnswers(id: String, in store: ProjectStore) -> ProjectAnswers? {
        store.savedFile(id: id, "answers.json").flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(ProjectAnswers.self, from: $0) }
    }

    public static func savedLock(id: String, in store: ProjectStore) -> Lock? {
        store.savedFile(id: id, "lock.json").flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Lock.self, from: $0) }
    }

    /// Writes lock.json (and answers.json, when given) under `<store>/<id>`.
    public static func save(_ lock: Lock, answers: ProjectAnswers?, id: String, in store: ProjectStore) throws {
        let folder = store.folder(id: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let answers { try encoder.encode(answers).write(to: folder.appending(path: "answers.json"), options: .atomic) }
        try encoder.encode(lock).write(to: folder.appending(path: "lock.json"), options: .atomic)
    }
}
