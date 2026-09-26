import CryptoKit
import Foundation

/// Applies a render to a project folder: what would change, then backup + write +
/// answers and lock in the brain (`projects/<id>/`). Nothing from AKit lands in the project.
public enum ProjectSetup {
    /// What AKit wrote into a project, stored in `brain/projects/<id>/lock.json`.
    public struct Lock: Codable, Hashable, Sendable {
        public struct Entry: Codable, Hashable, Sendable {
            /// Content hash of a written file; nil for a link.
            public var sha256: String?
            /// Destination of a written link.
            public var link: String?
            public var layers: [String]
        }

        /// Brain commit the files were rendered from.
        public var brainCommit: String?
        /// The brain had uncommitted changes, so the commit alone doesn't reproduce the render.
        public var brainDirty: Bool
        public var files: [String: Entry]
    }

    public struct Change: Identifiable, Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case create, update, same
            /// Written by an earlier render, not by this one: moved to the Trash.
            case remove
            /// Written by an earlier render, not by this one, but edited since: left alone.
            case keepEdited
        }

        public var id: String { path }
        public let path: String
        public let kind: Kind
        /// Current text in the project, if it is text.
        public let oldText: String?
        /// Rendered text, if it is text.
        public let newText: String?
        /// The project has this file, but AKit didn't write it (not in the last lock).
        public let replacesUnmanaged: Bool
        public let layers: [String]
        /// AKit wrote it, but it was edited by hand since (hash differs from the lock).
        public var editedSinceRender = false
    }

    public struct Plan: Sendable {
        public let project: URL
        public let id: String
        public let answers: ProjectAnswers
        public let render: Render.Result
        /// Every path, including unchanged ones, sorted.
        public let changes: [Change]
        /// Things in the project that stop Apply.
        public let blockers: [String]
        let previous: Lock?
        /// Current bytes of the paths the plan changes, to spot edits made after the preview.
        let snapshot: [String: Data?]

        public var canApply: Bool { render.errors.isEmpty && blockers.isEmpty }
    }

    public struct Outcome: Sendable {
        public let backup: URL?
        public let written: [String]
        public let removed: [String]
        public let notes: [String]
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    // MARK: - Home

    /// The brain id of this machine's home folder: `home/<host name>`, one lock per Mac.
    public static func homeID(hostName: String = ProcessInfo.processInfo.hostName) -> String {
        var host = hostName.lowercased()
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
        let path = project.standardizedFileURL.path, root = projectsRoot.standardizedFileURL.path
        if path.hasPrefix(root + "/") { return "local/" + cleanPath(String(path.dropFirst(root.count + 1))) }
        // Outside the projects root: the folder name plus a short hash, so two "app" folders differ.
        return "local/" + cleanPath(project.lastPathComponent) + "-" + sha256(Data(path.utf8)).prefix(8)
    }

    /// `git@github.com:Owner/Repo.git`, `https://user@github.com/owner/repo`, `ssh://git@host:22/o/r.git`
    /// → `github.com/owner/repo`.
    static func normalizedRemote(_ remote: String) -> String? {
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

    static func metadataFolder(id: String, brain root: URL) -> URL { root.appending(path: "projects/\(id)") }

    /// Answers saved by the last Apply, to prefill the form.
    public static func savedAnswers(id: String, brain root: URL) -> ProjectAnswers? {
        let url = metadataFolder(id: id, brain: root).appending(path: "answers.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ProjectAnswers.self, from: $0) }
    }

    static func savedLock(id: String, brain root: URL) -> Lock? {
        let url = metadataFolder(id: id, brain: root).appending(path: "lock.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Lock.self, from: $0) }
    }

    // MARK: - Plan

    public static func plan(project: URL, id: String, answers: ProjectAnswers, brain: Brain, forHome: Bool = false) -> Plan {
        let fm = FileManager.default
        let render = Render.render(answers, brain: brain, projectName: project.lastPathComponent, forHome: forHome)
        let previous = savedLock(id: id, brain: brain.root)
        var changes: [Change] = []
        var blockers: [String] = []
        var snapshot: [String: Data?] = [:]
        let rendered = Set(render.outputs.map(\.path))

        for output in render.outputs {
            let url = project.appending(path: output.path)
            let managed = previous?.files[output.path] != nil
            if let problem = escapes(output.path, project: project) {
                blockers.append(problem)
                continue
            }
            switch output.content {
            case .link(let destination):
                if let current = try? fm.destinationOfSymbolicLink(atPath: url.path) {
                    changes.append(Change(path: output.path, kind: current == destination ? .same : .update,
                                          oldText: "→ \(current)", newText: "→ \(destination)", replacesUnmanaged: !managed, layers: output.layers))
                } else if fm.fileExists(atPath: url.path) {
                    let items = (try? fm.contentsOfDirectory(atPath: url.path))?.filter { $0 != ".DS_Store" } ?? ["?"]
                    if items.isEmpty {
                        changes.append(Change(path: output.path, kind: .update, oldText: "(empty folder)", newText: "→ \(destination)",
                                              replacesUnmanaged: true, layers: output.layers))
                    } else {
                        blockers.append("\(output.path) is a folder with \(items.count) item\(items.count == 1 ? "" : "s") (\(items.sorted().prefix(3).joined(separator: ", "))). Move them into the brain or \(Render.skillsFolder) first; AKit links \(output.path) to \(destination).")
                    }
                } else {
                    changes.append(Change(path: output.path, kind: .create, oldText: nil, newText: "→ \(destination)",
                                          replacesUnmanaged: false, layers: output.layers))
                }
                snapshot[output.path] = state(url)
            case .data(let data):
                var isFolder: ObjCBool = false
                if isLink(url) == false, fm.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                    blockers.append("\(output.path) is a folder in the project; AKit wants to write a file there.")
                    continue
                }
                if let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) {
                    // A link (e.g. CLAUDE.md -> AGENTS.md) is replaced by a file; say so.
                    changes.append(Change(path: output.path, kind: .update, oldText: "→ \(destination) (a link)", newText: output.text,
                                          replacesUnmanaged: true, layers: output.layers))
                } else {
                    let current = try? Data(contentsOf: url)
                    let kind: Change.Kind = current == nil ? .create : current == data ? .same : .update
                    var change = Change(path: output.path, kind: kind, oldText: current.flatMap { String(data: $0, encoding: .utf8) },
                                        newText: output.text, replacesUnmanaged: current != nil && !managed, layers: output.layers)
                    if kind == .update, let current, let entry = previous?.files[output.path], entry.sha256 != sha256(current) {
                        change.editedSinceRender = true
                    }
                    changes.append(change)
                }
                snapshot[output.path] = state(url)
            }
        }

        for (path, entry) in previous?.files ?? [:] where !rendered.contains(path) {
            let url = project.appending(path: path)
            guard escapes(path, project: project) == nil else { continue }
            if let link = entry.link {
                guard (try? fm.destinationOfSymbolicLink(atPath: url.path)) == link else { continue }
                changes.append(Change(path: path, kind: .remove, oldText: "→ \(link)", newText: nil, replacesUnmanaged: false, layers: entry.layers))
                snapshot[path] = state(url)
            } else if !isLink(url), let data = try? Data(contentsOf: url) {
                let edited = entry.sha256 != sha256(data)
                changes.append(Change(path: path, kind: edited ? .keepEdited : .remove, oldText: String(data: data, encoding: .utf8),
                                      newText: nil, replacesUnmanaged: false, layers: entry.layers))
                snapshot[path] = state(url)
            }
        }

        return Plan(project: project, id: id, answers: answers, render: render,
                    changes: changes.sorted { $0.path < $1.path }, blockers: blockers, previous: previous, snapshot: snapshot)
    }

    // MARK: - Apply

    /// Writes the plan into the project (skipping `excluded` paths), backs up what it
    /// replaces, trashes files an earlier render wrote and this one doesn't, then stores
    /// answers and lock in the brain and commits them.
    public static func apply(_ plan: Plan, excluding excluded: Set<String> = [], brain: Brain, home: URL,
                             env: HarnessEnvironment, trash: (URL) throws -> URL? = SkillRemover.defaultTrash) async throws(Failure) -> Outcome {
        guard plan.canApply else {
            throw Failure(message: (plan.render.errors + plan.blockers).joined(separator: "\n"))
        }
        let fm = FileManager.default
        let outputs = Dictionary(plan.render.outputs.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let todo = plan.changes.filter { !excluded.contains($0.path) && [.create, .update, .remove].contains($0.kind) }

        // Stop if the project changed since the preview (a file, link or folder, or a parent
        // that became a link out of the project).
        for change in todo {
            let url = plan.project.appending(path: change.path)
            if let problem = escapes(change.path, project: plan.project) { throw Failure(message: problem) }
            if state(url) != (plan.snapshot[change.path] ?? nil) {
                throw Failure(message: "\(change.path) changed since the preview. Look at the preview again.")
            }
        }

        var backup: URL?
        var written: [String] = [], removed: [String] = [], notes: [String] = []
        do {
            for change in todo where change.kind != .create {
                let url = plan.project.appending(path: change.path)
                guard isLink(url) || fm.fileExists(atPath: url.path) else { continue }
                if backup == nil { backup = try Backup.newFolder(home: home) }
                try Backup.copy(url, into: backup!, home: home, keepLink: true)
            }
            for change in todo {
                let url = plan.project.appending(path: change.path)
                if change.kind == .remove {
                    _ = try trash(url)
                    removed.append(change.path)
                    removeEmptyFolders(from: url.deletingLastPathComponent(), upTo: plan.project)
                    continue
                }
                guard let output = outputs[change.path] else { continue }
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Whatever is there must go first: a link is only a link (backed up above);
                // a folder goes to the Trash and only when it is empty.
                if isLink(url) {
                    try fm.removeItem(at: url)
                } else if case .link = output.content, fm.fileExists(atPath: url.path) {
                    guard isEmptyFolder(url) else {
                        throw Failure(message: "\(change.path) is no longer an empty folder; nothing replaced it.")
                    }
                    _ = try trash(url)
                }
                switch output.content {
                case .data(let data):
                    try data.write(to: url, options: .atomic)
                case .link(let destination):
                    try fm.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
                }
                written.append(change.path)
            }
        } catch {
            // Record what did happen, so the next preview knows which files AKit wrote.
            var partial = plan.previous ?? Lock(brainCommit: nil, brainDirty: false, files: [:])
            for path in removed { partial.files[path] = nil }
            for path in written { if let output = outputs[path] { partial.files[path] = entry(for: output) } }
            try? save(partial, answers: nil, id: plan.id, brain: brain.root)
            let reason = (error as? Failure)?.message ?? error.localizedDescription
            throw Failure(message: "Writing the project stopped: \(reason) Written: \(written.count), removed: \(removed.count).\(backup.map { " Backup: \($0.path)" } ?? "")")
        }

        // Lock: what AKit now owns in the project. Excluded paths keep their old entry, if any.
        // A file that was already there with the same content stays the user's: AKit never
        // wrote it, so a later render or removal must not trash it.
        let kinds = Dictionary(plan.changes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var lock = Lock(brainCommit: nil, brainDirty: false, files: [:])
        for output in plan.render.outputs {
            if excluded.contains(output.path) {
                if let old = plan.previous?.files[output.path] { lock.files[output.path] = old }
                continue
            }
            if let change = kinds[output.path], change.kind == .same, change.replacesUnmanaged { continue }
            lock.files[output.path] = entry(for: output)
        }
        for change in plan.changes where change.kind == .keepEdited || (change.kind == .remove && excluded.contains(change.path)) {
            if let old = plan.previous?.files[change.path] { lock.files[change.path] = old }
        }

        let isRepo = fm.fileExists(atPath: brain.root.appending(path: ".git").path)
        if isRepo {
            lock.brainCommit = try? await git(["rev-parse", "--short", "HEAD"], in: brain.root, env: env)
            let dirty = (try? await git(["status", "--porcelain", "--", "skills", "layers"], in: brain.root, env: env)) ?? ""
            lock.brainDirty = !dirty.isEmpty
        }
        do {
            try save(lock, answers: plan.answers, id: plan.id, brain: brain.root)
        } catch {
            throw Failure(message: "The project was written, but the answers couldn't be saved in the brain: \(error.localizedDescription)")
        }
        if lock.brainDirty { notes.append("The brain has uncommitted changes in skills/ or layers/; commit them so this render can be reproduced.") }
        if isRepo {
            let path = "projects/\(plan.id)"
            do {
                _ = try await git(["add", "--", path], in: brain.root, env: env)
                let staged = try await git(["diff", "--cached", "--name-only", "--", path], in: brain.root, env: env)
                if !staged.isEmpty {
                    _ = try await git(["commit", "--quiet", "-m", plan.id.hasPrefix("home/") ? "Render the core layer into \(plan.id)" : "Render \(plan.project.lastPathComponent)", "--", path], in: brain.root, env: env)
                }
            } catch {
                notes.append("The answers are saved in the brain but not committed: \(error.message)")
            }
        }
        return Outcome(backup: backup, written: written, removed: removed, notes: notes)
    }

    // MARK: - Helpers

    private static func entry(for output: Render.Output) -> Lock.Entry {
        switch output.content {
        case .data(let data): .init(sha256: sha256(data), link: nil, layers: output.layers)
        case .link(let destination): .init(sha256: nil, link: destination, layers: output.layers)
        }
    }

    /// Writes lock.json (and answers.json, when given) under `projects/<id>`.
    private static func save(_ lock: Lock, answers: ProjectAnswers?, id: String, brain root: URL) throws {
        let folder = metadataFolder(id: id, brain: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let answers { try encoder.encode(answers).write(to: folder.appending(path: "answers.json"), options: .atomic) }
        try encoder.encode(lock).write(to: folder.appending(path: "lock.json"), options: .atomic)
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func isEmptyFolder(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.allSatisfy { $0 == ".DS_Store" } ?? false
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A path that would leave the project folder through `..` or a symlinked parent.
    private static func escapes(_ path: String, project: URL) -> String? {
        let base = project.resolvingSymlinksInPath().standardizedFileURL.path
        // resolvingSymlinksInPath leaves a missing path alone, so resolve the nearest folder
        // that exists (e.g. a linked .agents above a skill folder not created yet).
        var existing = project.appending(path: path).deletingLastPathComponent().standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        let parent = rest.reduce(existing.resolvingSymlinksInPath()) { $0.appending(path: $1) }.standardizedFileURL.path
        guard !path.split(separator: "/").contains(".."), parent == base || parent.hasPrefix(base + "/") else {
            return "\(path) would be written outside the project (through a link). AKit won't write it."
        }
        return nil
    }

    /// What is at a path now, compared before writing: a link's destination, a folder's
    /// listing, or a file's bytes; nil when nothing is there.
    private static func state(_ url: URL) -> Data? {
        let fm = FileManager.default
        if let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) { return Data("link:\(destination)".utf8) }
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isFolder) else { return nil }
        if isFolder.boolValue {
            let items = (try? fm.contentsOfDirectory(atPath: url.path))?.filter { $0 != ".DS_Store" }.sorted() ?? []
            return Data("folder:\(items.joined(separator: "/"))".utf8)
        }
        return (try? Data(contentsOf: url)) ?? Data("unreadable".utf8)
    }

    private static func removeEmptyFolders(from folder: URL, upTo project: URL) {
        let fm = FileManager.default
        var current = folder.standardizedFileURL
        let stop = project.standardizedFileURL.path
        while current.path.hasPrefix(stop + "/"),
              let items = try? fm.contentsOfDirectory(atPath: current.path), items.allSatisfy({ $0 == ".DS_Store" }) {
            try? fm.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }

    private static func git(_ arguments: [String], in root: URL, env: HarnessEnvironment) async throws(Failure) -> String {
        guard let git = env.findExecutable("git") else { throw Failure(message: "git was not found.") }
        let result = await ProcessRunner.run(git, arguments: arguments, directory: root,
                                             environment: env.variables.merging(["PATH": env.pathForChildProcesses]) { $1 }, timeout: 30)
        guard let result, result.succeeded else {
            throw Failure(message: "git \(arguments[0]) failed: \(result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "couldn't start")")
        }
        return result.output.trimmingCharacters(in: .newlines)
    }
}
