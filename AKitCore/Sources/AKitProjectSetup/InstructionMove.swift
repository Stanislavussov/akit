import AKitBrain
import AKitFoundation
import AKitInstructions
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
        let notes = ["AKit then updates the core block in this Mac's global instruction files (Update Home Folder, only those blocks), and only after that takes the section out of \(file.lastPathComponent).",
                     "Other Macs: Brain → Sync there offers Update Home Folder, which brings it to their global files."]
            + core.notes.filter { !$0.hasPrefix("It reaches") && !$0.contains("loses the section now") }
        return GlobalPlan(core: core, notes: notes)
    }

    /// Carries out a move to global. `context` gives the home record and the targets; `hold` keeps
    /// the home folder's worktree sync away while it is written (the app's).
    public static func apply(_ plan: GlobalPlan, brain: Brain, context: SkillMove.Context,
                             trash: @escaping (URL) throws -> URL? = Trash.move,
                             hold: SkillMove.Hold = { _, work in try await work() }) async throws(Failure) {
        let env = context.env, home = env.homeDirectory
        let file = plan.removal.file
        if (try? Data(contentsOf: file)) != plan.removal.before {
            throw Failure(message: "\(FileWalk.tilde(file, home: home)) changed since the preview. Look at the preview again.")
        }
        do {
            try await LayerEditor.appendToAgentsSection(plan.core.piece, inLayer: "core", expected: plan.core.before, in: brain, env: env)
        } catch {
            throw Failure(message: error.message)
        }
        let unfinished = "The core layer has the section (committed in the brain), and \(FileWalk.tilde(file, home: home)) still has it."
        guard let fresh = Brain.load(from: brain.root) else {
            throw Failure(message: unfinished + " The brain can't be read again: Brain → core → Update Home Folder… finishes it, then Remove This Copy… takes the project's copy out.")
        }
        var answers = ProjectRecords.savedAnswers(id: context.homeID, in: context.store) ?? ProjectAnswers(targets: context.targets)
        answers.layers = ["core"]
        let homePlan = ProjectSetup.plan(project: home, id: context.homeID, answers: answers, brain: fresh, store: context.store, forHome: true,
                                         piAgentDirSetting: context.piAgentDirSetting, rememberPiAgentDir: context.rememberPiAgentDir, env: env)
        let blocks = Set(homePlan.changes.filter { $0.block && ($0.kind == .create || $0.kind == .update) }.map(\.path))
        guard homePlan.canApply, !blocks.isEmpty else {
            let why = homePlan.canApply ? "no global instruction file takes the core block on this Mac"
                : (homePlan.render.errors + homePlan.blockers).joined(separator: " ")
            throw Failure(message: unfinished + " The home folder was not updated: \(why). Brain → core → Update Home Folder… finishes it; then Remove This Copy… takes the project's copy out.")
        }
        let excluded = Set(homePlan.changes.map(\.path)).subtracting(blocks)
        do {
            _ = try await hold(homePlan.id) {
                try await ProjectSetup.apply(homePlan, excluding: excluded, deferring: excluded, brain: fresh, home: home, env: env, trash: trash)
            }
        } catch {
            throw Failure(message: unfinished + " Updating the home folder failed: \(error.localizedDescription) Brain → core → Update Home Folder… finishes it.")
        }
        do {
            try InstructionEdit.apply(plan.removal, env: env)
        } catch {
            throw Failure(message: "The core block has the section now, but \(FileWalk.tilde(file, home: home)) still has it: \(error.message) Remove This Copy… takes it out.")
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

    /// The file of the project that would get a section: AGENTS.md, else CLAUDE.md, else a new
    /// AGENTS.md; nil with the reason when AKit renders that file from the brain.
    public static func target(_ project: URL, rendered: Set<String>) -> Target {
        let fm = FileManager.default
        let file = ["AGENTS.md", "CLAUDE.md"].map { project.appending(path: $0) }.first { fm.fileExists(atPath: $0.path) }
            ?? project.appending(path: "AGENTS.md")
        if fm.fileExists(atPath: file.path), rendered.contains(InstructionEdit.realPath(file)) {
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
            let target = target(project, rendered: rendered)
            guard let url = target.file else { throw Failure(message: "\(FileWalk.tilde(project, home: home)): \(target.reason ?? "")") }
            if InstructionEdit.isSameFile(url, file) { throw Failure(message: "\(FileWalk.tilde(url, home: home)) is the global file itself (a link).") }
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
