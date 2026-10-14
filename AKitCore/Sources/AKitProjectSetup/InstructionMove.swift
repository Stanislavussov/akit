import AKitBrain
import AKitFoundation
import AKitHarnesses
import AKitInstructions
import AKitModel
import Foundation

/// Move to Global… and Move to Project… on the Instructions screen (docs/design/instructions.md,
/// step 5). A move is an import plus a removal, in the order that never leaves a session
/// without the section:
///
/// ```
/// to global    project file unchanged? → core layer (commit) → home folder: the core blocks only
///              → the project file loses it
/// to projects  every file unchanged? → each project's own file gets it (backup) → the global file loses it
/// ```
///
/// Global means the core layer (decided D14): its block reaches every harness's global file, on
/// every Mac after Sync. A project's own file is its AGENTS.md, else its CLAUDE.md, else a new
/// AGENTS.md. A project whose AGENTS.md AKit renders from the brain is not a target here: Import
/// to Brain… into its layer, then Set Up Project…, brings the section there.
public enum InstructionMove {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    // MARK: - To global

    public struct GlobalPlan: Sendable {
        /// Core's AGENTS.md text gets the section; the file loses it (its plan holds the diff).
        public let core: InstructionImport.Plan
        public var removal: InstructionEdit.Plan { core.removal! }
        public let notes: [String]
    }

    /// What moving a project's (or an above folder's) section into the core layer would change. Only reads.
    public static func toGlobal(_ section: InstructionSection, from file: URL, level: InstructionLevel, brain: Brain,
                                rendered: Set<String>, env: HarnessEnvironment) throws(Failure) -> GlobalPlan {
        if level == .global { throw Failure(message: "This file is global already.") }
        guard brain.layers.contains(where: { $0.name == "core" }) else { throw Failure(message: "The brain has no core layer.") }
        let core: InstructionImport.Plan
        do {
            core = try InstructionImport.plan(section, from: file, into: "core", removeHere: true, brain: brain, rendered: rendered, env: env)
        } catch {
            throw Failure(message: error.message)
        }
        // The import's notes speak of a later render; this move renders the home folder itself.
        let notes = ["After the commit, AKit shows the core block's changes in this Mac's global instruction files (Claude Code's and Pi's) for a second Apply; \(file.lastPathComponent) loses the section only when every harness that reads it here gets it from there.",
                     "Other Macs: Brain → Sync there offers Update Home Folder, which brings it to their global files."]
            + core.notes.filter { !$0.hasPrefix("It reaches") && !$0.contains("loses the section now") }
        return GlobalPlan(core: core, notes: notes)
    }

    /// Step 1 of a move to global: the file is checked, then the section joins core (a commit).
    public static func commit(_ plan: GlobalPlan, brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        let file = plan.removal.file
        if (try? Data(contentsOf: file)) != plan.removal.before {
            throw Failure(message: "\(FileWalk.tilde(file, home: env.homeDirectory)) changed since the preview. Look at the preview again.")
        }
        do {
            try await LayerEditor.appendToAgentsSection(plan.core.piece, inLayer: "core", expected: plan.core.before, in: brain, env: env)
        } catch {
            throw Failure(message: error.message)
        }
    }

    /// Step 2's preview, after the commit: the home folder's block changes that carry the
    /// section, as diffs, and the harnesses that read the section here but would not get it.
    public struct Blocks: Sendable {
        public struct Diff: Identifiable, Sendable {
            public let path: String
            public let lines: [TextDiff.Line]
            public var id: String { path }
        }

        public let diffs: [Diff]
        /// Harnesses that load the section in this session now and get no core block with it:
        /// the project's copy must stay for them.
        public let uncovered: [HarnessID]
        public let warnings: [String]
        let home: ProjectSetup.Plan?
        let paths: Set<String>
        let brain: Brain?
        /// The harnesses that load the section now (checked again after the write).
        let readers: [HarnessID]

        /// The project's copy may leave: every harness that reads it gets the core block.
        public var canRemove: Bool { uncovered.isEmpty && home != nil }

        /// After a failed step 2: nothing more to apply here.
        public static let done = Blocks(diffs: [], uncovered: [], warnings: [], home: nil, paths: [], brain: nil, readers: [])
    }

    /// Plans the home folder's core blocks with the committed brain. Only an added or updated
    /// block that carries the section counts; a take-out or any other pending home change is
    /// left for Update Home Folder. Only reads.
    public static func blocks(for plan: GlobalPlan, project: URL?, context: SkillMove.Context, brainRoot: URL) -> Blocks {
        let env = context.env, home = env.homeDirectory, file = plan.removal.file
        let readers = installed(env).filter { harness in
            InstructionScanner.view(harness: harness, project: project, env: env).loaded.contains { InstructionEdit.isSameFile($0.file, file) }
        }
        guard let fresh = Brain.load(from: brainRoot) else {
            return Blocks(diffs: [], uncovered: readers, warnings: ["The brain can't be read again."], home: nil, paths: [], brain: nil, readers: readers)
        }
        var answers = ProjectRecords.savedAnswers(id: context.homeID, in: context.store) ?? ProjectAnswers(targets: context.targets)
        answers.layers = ["core"]
        let homePlan = ProjectSetup.plan(project: home, id: context.homeID, answers: answers, brain: fresh, store: context.store, forHome: true,
                                         piAgentDirSetting: context.piAgentDirSetting, rememberPiAgentDir: context.rememberPiAgentDir, env: env)
        let carrying = homePlan.changes.filter { change in
            change.block && (change.blockAction == .add || change.blockAction == .update) && (change.newText?.contains(plan.core.piece) ?? false)
        }
        let paths = Set(carrying.map(\.path))
        let url: (String) -> URL = { $0.hasPrefix("/") ? URL(filePath: $0) : home.appending(path: $0) }
        // A reader is covered when one of its global instruction files gets the block.
        let uncovered = readers.filter { harness in
            let globals = InstructionScanner.view(harness: harness, project: nil, env: env).entries.map(\.file)
                + [HarnessCatalog.configRoot(of: harness, in: env)].compactMap { $0 }.flatMap { root in ["CLAUDE.md", "AGENTS.md"].map { root.appending(path: $0) } }
            return !carrying.contains { change in globals.contains { InstructionEdit.isSameFile($0, url(change.path)) || $0.standardizedFileURL == url(change.path).standardizedFileURL } }
        }
        var warnings = homePlan.render.warnings
        if !homePlan.canApply { warnings += (homePlan.render.errors + homePlan.blockers) }
        return Blocks(diffs: carrying.map { Blocks.Diff(path: FileWalk.tilde(url($0.path), home: home), lines: TextDiff.lines(from: $0.oldText ?? "", to: $0.newText ?? "")) },
                      uncovered: uncovered, warnings: warnings, home: homePlan.canApply && !paths.isEmpty ? homePlan : nil, paths: paths,
                      brain: fresh, readers: readers)
    }

    /// Step 2: the blocks are written (refused when a file changed since their preview); then,
    /// when `removeSource` and every reader still gets the section (checked on disk), the file
    /// loses it.
    public static func finish(_ plan: GlobalPlan, blocks: Blocks, removeSource: Bool, project: URL?, context: SkillMove.Context,
                              trash: @escaping (URL) throws -> URL? = Trash.move,
                              hold: SkillMove.Hold = { _, work in try await work() }) async throws(Failure) {
        let env = context.env, home = env.homeDirectory, file = plan.removal.file
        let shown = FileWalk.tilde(file, home: home)
        guard let homePlan = blocks.home, let brain = blocks.brain else {
            throw Failure(message: "No global instruction file on this Mac takes the core block now. Brain → core → Update Home Folder… shows why; \(shown) keeps the section.")
        }
        if let path = ProjectSetup.changedSincePreview(homePlan, paths: blocks.paths) {
            throw Failure(message: "~/\(path) changed since the preview. Look at the preview again.")
        }
        let excluded = Set(homePlan.changes.map(\.path)).subtracting(blocks.paths)
        do {
            _ = try await hold(homePlan.id) {
                try await ProjectSetup.apply(homePlan, excluding: excluded, deferring: excluded, brain: brain, home: home, env: env, trash: trash)
            }
        } catch {
            throw Failure(message: "The core layer has the section (committed), but the global files were not updated: \(error.localizedDescription) Brain → core → Update Home Folder… finishes it; \(shown) keeps the section.")
        }
        guard removeSource else { return }
        guard blocks.uncovered.isEmpty else {
            throw Failure(message: "The global files have the core block, but \(blocks.uncovered.map(\.displayName).joined(separator: ", ")) get no core block on this Mac, so \(shown) keeps the section.")
        }
        // Every harness that read the section here must still get it, from another file.
        let own = InstructionText.normalized(InstructionSection(heading: plan.core.heading, text: plan.core.piece, isAKitBlock: false, line: 1))
        let missing = blocks.readers.filter { harness in
            !InstructionScanner.view(harness: harness, project: project, env: env).loaded
                .filter { !InstructionEdit.isSameFile($0.file, file) }
                .contains { entry in InstructionText.units(entry.text).contains { InstructionText.normalized($0) == own } }
        }
        guard missing.isEmpty else {
            throw Failure(message: "The global files have the core block, but \(missing.map(\.displayName).joined(separator: ", ")) still don't get the section from it, so \(shown) keeps it. Remove This Copy… takes it out once they do.")
        }
        do {
            try InstructionEdit.apply(plan.removal, env: env)
        } catch {
            throw Failure(message: "The core block has the section now, but \(shown) still has it: \(error.message) Remove This Copy… takes it out.")
        }
    }

    // MARK: - To projects

    public struct Target: Identifiable, Hashable, Sendable {
        public let project: URL
        /// The file that gets the section; nil when the project can't take it here.
        public let file: URL?
        /// Why not, and what to do instead.
        public let reason: String?
        public var id: String { project.path }
    }

    public struct Write: Sendable {
        public let file: URL
        public let created: Bool
        public let diff: [TextDiff.Line]
        let before: Data?
        let after: Data
    }

    public struct ProjectPlan: Sendable {
        public let writes: [Write]
        /// The global file without the section.
        public let removal: InstructionEdit.Plan
        public let notes: [String]
    }

    /// The file of the project that gets a section of `source`: one that every harness reading
    /// `source` in a session there also reads (AGENTS.md first). When none of them reads a
    /// project file yet, a new CLAUDE.md or AGENTS.md that each of them would read
    /// (`wouldRead`); nil with the reason when no file fits, or when AKit renders it.
    public static func target(_ project: URL, source: URL, rendered: Set<String>, env: HarnessEnvironment) -> Target {
        var views: [HarnessID: InstructionView] = [:]
        let readers = installed(env).compactMap { harness -> (HarnessID, [URL])? in
            let view = InstructionScanner.view(harness: harness, project: project, env: env)
            guard view.loaded.contains(where: { InstructionEdit.isSameFile($0.file, source) }) else { return nil }
            views[harness] = view
            return (harness, view.loaded.filter { $0.level == .project }.map(\.file))
        }
        guard let first = readers.first else {
            return Target(project: project, file: nil, reason: "No harness reads \(source.lastPathComponent) in a session here.")
        }
        let common = first.1.filter { file in readers.allSatisfy { reader in reader.1.contains { InstructionEdit.isSameFile($0, file) } } }
        let names = readers.map(\.0)
        let file: URL
        if let found = common.first(where: { $0.lastPathComponent == "AGENTS.md" }) ?? common.first {
            file = found
        } else if readers.allSatisfy({ $0.1.isEmpty }),
                  let name = (names.contains(.claudeCode) ? ["CLAUDE.md", "AGENTS.md"] : ["AGENTS.md", "CLAUDE.md"])
                    .first(where: { name in names.allSatisfy { harness in views[harness].map { wouldRead(name, harness, $0) } ?? false } }) {
            file = project.appending(path: name)
        } else {
            return Target(project: project, file: nil,
                          reason: "\(names.map(\.displayName).joined(separator: ", ")) read no common instruction file here. Add the section to each harness's file by hand.")
        }
        if rendered.contains(InstructionEdit.realPath(file)) {
            return Target(project: project, file: nil,
                          reason: "AKit renders this project's \(file.lastPathComponent) from the brain. Import to Brain… into one of its layers, then run Set Up Project… there.")
        }
        return Target(project: project, file: file, reason: nil)
    }

    /// What moving a global section into these projects would change. Only reads.
    public static func toProjects(_ section: InstructionSection, from file: URL, level: InstructionLevel, projects: [URL],
                                  rendered: Set<String>, env: HarnessEnvironment) throws(Failure) -> ProjectPlan {
        let home = env.homeDirectory
        guard level != .project else { throw Failure(message: "This is a project's file already.") }
        guard !projects.isEmpty else { throw Failure(message: "Pick at least one project.") }
        let removal: InstructionEdit.Plan
        do {
            removal = try InstructionEdit.removing(section, from: file, rendered: rendered, env: env)
        } catch {
            throw Failure(message: error.message)
        }
        let piece = section.text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let own = InstructionText.normalized(section)
        var writes: [Write] = []
        var notes: [String] = []
        for project in projects {
            let target = target(project, source: file, rendered: rendered, env: env)
            guard let url = target.file else { throw Failure(message: "\(FileWalk.tilde(project, home: home)): \(target.reason ?? "")") }
            if InstructionEdit.isSameFile(url, file) { throw Failure(message: "\(FileWalk.tilde(url, home: home)) is the global file itself (a link).") }
            // Two projects that share one file through links: it is written once.
            if writes.contains(where: { InstructionEdit.isSameFile($0.file, url) }) { continue }
            let before = try? Data(contentsOf: url)
            if before != nil, (before.flatMap { String(data: $0, encoding: .utf8) }) == nil {
                throw Failure(message: "\(FileWalk.tilde(url, home: home)) can't be read as text.")
            }
            let text = before.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if InstructionText.units(text).contains(where: { InstructionText.normalized($0) == own }) {
                notes.append("\(FileWalk.tilde(url, home: home)) has the section already: it stays as it is.")
                continue
            }
            let after = appended(piece, to: text)
            writes.append(Write(file: url, created: before == nil, diff: TextDiff.lines(from: text, to: after), before: before, after: Data(after.utf8)))
            if let tracked = LocalOnly.tracked([url.lastPathComponent], in: project, env: env), !tracked.isEmpty {
                notes.append("git tracks \(FileWalk.tilde(url, home: home)): the change shows in git status there. AKit doesn't commit it.")
            }
        }
        notes += removal.notes
        notes.append("Projects not picked here lose the section: \(FileWalk.tilde(file, home: home)) no longer has it for them.")
        return ProjectPlan(writes: writes, removal: removal, notes: notes)
    }

    /// The projects' files first (each backed up; refused when changed since the preview), then
    /// the global file. Nothing is written when any file changed.
    public static func apply(_ plan: ProjectPlan, env: HarnessEnvironment) throws(Failure) {
        let home = env.homeDirectory
        for write in plan.writes where (try? Data(contentsOf: write.file)) != write.before {
            throw Failure(message: "\(FileWalk.tilde(write.file, home: home)) changed since the preview. Look at the preview again.")
        }
        if (try? Data(contentsOf: plan.removal.file)) != plan.removal.before {
            throw Failure(message: "\(FileWalk.tilde(plan.removal.file, home: home)) changed since the preview. Look at the preview again.")
        }
        var done: [String] = []
        for write in plan.writes {
            do {
                try FileManager.default.createDirectory(at: write.file.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try SettingsFile.write(write.after, to: write.file, expecting: write.before, home: home)
                done.append(FileWalk.tilde(write.file, home: home))
            } catch {
                let partial = done.isEmpty ? "" : " Already written: \(done.joined(separator: ", ")); the global file still has the section."
                throw Failure(message: "\(FileWalk.tilde(write.file, home: home)): \(error.localizedDescription)\(partial)")
            }
        }
        do {
            try InstructionEdit.apply(plan.removal, env: env)
        } catch {
            throw Failure(message: "The projects have the section now, but \(FileWalk.tilde(plan.removal.file, home: home)) still has it: \(error.message) Remove This Copy… takes it out.")
        }
    }

    /// Whether the harness would read a new project file of this name, given what it reads now
    /// (no project file yet): the rules of `InstructionScanner`.
    static func wouldRead(_ name: String, _ harness: HarnessID, _ view: InstructionView) -> Bool {
        let above = view.loaded.filter { if case .above = $0.level { true } else { false } }.map(\.file.lastPathComponent)
        switch (harness, name) {
        case (.claudeCode, "CLAUDE.md"): return true
        // Claude Code reads AGENTS.md only when no CLAUDE.md is in the project or above it.
        case (.claudeCode, "AGENTS.md"): return !above.contains { $0.hasPrefix("CLAUDE") }
        case (.pi, _): return true
        case (.codex, "AGENTS.md"): return true
        case (.openCode, "AGENTS.md"): return true
        // OpenCode reads CLAUDE.md only when no AGENTS.md is in the tree.
        case (.openCode, "CLAUDE.md"): return !above.contains("AGENTS.md")
        default: return false
        }
    }

    /// The harnesses installed on this Mac that the scanner knows.
    static func installed(_ env: HarnessEnvironment) -> [HarnessID] {
        let ids = Set(HarnessCatalog.detectAll(in: env).map(\.id))
        return InstructionScanner.harnesses.filter(ids.contains)
    }

    /// The text with the piece at its end: one blank line before it, the file's line ending, a
    /// final newline; the bytes before stay.
    static func appended(_ piece: String, to text: String) -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = InstructionText.lines(text)
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.removeLast() }
        if let last = lines.last, last.hasSuffix("\r") { lines[lines.count - 1] = String(last.dropLast()) }
        let kept = lines.joined(separator: "\n")
        let added = piece.replacingOccurrences(of: "\n", with: newline)
        return (kept.isEmpty ? "" : kept + newline + newline) + added + newline
    }
}
