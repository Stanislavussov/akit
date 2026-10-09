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
    /// other file, and each merged JSON file AKit created. Sorted; unsafe paths left out
    /// (`skipped(of:)`).
    static func candidates(of lock: ProjectRecords.Lock) -> [String] { allCandidates(of: lock).filter(isSafe) }

    /// Paths of the lock that can't be a line of the block (a newline, `..`): git shows them.
    static func skipped(of lock: ProjectRecords.Lock) -> [String] { allCandidates(of: lock).filter { !isSafe($0) } }

    private static func allCandidates(of lock: ProjectRecords.Lock) -> [String] {
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

    /// A unit names a path inside the checkout: not empty, relative, no empty, `.` or `..`
    /// component, no line break. Units come from the lock and from the exclude file, which
    /// the user may edit; a link is made or removed only at a safe one.
    static func isSafe(_ unit: String) -> Bool {
        guard !unit.isEmpty, !unit.hasPrefix("/"), !unit.contains(where: { $0.isNewline || $0 == "\0" }) else { return false }
        return unit.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
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

    /// The unit of a line of AKit's block; nil for anything else, and for a path that is not
    /// safe (`isSafe`): the block may have been edited by hand.
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
        return isSafe(unit) ? unit : nil
    }

    // MARK: - The block

    /// The exclude file read as bytes, split on "\n" (a line keeps its "\r", and need not be
    /// UTF-8); a link is followed. No file: no lines.
    enum Contents {
        case lines([Data])
        /// The file is there but can't be read (or is a broken link): AKit leaves it alone.
        case unreadable(String)
    }

    static func contents(of file: URL) -> Contents {
        var info = stat()
        if lstat(file.path, &info) != 0, errno == ENOENT { return .lines([]) }
        do {
            let data = try Data(contentsOf: file)
            return .lines(data.isEmpty ? [] : data.split(separator: 0x0A, omittingEmptySubsequences: false))
        } catch {
            return .unreadable("Couldn't read \(file.path) (\(error.localizedDescription)); AKit left it alone.")
        }
    }

    /// A line as text without a trailing "\r"; nil when it is not UTF-8.
    private static func text(_ line: Data) -> String? {
        String(data: line.last == 0x0D ? line.dropLast() : line, encoding: .utf8)
    }

    /// The units in AKit's block of an exclude file; nil when there is no block, its markers
    /// are broken, or the file can't be read.
    public static func blockUnits(in file: URL) -> [String]? {
        guard case .lines(let lines) = contents(of: file), case .found(let range)? = block(in: lines) else { return nil }
        return lines[range].dropFirst().dropLast().compactMap { text($0).flatMap(unit(fromLine:)) }
    }

    /// The file has AKit's markers, but not one start before one end: AKit leaves it alone.
    static func blockIsBroken(in file: URL) -> Bool {
        guard case .lines(let lines) = contents(of: file), case .broken? = block(in: lines) else { return false }
        return true
    }

    /// Why AKit can't change its block in the exclude file (a broken block, a file it can't
    /// read), with what to do; nil when it can.
    public static func problem(in file: URL) -> String? {
        switch contents(of: file) {
        case .unreadable(let problem):
            return problem
        case .lines(let lines):
            guard case .broken? = block(in: lines) else { return nil }
            return "\(file.path) has a broken AKit block (a marker is missing or doubled); AKit left it alone. Delete the lines from \(startMarker) to \(endMarker) by hand, then apply again."
        }
    }

    enum Block { case found(ClosedRange<Int>), broken }

    /// Where AKit's block is (from its start marker to its end marker); nil when there is none.
    /// A marker line may end in "\r".
    static func block(in lines: [Data]) -> Block? {
        let start = Data(startMarker.utf8), end = Data(endMarker.utf8)
        func strip(_ line: Data) -> Data { line.last == 0x0D ? line.dropLast() : line }
        let starts = lines.indices.filter { strip(lines[$0]) == start }
        let ends = lines.indices.filter { strip(lines[$0]) == end }
        if starts.isEmpty && ends.isEmpty { return nil }
        guard starts.count == 1, ends.count == 1, starts[0] < ends[0] else { return .broken }
        return .found(starts[0]...ends[0])
    }

    /// The file's bytes with AKit's block holding `units` (appended when missing), or without
    /// the block when `units` is empty; every other line stays byte for byte. nil when the
    /// markers are broken.
    static func updated(_ data: Data, units: [String]) -> Data? {
        var lines = data.isEmpty ? [] : data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let block = ([startMarker] + units.filter(isSafe).map(line(for:)) + [endMarker]).map { Data($0.utf8) }
        switch self.block(in: lines) {
        case .broken?:
            return nil
        case .found(let range)?:
            if units.isEmpty { lines.removeSubrange(range) } else { lines.replaceSubrange(range, with: block) }
            return Data(lines.joined(separator: [0x0A]))
        case nil:
            guard !units.isEmpty else { return data }
            var new = data
            if !new.isEmpty, new.last != 0x0A { new.append(0x0A) }
            new.append(Data(block.joined(separator: [0x0A])))
            new.append(0x0A)
            return new
        }
    }

    /// Puts `units` into AKit's block of the exclude file (takes the block out when empty).
    /// A link is written through to the file it points to. Returns a problem to report, nil
    /// when done.
    static func write(units: [String], to file: URL) -> String? {
        let old: Data
        switch contents(of: file) {
        case .unreadable(let problem): return problem
        case .lines(let lines): old = Data(lines.joined(separator: [0x0A]))
        }
        guard let new = updated(old, units: units) else { return problem(in: file) }
        guard new != old else { return nil }
        var target = file
        var info = stat()
        if lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
            guard let resolved = FileWalk.realPath(file) else { return "Couldn't follow the link \(file.path); AKit left it alone." }
            target = URL(filePath: resolved)
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try new.write(to: target, options: .atomic)
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
        // A broken block or a file AKit can't read: Apply leaves it alone, so say so now.
        if let problem = problem(in: file) {
            plan.notes.append((plan.localOnly ? "Local only: " : "") + problem)
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
        let planned = ProjectSetup.lock(after: plan, excluding: [], accepting: [])
        let candidates = candidates(of: planned)
        let skipped = skipped(of: planned)
        if !skipped.isEmpty {
            plan.notes.append("Local only: AKit can't put these paths in its block (a line break or `..` in the path), so git shows them: \(skipped.map(\.debugDescription).joined(separator: ", ")).")
        }
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

    /// Before Apply writes a file: in a local-only project the block also gets the units the
    /// preview planned, so no file AKit writes shows in git status, even when git fails after
    /// Apply. `afterApply` shrinks the block to what was written. Returns the block's units
    /// before (nil: no block).
    static func beforeApply(_ plan: ProjectSetup.Plan) -> [String]? {
        guard let file = excludeFile(of: plan.project) else { return nil }
        let previous = blockUnits(in: file)
        if plan.localOnly, let planned = plan.exclude?.units {
            let union = Set(previous ?? []).union(planned)
            // A problem (broken block, unreadable file) is reported by `afterApply`.
            if union != Set(previous ?? []) { _ = write(units: union.sorted(), to: file) }
        }
        return previous
    }

    /// After Apply saved `lock`: the block holds the untracked units in a local-only project, and
    /// comes out otherwise. `previous`: the block's units before Apply (`beforeApply`). Returns
    /// notes for the outcome. The worktrees follow: links of new units are made, those of
    /// dropped units removed.
    static func afterApply(_ plan: ProjectSetup.Plan, lock: ProjectRecords.Lock, previous: [String]?, env: HarnessEnvironment) -> [String] {
        guard let file = excludeFile(of: plan.project) else { return [] }
        let previous = previous ?? []
        var units: [String] = []
        if plan.localOnly {
            let candidates = candidates(of: lock)
            guard let tracked = tracked(candidates, in: plan.project, env: env) else {
                return ["git didn't run, so AKit couldn't check which of its files git tracks; its block in \(shownPath(file, in: plan.project)) still holds every file AKit planned. Apply again to update it."]
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
        guard let file = excludeFile(of: project) else { return nil }
        if let problem = problem(in: file) { return problem }
        guard let previous = blockUnits(in: file) else { return nil }
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
