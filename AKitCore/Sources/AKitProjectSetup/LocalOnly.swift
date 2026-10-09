import AKitBrain
import AKitFoundation
import Foundation

/// Local-only projects (layers.md, "Local-only files and git worktrees"): the files AKit wrote
/// stay out of git through one marked block in `<git common dir>/info/exclude`, which every
/// worktree of the repository shares and git never commits. A line per unit AKit wrote that
/// git doesn't track: `/.agents/skills/<name>` (no trailing slash, so it also matches a link in
/// a worktree), `/.claude/skills`, and the files AKit created. Never a `.gitignore`: Pi reads
/// ignore files inside `.agents/skills` and would hide the skills.
public enum LocalOnly {
    static let startMarker = "# >>> akit (local-only files of this project; managed by AKit)"
    static let endMarker = "# <<< akit"

    /// What local only does to a project's exclude file, shown before Apply.
    public struct Exclude: Sendable, Hashable {
        /// `<git common dir>/info/exclude`.
        public let file: URL
        /// The units in AKit's block now (`.agents/skills/tdd`); nil when the file has no block.
        public let current: [String]?
        /// The units after Apply; empty: the block comes out (or none is written).
        public let units: [String]
        /// The block's lines after Apply (`/.agents/skills/tdd`).
        public var lines: [String] { units.map(line(for:)) }
    }

    // MARK: - Units

    /// The units a lock says AKit wrote: each skill folder, the `.claude/skills` link, every
    /// other file, and each merged JSON file AKit created. Sorted.
    static func candidates(of lock: ProjectRecords.Lock) -> [String] {
        let prefix = ProjectBundle.skillsFolder + "/"
        var units: Set<String> = []
        for path in lock.files.keys {
            if path.hasPrefix(prefix) {
                if let name = path.dropFirst(prefix.count).split(separator: "/").first { units.insert(prefix + name) }
            } else {
                units.insert(path)
            }
        }
        for (path, record) in lock.json ?? [:] where record.created { units.insert(path) }
        return units.sorted()
    }

    /// The paths git tracks a file in (or under), from one `git ls-files`; nil when git can't run.
    static func tracked(_ paths: [String], in folder: URL, env: HarnessEnvironment) -> Set<String>? {
        guard !paths.isEmpty else { return [] }
        let git = env.findExecutable("git") ?? URL(filePath: "/usr/bin/git")
        // Pathspecs read literally: a path with `*` or `:` names only itself.
        guard let result = ProcessRunner.runAndWait(git, arguments: ["-C", folder.path, "ls-files", "-z", "--"] + paths.map { ":(literal)" + $0 },
                                                    environment: env.gitVariables, timeout: 15),
              result.succeeded else { return nil }
        let files = result.output.split(separator: "\0").map(String.init)
        return Set(paths.filter { path in files.contains { $0 == path || $0.hasPrefix(path + "/") } })
    }

    /// The units AKit's block should hold for this lock: what AKit wrote that git doesn't
    /// track. nil when git didn't run. For checks (`akit doctor`).
    public static func expectedUnits(of project: URL, lock: ProjectRecords.Lock, env: HarnessEnvironment) -> [String]? {
        let candidates = candidates(of: lock)
        return tracked(candidates, in: project, env: env).map { tracked in candidates.filter { !tracked.contains($0) } }
    }

    // MARK: - Lines

    /// A unit as an exclude pattern, anchored at the top: `/` + the path, with what gitignore
    /// reads as a wildcard escaped, and trailing spaces kept.
    static func line(for unit: String) -> String {
        var text = "/" + unit.map { "*?[\\".contains($0) ? "\\\($0)" : String($0) }.joined()
        var trailing = 0
        while text.hasSuffix(" ") {
            text.removeLast()
            trailing += 1
        }
        return text + String(repeating: "\\ ", count: trailing)
    }

    /// The unit of a line of AKit's block; nil for anything else.
    static func unit(fromLine line: String) -> String? {
        guard line.hasPrefix("/"), line.count > 1 else { return nil }
        var unit = ""
        var escaped = false
        for character in line.dropFirst() {
            if escaped || character != "\\" {
                unit.append(character)
                escaped = false
            } else {
                escaped = true
            }
        }
        return unit
    }

    // MARK: - The block

    /// The units in AKit's block of an exclude file; nil when there is no block or its markers
    /// are broken.
    public static func blockUnits(in file: URL) -> [String]? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard case .found(let range)? = block(in: lines) else { return nil }
        return lines[range].dropFirst().dropLast().compactMap(unit(fromLine:))
    }

    /// The file has AKit's markers, but not one start before one end: AKit leaves it alone.
    static func blockIsBroken(in file: URL) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8), case .broken? = block(in: text.components(separatedBy: "\n")) else {
            return false
        }
        return true
    }

    enum Block { case found(ClosedRange<Int>), broken }

    /// Where AKit's block is (from its start marker to its end marker); nil when there is none.
    static func block(in lines: [String]) -> Block? {
        let starts = lines.indices.filter { lines[$0] == startMarker }
        let ends = lines.indices.filter { lines[$0] == endMarker }
        if starts.isEmpty && ends.isEmpty { return nil }
        guard starts.count == 1, ends.count == 1, starts[0] < ends[0] else { return .broken }
        return .found(starts[0]...ends[0])
    }

    /// The text with AKit's block holding `units` (appended when missing), or without the block
    /// when `units` is empty; every other line stays as it was. nil when the markers are broken.
    static func updated(_ text: String, units: [String]) -> String? {
        var lines = text.components(separatedBy: "\n")
        let block = [startMarker] + units.map(line(for:)) + [endMarker]
        switch self.block(in: lines) {
        case .broken?:
            return nil
        case .found(let range)?:
            if units.isEmpty { lines.removeSubrange(range) } else { lines.replaceSubrange(range, with: block) }
            return lines.joined(separator: "\n")
        case nil:
            guard !units.isEmpty else { return text }
            let joined = block.joined(separator: "\n") + "\n"
            return text.isEmpty ? joined : text + (text.hasSuffix("\n") ? "" : "\n") + joined
        }
    }

    /// Puts `units` into AKit's block of the exclude file (takes the block out when empty).
    /// Returns a problem to report, nil when done.
    static func write(units: [String], to file: URL) -> String? {
        let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard let new = updated(old, units: units) else {
            return "\(file.path) has a broken AKit block (a marker is missing or doubled); AKit left it alone. Remove the lines between \(startMarker) and \(endMarker) by hand."
        }
        guard new != old else { return nil }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(new.utf8).write(to: file, options: .atomic)
            return nil
        } catch {
            return "Couldn't update \(file.path): \(error.localizedDescription)"
        }
    }

    // MARK: - Plan, Apply, Forget

    /// The exclude file of a project's main checkout; nil when the folder is not the top of a
    /// git repository or is a linked worktree.
    static func excludeFile(of project: URL) -> URL? {
        guard let checkout = GitCheckout.at(project), !checkout.isLinkedWorktree else { return nil }
        return checkout.excludeFile
    }

    /// Fills in what local only will do: `plan.exclude`, a note listing the lines, and a
    /// warning for each tracked file AKit merges keys into. Only reads (one `git ls-files`).
    static func preview(_ plan: inout ProjectSetup.Plan, env: HarnessEnvironment) {
        guard let file = excludeFile(of: plan.project) else {
            if plan.localOnly, GitCheckout.at(plan.project) == nil, let outer = GitCheckout.containing(plan.project) {
                plan.notes.append("Local only: the project folder is inside the git repository at \(outer.folder.path); AKit hides its files only at the top of a repository, so they show in git status there.")
            }
            return
        }
        let current = blockUnits(in: file)
        let shown = shownPath(file, in: plan.project)
        guard plan.localOnly else {
            if current != nil {
                plan.exclude = Exclude(file: file, current: current, units: [])
                plan.notes.append("Not local only: AKit's block comes out of \(shown); its files show in git status.")
            }
            return
        }
        let candidates = candidates(of: ProjectSetup.lock(after: plan, excluding: [], accepting: []))
        let merged = plan.render.outputs.filter(\.mergesJSON).map(\.path)
        guard let tracked = tracked(Array(Set(candidates + merged)).sorted(), in: plan.project, env: env) else {
            plan.notes.append("Local only: git didn't run, so AKit can't tell which files git tracks; \(shown) is left as it is.")
            return
        }
        let units = candidates.filter { !tracked.contains($0) }
        plan.exclude = Exclude(file: file, current: current, units: units)
        if !units.isEmpty {
            plan.notes.append("Local only: AKit's block in \(shown) keeps these out of git: \(units.map(line(for:)).joined(separator: ", ")).")
            let folder = plan.project.standardizedFileURL.path
            let trees = GitCheckout.at(plan.project).map {
                ProjectWorktrees.linkedWorktrees(of: $0, main: [folder, ProjectWorktrees.realPath(folder)], env: env)
            } ?? []
            if !trees.isEmpty {
                plan.notes.append("Apply also links them into the repository's other worktrees: \(trees.map(\.folder.path).joined(separator: ", ")).")
            }
        } else if current != nil {
            plan.notes.append("Local only: nothing of AKit's left to hide; its block comes out of \(shown).")
        }
        let warnings = merged.filter(tracked.contains).map { "\($0) is tracked in git: AKit's keys show in git diff." }
        if !warnings.isEmpty {
            plan.render = RenderResult(layers: plan.render.layers, outputs: plan.render.outputs, errors: plan.render.errors,
                                       warnings: plan.render.warnings + warnings, skills: plan.render.skills)
        }
    }

    /// After Apply saved `lock`: the block holds the untracked units in a local-only project, and
    /// comes out otherwise. Returns notes for the outcome.
    /// The worktrees follow: links of new units are made, those of dropped units removed.
    static func afterApply(_ plan: ProjectSetup.Plan, lock: ProjectRecords.Lock, env: HarnessEnvironment) -> [String] {
        guard let file = excludeFile(of: plan.project) else { return [] }
        let previous = blockUnits(in: file) ?? []
        var units: [String] = []
        if plan.localOnly {
            let candidates = candidates(of: lock)
            guard let tracked = tracked(candidates, in: plan.project, env: env) else {
                return ["git didn't run, so AKit's files are not hidden from git (\(shownPath(file, in: plan.project)))."]
            }
            units = candidates.filter { !tracked.contains($0) }
        } else if blockUnits(in: file) == nil {
            return []
        }
        if let problem = write(units: units, to: file) { return [problem] }
        guard !(previous.isEmpty && units.isEmpty) else { return [] }
        return notes(ProjectWorktrees.sync(plan.project, dropped: previous.filter { !units.contains($0) }, env: env))
    }

    /// Forget: AKit's block comes out of the project's exclude file, and its links out of the
    /// worktrees. Returns a problem, if any.
    static func takeOut(of project: URL, env: HarnessEnvironment) -> String? {
        guard let file = excludeFile(of: project), let previous = blockUnits(in: file) else { return nil }
        if let problem = write(units: [], to: file) { return problem }
        let problems = ProjectWorktrees.sync(project, dropped: previous, env: env).problems
        return problems.isEmpty ? nil : problems.joined(separator: " ")
    }

    /// What a worktree sync did, for the outcome.
    static func notes(_ outcome: ProjectWorktrees.Outcome) -> [String] {
        var notes: [String] = []
        if !outcome.created.isEmpty { notes.append("Linked into worktrees: \(outcome.created.joined(separator: ", ")).") }
        if !outcome.removed.isEmpty { notes.append("Links removed from worktrees: \(outcome.removed.joined(separator: ", ")).") }
        if !outcome.conflicts.isEmpty {
            notes.append("Left alone in worktrees (something else is there): \(outcome.conflicts.joined(separator: ", ")).")
        }
        return notes + outcome.problems
    }

    /// `.git/info/exclude` inside the project, else the full path.
    static func shownPath(_ file: URL, in project: URL) -> String {
        let base = project.standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}
