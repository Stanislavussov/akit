import AKitBrain
import AKitFoundation
import AKitInsights
import AKitRender
import Foundation

/// Applies a render to a project folder: what would change, then backup + write +
/// answers and lock in the project store (the brain's `projects/<id>/`, or a local
/// folder on a work Mac, see `ProjectStore`). Nothing from AKit lands in the project.
public enum ProjectSetup {
    public struct Change: Identifiable, Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case create, update, same
            /// Written by an earlier render, not by this one: moved to the Trash.
            case remove
            /// Written by an earlier render, not by this one, but edited since: left alone.
            case keepEdited
            /// The project's own file (AGENTS.md, a template); the layers' version changed since
            /// it was last offered. Written only when taken (`accepting` in apply).
            case suggest
            /// The project's own file, different from the layers' version, which it has already
            /// seen. Left alone; still written when taken (`accepting` in apply).
            case own
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
        public let render: RenderResult
        /// Every path, including unchanged ones, sorted.
        public let changes: [Change]
        /// Things in the project that stop Apply.
        public let blockers: [String]
        /// Where the answers and lock are read from and saved to.
        public let store: ProjectStore
        let previous: ProjectRecords.Lock?
        let forHome: Bool
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

    // MARK: - Plan

    /// In a project, AGENTS.md, CLAUDE.md and other template files are the layers' skeleton:
    /// once the project edits one, it is the project's own and a newer layer version is only
    /// offered. Skills (and the link to them) stay AKit's. The home folder follows the core
    /// layer completely.
    static func isProjectOwned(_ path: String, forHome: Bool) -> Bool {
        !forHome && !path.hasPrefix(ProjectBundle.skillsFolder + "/") && path != ".claude/skills"
    }

    /// Everything wrong with a project's bundle before a preview: its own errors and warnings,
    /// then the render's (file clashes, a manual skill without a header, …). For the project form.
    public static func check(_ bundle: ProjectBundle) -> RenderResult {
        Render.render(bundle, forHome: false)
    }

    public static func plan(project: URL, id: String, answers: ProjectAnswers, brain: Brain, store: ProjectStore,
                            forHome: Bool = false) -> Plan {
        let fm = FileManager.default
        let answers = ProjectBundle.pruned(answers, brain: brain, projectName: project.lastPathComponent)
        var render = Render.render(ProjectBundle.resolve(answers, brain: brain, projectName: project.lastPathComponent), forHome: forHome)
        let previous = ProjectRecords.savedLock(id: id, in: store)
        // A skill the project has itself wins over the brain's copy with the same name. Only
        // with a lock: without one AKit can't tell its own earlier copies from the project's.
        // A folder that holds exactly what the brain renders is AKit's too.
        var own: [String: String] = [:]  // lowercased → folder name (APFS ignores case)
        if !forHome, previous != nil {
            for name in ProjectSkills.names(in: project, lock: previous) { own[name.lowercased()] = name }
        }
        let skillPrefix = ProjectBundle.skillsFolder + "/"
        func skillName(_ path: String) -> String? {
            path.hasPrefix(skillPrefix) ? path.dropFirst(skillPrefix.count).split(separator: "/").first.map(String.init) : nil
        }
        var shadowed: Set<String> = []
        for output in render.outputs {
            guard let name = skillName(output.path), let folder = own[name.lowercased()],
                  output.path == "\(skillPrefix)\(name)/SKILL.md", case .data(let data) = output.content else { continue }
            let current = try? Data(contentsOf: project.appending(path: "\(skillPrefix)\(folder)/SKILL.md"))
            if current != data { shadowed.insert(name) }
        }
        var outputs = render.outputs.filter { output in skillName(output.path).map { !shadowed.contains($0) } ?? true }
        var warnings = render.warnings + shadowed.sorted().map { "The project has its own \($0) skill in \(ProjectBundle.skillsFolder); the brain's is not written." }
        // Claude finds the project's own skills through the same link as the brain's, if
        // nothing else is at .claude/skills.
        if !forHome, !own.isEmpty, answers.targets.contains("claude"),
           !outputs.contains(where: { $0.path == ".claude/skills" || $0.path.hasPrefix(".claude/skills/") }) {
            let link = project.appending(path: ".claude/skills")
            if isLink(link) || !fm.fileExists(atPath: link.path) || isEmptyFolder(link) {
                outputs.append(RenderedFile(path: ".claude/skills", content: .link("../\(ProjectBundle.skillsFolder)"), layers: [ProjectBundle.projectSource]))
            } else {
                warnings.append(".claude/skills is a folder, so Claude Code doesn't see the project's own skills in \(ProjectBundle.skillsFolder).")
            }
        }
        render = RenderResult(layers: render.layers, outputs: outputs.sorted { $0.path < $1.path }, errors: render.errors,
                              warnings: warnings, skills: render.skills)
        let rendered = Set(render.outputs.map(\.path))

        var changes: [Change] = []
        var blockers: [String] = []
        var snapshot: [String: Data?] = [:]

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
                        blockers.append("\(output.path) is a folder with \(items.count) item\(items.count == 1 ? "" : "s") (\(items.sorted().prefix(3).joined(separator: ", "))). Move them into the brain or \(ProjectBundle.skillsFolder) first; AKit links \(output.path) to \(destination).")
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
                if isProjectOwned(output.path, forHome: forHome) {
                    let destination = try? fm.destinationOfSymbolicLink(atPath: url.path)
                    let current = destination == nil ? try? Data(contentsOf: url) : nil
                    let written = previous?.files[output.path]?.sha256
                    let offered = previous?.templates?[output.path]
                    let layersChanged = offered != Checksum.sha256(data)
                    let kind: Change.Kind = if destination == nil && current == nil {
                        // Missing: the skeleton, unless the project deleted the file it had.
                        written == nil && offered == nil ? .create : layersChanged ? .suggest : .own
                    } else if current == data {
                        .same
                    } else if let current, written == Checksum.sha256(current) {
                        .update  // untouched since AKit wrote it: still the skeleton
                    } else {
                        layersChanged ? .suggest : .own
                    }
                    changes.append(Change(path: output.path, kind: kind,
                                          oldText: destination.map { "→ \($0) (a link)" } ?? current.flatMap { String(data: $0, encoding: .utf8) },
                                          newText: output.text, replacesUnmanaged: (destination != nil || current != nil) && !managed,
                                          layers: output.layers))
                } else if let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) {
                    // A link (e.g. CLAUDE.md -> AGENTS.md) is replaced by a file; say so.
                    changes.append(Change(path: output.path, kind: .update, oldText: "→ \(destination) (a link)", newText: output.text,
                                          replacesUnmanaged: true, layers: output.layers))
                } else {
                    let current = try? Data(contentsOf: url)
                    let kind: Change.Kind = current == nil ? .create : current == data ? .same : .update
                    var change = Change(path: output.path, kind: kind, oldText: current.flatMap { String(data: $0, encoding: .utf8) },
                                        newText: output.text, replacesUnmanaged: current != nil && !managed, layers: output.layers)
                    if kind == .update, let current, let entry = previous?.files[output.path], entry.sha256 != Checksum.sha256(current) {
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
                let edited = entry.sha256 != Checksum.sha256(data)
                changes.append(Change(path: path, kind: edited ? .keepEdited : .remove, oldText: String(data: data, encoding: .utf8),
                                      newText: nil, replacesUnmanaged: false, layers: entry.layers))
                snapshot[path] = state(url)
            }
        }

        return Plan(project: project, id: id, answers: answers, render: render,
                    changes: changes.sorted { $0.path < $1.path }, blockers: blockers, store: store, previous: previous,
                    forHome: forHome, snapshot: snapshot)
    }

    // MARK: - Apply

    /// Writes the plan into the project (skipping `excluded` paths; a suggestion only when
    /// its path is in `accepting`), backs up what it replaces, trashes files an earlier
    /// render wrote and this one doesn't, then stores answers and lock in the plan's store
    /// and commits them when that store is the brain.
    public static func apply(_ plan: Plan, excluding excluded: Set<String> = [], accepting: Set<String> = [], brain: Brain, home: URL,
                             env: HarnessEnvironment, trash: (URL) throws -> URL? = Trash.move) async throws(Failure) -> Outcome {
        guard plan.canApply else {
            throw Failure(message: (plan.render.errors + plan.blockers).joined(separator: "\n"))
        }
        // The Mac may have become a work Mac (or stopped being one) since the preview.
        guard plan.store.isSamePlace(as: .current(brain: plan.store.brain ?? brain.root, home: home)) else {
            throw Failure(message: "This Mac's role (akit machine) changed since the preview; preview again.")
        }
        let fm = FileManager.default
        let outputs = Dictionary(plan.render.outputs.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let todo = plan.changes.filter { change in
            change.kind == .suggest || change.kind == .own ? accepting.contains(change.path) && !excluded.contains(change.path)
                : !excluded.contains(change.path) && [.create, .update, .remove].contains(change.kind)
        }

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
            var partial = plan.previous ?? ProjectRecords.Lock(brainCommit: nil, brainDirty: false, files: [:])
            for path in removed { partial.files[path] = nil }
            for path in written { if let output = outputs[path] { partial.files[path] = entry(for: output) } }
            try? ProjectRecords.save(partial, answers: nil, id: plan.id, in: plan.store)
            let reason = (error as? Failure)?.message ?? error.localizedDescription
            throw Failure(message: "Writing the project stopped: \(reason) Written: \(written.count), removed: \(removed.count).\(backup.map { " Backup: \($0.path)" } ?? "")")
        }

        // Lock: what AKit now owns in the project. Excluded paths keep their old entry, if any.
        // A file that was already there with the same content stays the user's: AKit never
        // wrote it, so a later render or removal must not trash it.
        let kinds = Dictionary(plan.changes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var lock = ProjectRecords.Lock(brainCommit: nil, brainDirty: false, files: [:])
        for output in plan.render.outputs {
            // Skeleton files: which layers' version the project has seen, so it is offered once.
            // A declined first version isn't "seen": it is offered again next time.
            if isProjectOwned(output.path, forHome: plan.forHome), case .data(let data) = output.content,
               !(kinds[output.path]?.kind == .create && excluded.contains(output.path)) {
                lock.templates = (lock.templates ?? [:]).merging([output.path: Checksum.sha256(data)]) { $1 }
            }
            let kind = kinds[output.path]?.kind
            if excluded.contains(output.path) || ((kind == .suggest || kind == .own) && !accepting.contains(output.path)) {
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
            try ProjectRecords.save(lock, answers: plan.answers, id: plan.id, in: plan.store)
        } catch {
            throw Failure(message: "The project was written, but the answers couldn't be saved in \(plan.store.describe(id: plan.id)): \(error.localizedDescription)")
        }
        // For before/after measurements: a local spool line, never in the brain; can't fail the apply.
        Spool.append(applyEvent(plan), home: home)
        if lock.brainDirty { notes.append("The brain has uncommitted changes in skills/ or layers/; commit them so this render can be reproduced.") }
        // A local store (work Mac) is never committed: nothing about the project reaches the brain.
        if let storeBrain = plan.store.brain, fm.fileExists(atPath: storeBrain.appending(path: ".git").path) {
            let path = "projects/\(plan.id)"
            do {
                _ = try await git(["add", "--", path], in: storeBrain, env: env)
                let staged = try await git(["diff", "--cached", "--name-only", "--", path], in: storeBrain, env: env)
                if !staged.isEmpty {
                    _ = try await git(["commit", "--quiet", "-m", plan.id.hasPrefix("home/") ? "Render the core layer into \(plan.id)" : "Render \(plan.project.lastPathComponent)", "--", path], in: storeBrain, env: env)
                }
            } catch {
                notes.append("The answers are saved in the brain but not committed: \(error.message)")
            }
        }
        return Outcome(backup: backup, written: written, removed: removed, notes: notes)
    }

    /// The spool line an apply leaves: project, layers and skill modes, `ts` in Unix ms (two
    /// applies within one second are both kept).
    static func applyEvent(_ plan: Plan, now: Date = Date()) -> [String: Any] {
        ["v": Spool.lineVersion, "kind": "apply", "project": plan.id, "layers": plan.render.layers,
         "skills": Dictionary(plan.render.skills.map { ($0.name, $0.mode.rawValue) }, uniquingKeysWith: { _, last in last }), "ts": Spool.milliseconds(now)]
    }

    // MARK: - Helpers

    private static func entry(for output: RenderedFile) -> ProjectRecords.Lock.Entry {
        switch output.content {
        case .data(let data): .init(sha256: Checksum.sha256(data), link: nil, layers: output.layers)
        case .link(let destination): .init(sha256: nil, link: destination, layers: output.layers)
        }
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func isEmptyFolder(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.allSatisfy { $0 == ".DS_Store" } ?? false
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
