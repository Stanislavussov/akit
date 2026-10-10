import AKitBrain
import AKitFoundation
import AKitSkills
import Foundation

/// Move to Project (layers.md, "Move a skill to a project"): a global skill that only some
/// projects need moves into them, so its description stops being sent in every other session.
/// The skill reaches the projects through the brain: it is copied into the brain's library (no
/// layer), listed in each project's answers and rendered there by Set Up Project's Apply. A
/// local-only project's exclude block and worktree links then cover it like any skill AKit
/// renders, also in worktrees made later. Only then does it leave the core layer and the home
/// folder, so it is never missing anywhere in between:
///
/// ```
/// brain import (library only) → each project's Apply → core's layer.yaml → home Apply → Trash
/// ```
///
/// A plain folder moved into `<project>/.agents/skills` would be the project's own skill: no
/// exclude line, no worktree links. Pi can't hide a global skill in one project, so for Pi this
/// is the only per-project control.
public enum SkillMove {
    /// One project to move the skill into.
    public struct Target: Hashable, Sendable {
        /// The brain's project id.
        public let id: String
        /// The project's folder on this Mac (a worktree stands for its main checkout); nil when
        /// it is not here: only its saved answers get the skill.
        public let folder: URL?
        /// Keep AKit's files out of git; nil: the project's saved choice, and local only for a
        /// project that is not set up yet.
        public var localOnly: Bool?
        /// The project has its own copy of the skill: keep it and write nothing there.
        public var keepOwn: Bool

        public init(id: String, folder: URL?, localOnly: Bool? = nil, keepOwn: Bool = false) {
            self.id = id
            self.folder = folder
            self.localOnly = localOnly
            self.keepOwn = keepOwn
        }
    }

    /// What a plan reads besides the brain.
    public struct Context: Sendable {
        public var env: HarnessEnvironment
        public var store: ProjectStore
        /// This Mac's home record (`ProjectRecords.homeID`).
        public var homeID: String
        /// The skills the harnesses see (`SkillScanner.scan`); the global ones with the name are used.
        public var installed: [Skill]
        /// Render targets of a project that isn't set up yet: the installed harnesses.
        public var targets: [String]
        /// Projects on this Mac by id; those not moved to are checked for mentions of the skill.
        public var projectFolders: [String: URL]
        public var piAgentDirSetting: String?
        public var rememberPiAgentDir: Bool

        public init(env: HarnessEnvironment, store: ProjectStore, homeID: String, installed: [Skill], targets: [String],
                    projectFolders: [String: URL] = [:], piAgentDirSetting: String? = nil, rememberPiAgentDir: Bool = false) {
            self.env = env
            self.store = store
            self.homeID = homeID
            self.installed = installed
            self.targets = targets
            self.projectFolders = projectFolders
            self.piAgentDirSetting = piAgentDirSetting
            self.rememberPiAgentDir = rememberPiAgentDir
        }
    }

    /// A file of the skill that differs from the brain's: edited by hand in the home folder, or a
    /// global copy that is not the brain's. For Show Edits.
    public struct Edit: Hashable, Sendable {
        /// Where the copy is, e.g. `~/.agents/skills/deploy/SKILL.md`.
        public let path: String
        public let brainText: String?
        public let copyText: String?
    }

    /// What happens in one project.
    public struct Part: Identifiable, Sendable {
        public enum State: Hashable, Sendable {
            /// Apply writes the skill there (or only saves the answers when it is already there).
            case add
            /// The project keeps its own copy; nothing is written.
            case keepOwn
            /// Not on this Mac, but it has a record: only its answers get the skill, so Set Up
            /// Project on the Mac that has it renders the skill there.
            case answersOnly
            /// Something stops it; the whole move waits.
            case blocked(String)
        }

        public var id: String { target.id }
        public let target: Target
        public let state: State
        /// The project's main checkout.
        public let folder: URL?
        public let plan: ProjectSetup.Plan?
        /// The paths of `plan` that Apply writes: the skill's files, and the `.claude/skills` link when new.
        public let paths: Set<String>
        /// Every other change of `plan`: left for Set Up Project.
        public let excluded: Set<String>
        /// The project had no answers: this is its first Set Up, with only this skill.
        public let isNew: Bool
        /// AKit's files stay out of git after Apply.
        public let localOnly: Bool
        /// The project's saved choice before; nil: none (the Mac's role decided).
        public let savedLocalOnly: Bool?
        /// Its other git worktrees, which get a link to the skill (local only).
        public let worktrees: [URL]
        /// The project's own copy of the skill (for Compare), and whether git tracks it.
        public let ownFolder: URL?
        public let ownTracked: Bool
        /// The answers saved for `.answersOnly`.
        public var answers: ProjectAnswers? = nil

        /// The changes Apply makes for the skill.
        public var changes: [ProjectSetup.Change] { plan?.changes.filter { paths.contains($0.path) } ?? [] }
        /// Apply writes nothing but the answers: the project has the skill already.
        public var isPresent: Bool { state == .add && !changes.contains { $0.kind != .same } }
    }

    /// `layers/core/layer.yaml` before and after the skill's entry is taken out.
    public struct LayerEdit: Hashable, Sendable {
        public let before: String
        public let after: String
    }

    public struct Plan: Sendable {
        /// The skill's folder name, as the brain and layers call it.
        public let name: String
        public let mode: LayerSkill.Mode
        /// Copy to the projects only: the core layer and the home folder keep it.
        public let keepGlobal: Bool
        /// The global copy the harnesses read now; nil when there is none (only core lists it).
        public let source: Skill?
        /// The home folder's copy is AKit's render of the core layer (in the home record's lock).
        public let sourceRendered: Bool
        /// Copies the skill into the brain's library first (no layer); nil: the brain has it.
        public let brainImport: BrainImport.Plan?
        /// The global copy's files when planned, to stop when they change before Apply.
        let sourceDigest: String?
        public let parts: [Part]
        /// The core layer without the skill; nil when core doesn't list it or `keepGlobal`.
        public let coreEdit: LayerEdit?
        /// The home folder's Apply with core without the skill; nil when the home record has no copy.
        public let home: ProjectSetup.Plan?
        /// The paths of `home` Apply changes (the skill's files); the rest stay for Update Home Folder.
        public let homePaths: Set<String>
        public let homeExcluded: Set<String>
        /// A global copy that is not AKit's render (a folder, or a link: only the link goes): to the Trash.
        public let trashSource: [URL]
        /// Other global copies with the same folder name in other skill folders
        /// (`~/.pi/agent/skills/<name>`, a separate `~/.claude/skills/<name>`), each the same as the
        /// brain's: each to the Trash.
        public let extraCopies: [Skill]
        /// What each item that goes to the Trash held when planned (path → digest), checked again
        /// before anything is written.
        let trashDigests: [String: String]
        /// Where project answers and locks are kept (the brain, or a work Mac's local store).
        let store: ProjectStore
        /// Files that differ from the brain's: the move waits until they are the same.
        public let edits: [Edit]
        public let blockers: [String]
        public let warnings: [String]
        public let notes: [String]

        public var canApply: Bool {
            blockers.isEmpty && !parts.contains { if case .blocked = $0.state { true } else { false } }
                && parts.contains { $0.state == .add || $0.state == .keepOwn || $0.state == .answersOnly }
        }
        /// Projects the skill is written into.
        public var adding: [Part] { parts.filter { $0.state == .add } }
        /// Projects on other Macs whose answers get the skill.
        public var answersOnly: [Part] { parts.filter { $0.state == .answersOnly } }
    }

    public struct Outcome: Sendable {
        public var imported = false
        /// Each project's Apply, in order.
        public var projects: [(id: String, outcome: ProjectSetup.Outcome)] = []
        /// Projects on other Macs whose answers got the skill.
        public var answersSaved: [String] = []
        public var coreChanged = false
        public var home: ProjectSetup.Outcome?
        /// Copies moved to the Trash.
        public var trashed: [String] = []
        public var notes: [String] = []
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        /// What was done before it stopped.
        public let outcome: Outcome
        public var errorDescription: String? { message }
    }

    /// Runs one project's Apply; the app holds the project's worktree sync meanwhile.
    public typealias Hold = (_ id: String, _ work: () async throws -> ProjectSetup.Outcome) async throws -> ProjectSetup.Outcome

    // MARK: - Plan

    /// The skill's mode where it is now: its entry in the core layer, else the global copy's
    /// header (`disable-model-invocation: true` is manual), else auto.
    public static func currentMode(_ name: String, brain: Brain, installed: [Skill]) -> LayerSkill.Mode {
        if let entry = brain.layers.first(where: { $0.name == "core" })?.skills.first(where: { $0.name == name }) { return entry.mode }
        return globalCopies(name, installed: installed).first?.disablesModelInvocation == true ? .manual : .auto
    }

    /// The global skills named `name` (by folder, else by their header's name) that AKit may move.
    static func globalCopies(_ name: String, installed: [Skill]) -> [Skill] {
        installed.filter { $0.scope == .global && !$0.isReadOnly && !$0.isSingleFile && folderName($0) == name }
            + installed.filter { $0.scope == .global && !$0.isReadOnly && !$0.isSingleFile && folderName($0) != name && $0.name == name }
    }

    static func folderName(_ skill: Skill) -> String { skill.folder.lastPathComponent }

    /// What moving `name` into `targets` would do. Only reads (`git ls-files`, `git worktree list`).
    public static func plan(name requested: String, targets: [Target], mode: LayerSkill.Mode, keepGlobal: Bool = false,
                            brain: Brain, context: Context) -> Plan {
        let env = context.env, home = env.homeDirectory
        let skillPrefix = { (name: String) in "\(ProjectBundle.skillsFolder)/\(name)/" }
        var blockers: [String] = [], warnings: [String] = [], notes: [String] = [], edits: [Edit] = []

        // Where the skill is: a global copy the harnesses read, and the brain. A copy found by its
        // header's name in a folder of another name is a different skill: never moved or trashed.
        let found = globalCopies(requested, installed: context.installed)
        let copies = found.contains { folderName($0) == requested } ? found.filter { folderName($0) == requested } : found
        let homeLock = ProjectRecords.savedLock(id: context.homeID, in: context.store)
        let rendered = { (name: String) in homeLock?.files.keys.contains { $0.hasPrefix(skillPrefix(name)) } ?? false }
        let agentsFolder = home.appending(path: ProjectBundle.skillsFolder).resolvingSymlinksInPath().standardizedFileURL.path
        // The shared folder's copy first: AKit renders there, and both harnesses read it.
        let shared = copies.filter { $0.realFolder.deletingLastPathComponent().standardizedFileURL.path == agentsFolder }
        let source = shared.first { rendered(folderName($0)) } ?? shared.first ?? copies.first
        let name = source.map(folderName) ?? requested
        for other in found where folderName(other) != name {
            warnings.append("\(shown(other.folder, home: home)) also says \(requested) in its header, but it is a different folder; it stays where it is.")
        }
        let readOnly = context.installed.filter { ($0.name == name || folderName($0) == name) && $0.isReadOnly }
        let core = brain.layers.first { $0.name == "core" }
        let inCore = core?.skills.contains { $0.name == name } ?? false
        let inBrain = brain.skills.contains { $0.name == name }
        if source == nil, !inCore {
            if let first = readOnly.first {
                blockers.append("\(name) is \(readOnlyKind(first)), so AKit can't move it. Turn it off per harness instead: Skills → the skill → the Claude / Pi picker (akit skills set \(name) --harness claude|pi --state off).")
            } else {
                blockers.append("\(name) is not a global skill on this Mac and the core layer doesn't list it: there is nothing to move.")
            }
        } else if let first = readOnly.first {
            warnings.append("\(name) also comes as \(readOnlyKind(first)), which AKit can't move; it stays where it is. Turn it off with the skill switches (Skills → the Claude / Pi picker).")
        }
        let sourceRendered = source.map { rendered(folderName($0)) } ?? false

        // Into the brain's library first, unless it has the skill.
        var brainImport: BrainImport.Plan?
        var digest: String?
        var planning = brain
        if let source {
            // Only the skill's own folder is read, also when it is a link into a development folder.
            let importPlan = BrainImport.plan(skill: source.folder, name: name, into: brain.root, env: env)
            switch importPlan.candidates.first?.state {
            case .new?:
                brainImport = importPlan
                planning = brain.addingSkill(name, from: source.realFolder)
                digest = Self.digest(source.realFolder)
            case .different? where !sourceRendered:
                blockers.append("The brain's skills/\(name) differs from \(shown(source.folder, home: home)). Compare them (Show Edits), bring what you want to keep into one of them, then move again.")
                edits += differences(brain: brain.root.appending(path: "skills/\(name)"), copy: source.realFolder,
                                     shownCopy: shown(source.folder, home: home))
            case nil where !inBrain:
                blockers.append("\(shown(source.folder, home: home)) can't be copied into the brain (its folder name is not a valid skill name).")
            default:
                break
            }
        }

        // The core layer without the skill, for the home folder's plan and the layer.yaml diff.
        var coreEdit: LayerEdit?
        if !keepGlobal, inCore, let core {
            do {
                let edit = try BrainRemove.layerWithoutSkill(name, in: core)
                coreEdit = LayerEdit(before: edit.before, after: edit.after)
            } catch {
                blockers.append("layers/core/layer.yaml: \(error.message)")
            }
        }
        let others = brain.layers.filter { $0.name != "core" && $0.skills.contains { $0.name == name } }.map(\.name)
        if !others.isEmpty {
            notes.append("Layer\(others.count == 1 ? "" : "s") \(others.joined(separator: ", ")) also list\(others.count == 1 ? "s" : "") \(name); projects that use \(others.count == 1 ? "it" : "them") keep it.")
        }

        // Each project: its answers with the skill, and only the skill's paths applied.
        let parts = targets.map { target in
            part(target, name: name, mode: mode, brain: planning, context: context)
        }
        for part in parts {
            if part.state == .answersOnly {
                notes.append("\(part.id) is not on this Mac: its answers get \(name), and Set Up Project on the Mac that has it renders it there.")
            }
            if part.state == .keepOwn, !part.ownTracked, !keepGlobal {
                warnings.append("\(part.id)'s own \(name) is not in git: its git worktrees won't have \(name) once core drops it. Commit it, or move it the usual way instead.")
            }
        }
        if parts.filter({ $0.state == .add }).count >= 3 {
            notes.append("\(name) goes to \(parts.filter { $0.state == .add }.count) projects: a layer may suit it better (Brain → New Layer…, with \(name) in its skills).")
        }
        if parts.isEmpty { blockers.append("Pick at least one project.") }

        // The home folder: AKit's rendered copy goes with the core layer's next render, a copy
        // AKit didn't write goes to the Trash.
        var homePlan: ProjectSetup.Plan?
        var homePaths: Set<String> = [], homeExcluded: Set<String> = []
        var trashSource: [URL] = []
        var extra: [Skill] = []
        var trashItems: [URL] = []
        if !keepGlobal {
            if rendered(name) {
                let saved = ProjectRecords.savedAnswers(id: context.homeID, in: context.store)
                var answers = saved ?? ProjectAnswers(targets: context.targets)
                answers.layers = ["core"]
                let homeBrain = coreEdit.flatMap { planning.replacingLayer("core", text: $0.after) } ?? planning
                let plan = ProjectSetup.plan(project: home, id: context.homeID, answers: answers, brain: homeBrain, store: context.store,
                                             forHome: true, piAgentDirSetting: context.piAgentDirSetting,
                                             rememberPiAgentDir: context.rememberPiAgentDir, env: env)
                let ours = plan.changes.filter { $0.path.hasPrefix(skillPrefix(name)) }
                homePaths = Set(ours.filter { $0.kind == .remove }.map(\.path))
                homeExcluded = Set(plan.changes.map(\.path)).subtracting(homePaths)
                let edited = ours.filter { $0.kind == .keepEdited }
                if !edited.isEmpty {
                    blockers.append("~/\(skillPrefix(name)) was edited by hand since AKit wrote it (\(edited.map(\.path).joined(separator: ", "))). Show Edits, bring what you want to keep into the brain's skills/\(name) (Brain → the skill), then move again.")
                    for change in edited {
                        let relative = String(change.path.dropFirst(skillPrefix(name).count))
                        edits.append(Edit(path: "~/\(change.path)",
                                          brainText: try? String(contentsOf: brain.root.appending(path: "skills/\(name)/\(relative)"), encoding: .utf8),
                                          copyText: change.oldText))
                    }
                }
                if !plan.canApply {
                    blockers += (plan.render.errors + plan.blockers).map { "Home folder: \($0)" }
                }
                if coreEdit == nil, !homePaths.isEmpty {
                    notes.append("The core layer no longer lists \(name); the home folder's copy is from an earlier render and goes now.")
                }
                homePlan = plan
            }
            if let source, !sourceRendered {
                do {
                    trashSource = try SkillRemover.items(for: source)
                } catch {
                    blockers.append(error.localizedDescription)
                }
            }
            // Other copies with the same folder name. One that holds something else than the
            // brain's skill (or the copy the brain is about to get) would lose that: it stops the move.
            let canonical = FileWalk.isDirectory(brain.root.appending(path: "skills/\(name)")) ? brain.root.appending(path: "skills/\(name)")
                : source?.realFolder
            for copy in copies where copy.id != source?.id && folderName(copy) == name {
                if !SkillRemover.removesOnlyLink(copy), let canonical {
                    let differing = differences(brain: canonical, copy: copy.realFolder, shownCopy: shown(copy.folder, home: home))
                    if !differing.isEmpty {
                        blockers.append("\(shown(copy.folder, home: home)) differs from the brain's \(name). Show Edits, bring what you want to keep into the brain's skills/\(name) (or delete that copy), then move again.")
                        edits += differing
                        continue
                    }
                }
                do {
                    trashItems += try SkillRemover.items(for: copy)
                    extra.append(copy)
                } catch {
                    blockers.append(error.localizedDescription)
                }
            }
            notes.append("Other Macs: Brain → Sync there offers Update Home Folder, which takes \(name) out of their home folder; each project there needs its own Apply (Set Up Project).")
        }

        warnings += mentions(of: name, brain: brain, targets: Set(targets.map(\.id)), projectFolders: context.projectFolders)

        let trashDigests = Dictionary((trashSource + trashItems).map { ($0.path, treeDigest($0)) }, uniquingKeysWith: { first, _ in first })
        return Plan(name: name, mode: mode, keepGlobal: keepGlobal, source: source, sourceRendered: sourceRendered, brainImport: brainImport,
                    sourceDigest: digest, parts: parts, coreEdit: coreEdit, home: homePlan, homePaths: homePaths, homeExcluded: homeExcluded,
                    trashSource: trashSource, extraCopies: extra, trashDigests: trashDigests, store: context.store, edits: edits, blockers: blockers,
                    warnings: warnings, notes: notes)
    }

    /// `~/…` for a path under the home folder, also when links were resolved in it (`/private/var/…`).
    public static func shown(_ url: URL, home: URL) -> String {
        let real = home.resolvingSymlinksInPath()
        let tilde = FileWalk.tilde(url, home: home)
        return tilde.hasPrefix("~") || real.path == home.path ? tilde : FileWalk.tilde(url, home: real)
    }

    static func readOnlyKind(_ skill: Skill) -> String {
        switch skill.scope {
        case .synced: "a claude.ai skill (synced by Claude)"
        case .plugin(let plugin): "a skill of the Claude Code plugin \(plugin)"
        case .package(let package, _): "a skill of the Pi package \(package)"
        case .bundled: "a skill bundled with the harness"
        default: "managed elsewhere"
        }
    }

    /// One project's part: its answers with the skill, the plan, and what stops it.
    static func part(_ target: Target, name: String, mode: LayerSkill.Mode, brain: Brain, context: Context) -> Part {
        let env = context.env
        func done(_ state: Part.State, folder: URL? = nil, own: URL? = nil, tracked: Bool = false) -> Part {
            Part(target: target, state: state, folder: folder, plan: nil, paths: [], excluded: [], isNew: false, localOnly: false,
                 savedLocalOnly: nil, worktrees: [], ownFolder: own, ownTracked: tracked)
        }
        let saved = ProjectRecords.savedAnswers(id: target.id, in: context.store)
        guard let given = target.folder, FileWalk.isDirectory(given) else {
            // Not here: its record gets the skill, so the Mac that has it renders it on its next Set Up.
            guard var answers = saved else {
                return done(.blocked(target.folder == nil
                    ? "is not on this Mac and AKit has no record of it. Set it up on a Mac that has it, or untick it."
                    : "its folder \(target.folder!.path) is gone and AKit has no record of it."))
            }
            if let localOnly = target.localOnly { answers.localOnly = localOnly }
            answers.skills.removeAll { $0.name == name }
            answers.skills.append(.init(name: name, mode: mode))
            var part = done(.answersOnly)
            part.answers = answers
            return part
        }
        // A worktree stands for its main checkout, which AKit sets up.
        let folder = GitCheckout.at(given).flatMap { $0.isLinkedWorktree ? $0.mainFolder : nil } ?? given
        let lock = ProjectRecords.savedLock(id: target.id, in: context.store)
        let prefix = "\(ProjectBundle.skillsFolder)/\(name)/"

        // The project's own copy: a folder (or link) AKit didn't write.
        let own = ProjectSkills.folder(of: folder).appending(path: name)
        var info = stat()
        if lstat(own.path, &info) == 0, !(lock?.files.keys.contains { $0.hasPrefix(prefix) } ?? false) {
            let tracked = LocalOnly.tracked(["\(ProjectBundle.skillsFolder)/\(name)"], in: folder, env: env)?.isEmpty == false
            if target.keepOwn { return done(.keepOwn, folder: folder, own: own, tracked: tracked) }
            let where_ = tracked ? "in git" : "not in git"
            return done(.blocked("has its own \(name) in \(ProjectBundle.skillsFolder) (\(where_)). Compare it, then keep the project's (just take \(name) out of core) or remove it from the project first."),
                        folder: folder, own: own, tracked: tracked)
        }

        var answers = saved ?? ProjectAnswers(targets: context.targets)
        if let localOnly = target.localOnly {
            answers.localOnly = localOnly
        } else if saved == nil {
            answers.localOnly = true  // a moved personal skill stays out of the project's git
        }
        answers.skills.removeAll { $0.name == name }
        answers.skills.append(.init(name: name, mode: mode))
        let plan = ProjectSetup.plan(project: folder, id: target.id, answers: answers, brain: brain, store: context.store, env: env)
        // The Claude link goes with the skill when it is new, AKit's own, or an empty folder.
        let link = plan.changes.first { $0.path == ".claude/skills" }
        let takesLink = link.map { change in
            change.kind == .create || (change.kind == .update && (!change.replacesUnmanaged || change.oldText == "(empty folder)"))
        } ?? false
        var paths = Set(plan.changes.filter { $0.path.hasPrefix(prefix) }.map(\.path))
        if takesLink { paths.insert(".claude/skills") }
        let excluded = Set(plan.changes.map(\.path)).subtracting(paths)
        let worktrees = plan.localOnly ? ProjectWorktrees.family(of: folder, env: env).worktrees : []
        var state = Part.State.add
        if !plan.canApply {
            state = .blocked((plan.render.errors + plan.blockers).joined(separator: " "))
        } else if plan.answers.targets.contains("claude"), !takesLink, !claudeSeesSkills(in: folder) {
            let now = (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.appending(path: ".claude/skills").path))
                .map { "links to \($0)" } ?? "is a folder of its own"
            state = .blocked(".claude/skills \(now), so Claude Code wouldn't see \(name) there. Point it at ../.agents/skills (Set Up Project), or take Claude out of the project's harnesses.")
        }
        return Part(target: target, state: state, folder: folder, plan: plan, paths: paths, excluded: excluded, isNew: saved == nil,
                    localOnly: plan.localOnly, savedLocalOnly: saved?.localOnly, worktrees: worktrees, ownFolder: nil, ownTracked: false)
    }

    /// `.claude/skills` leads to the project's `.agents/skills` (a link, also an absolute one).
    static func claudeSeesSkills(in project: URL) -> Bool {
        let link = project.appending(path: ".claude/skills").resolvingSymlinksInPath().standardizedFileURL.path
        return link == ProjectSkills.folder(of: project).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Comparing copies

    /// The files that differ between the brain's skill and another copy (missing on one side,
    /// or other bytes), each for Show Edits; binary files are named, not shown.
    static func differences(brain: URL, copy: URL, shownCopy: String) -> [Edit] {
        let left = BrainImport.copyableFiles(in: brain), right = BrainImport.copyableFiles(in: copy)
        func text(_ url: URL?) -> String? {
            guard let url else { return nil }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? "(a binary file)"
        }
        return Set(left.keys).union(right.keys).sorted().compactMap { path in
            if let a = left[path], let b = right[path], FileManager.default.contentsEqual(atPath: a.path, andPath: b.path) { return nil }
            return Edit(path: "\(shownCopy)/\(path)", brainText: text(left[path]), copyText: text(right[path]))
        }
    }

    /// What is at a path, as one hash: a link's destination, a file's bytes, or every entry of a
    /// folder (names, links, bytes), at most 10,000 entries.
    static func treeDigest(_ url: URL) -> String {
        let fm = FileManager.default
        if let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) { return "link:" + destination }
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isFolder) else { return "missing" }
        guard isFolder.boolValue else { return Checksum.sha256((try? Data(contentsOf: url)) ?? Data()) }
        var data = Data()
        let base = url.standardizedFileURL.path
        guard let walker = fm.enumerator(atPath: base) else { return "unreadable" }
        var count = 0
        while let relative = walker.nextObject() as? String, count < 10_000 {
            count += 1
            let path = base + "/" + relative
            data.append(Data(relative.utf8))
            if let destination = try? fm.destinationOfSymbolicLink(atPath: path) {
                data.append(Data(("→" + destination).utf8))
            } else if fm.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue {
                data.append(Data(Checksum.sha256((try? Data(contentsOf: URL(filePath: path))) ?? Data()).utf8))
            }
            data.append(0)
        }
        return Checksum.sha256(data)
    }

    // MARK: - Mentions

    /// Texts that name the skill and won't reach every session after the move: other brain
    /// skills, layer templates (the core layer's reach every session) and the AGENTS.md or
    /// CLAUDE.md of projects not moved to.
    static func mentions(of name: String, brain: Brain, targets: Set<String>, projectFolders: [String: URL]) -> [String] {
        var warnings: [String] = []
        for skill in brain.skills where skill.name != name {
            if textFiles(in: skill.folder).contains(where: { mentions(name, in: $0) }) {
                warnings.append("The brain's skill \(skill.name) mentions \(name); sessions outside the chosen projects will have \(skill.name) without \(name).")
            }
        }
        for layer in brain.layers where textFiles(in: layer.templates).contains(where: { mentions(name, in: $0) }) {
            warnings.append(layer.name == "core"
                ? "Strong: the core layer's templates mention \(name). Every session gets that text, but only the chosen projects will have \(name); edit the core layer's text."
                : "Layer \(layer.name)'s templates mention \(name); its projects that are not moved to won't have \(name).")
        }
        for (id, folder) in projectFolders.sorted(by: { $0.key < $1.key }) where !targets.contains(id) && !id.hasPrefix("home/") {
            for file in ["AGENTS.md", "CLAUDE.md"] {
                guard let text = readText(folder.appending(path: file)), mentions(name, in: text) else { continue }
                warnings.append("\(file) of \(id) mentions \(name), but \(id) won't have it.")
            }
        }
        return warnings
    }

    /// `name` as a word of its own: not part of a longer name (letters, digits, `-`, `_` around it).
    static func mentions(_ name: String, in text: String) -> Bool {
        guard !name.isEmpty else { return false }
        func isNamePart(_ character: Character?) -> Bool {
            character.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } ?? false
        }
        var start = text.startIndex
        while start < text.endIndex, let found = text.range(of: name, range: start..<text.endIndex) {
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            if !isNamePart(before), !isNamePart(after) { return true }
            start = found.upperBound  // always past the match: the loop ends
        }
        return false
    }

    /// Texts of the Markdown and text files under a folder: at most 200 files of at most 256 KB.
    static func textFiles(in folder: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var texts: [String] = []
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > 2_000 || texts.count >= 200 { break }
            guard ["md", "txt", "markdown"].contains(url.pathExtension.lowercased()), let text = readText(url) else { continue }
            texts.append(text)
        }
        return texts
    }

    static func readText(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              (values.fileSize ?? 0) <= 256 * 1024 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The bytes of a skill folder's files that an import copies, as one hash.
    static func digest(_ folder: URL) -> String {
        var data = Data()
        for (relative, url) in BrainImport.copyableFiles(in: folder).sorted(by: { $0.key < $1.key }) {
            data.append(Data(relative.utf8))
            data.append(0)
            data.append(Data(Checksum.sha256((try? Data(contentsOf: url)) ?? Data()).utf8))
        }
        return Checksum.sha256(data)
    }

    // MARK: - Apply

    /// Carries out the plan in the order that keeps the skill present everywhere: the brain
    /// import, each project's Apply (stopping at the first failure, before anything global
    /// changed), the core layer's edit, the home folder's Apply, then the copies to the Trash.
    @discardableResult
    public static func apply(_ plan: Plan, brain: Brain, env: HarnessEnvironment, trash: @escaping (URL) throws -> URL? = Trash.move,
                             hold: Hold = { _, work in try await work() }) async throws(Failure) -> Outcome {
        var outcome = Outcome()
        func fail(_ message: String) -> Failure { Failure(message: message, outcome: outcome) }
        guard plan.canApply else {
            let blocked = plan.parts.compactMap { part -> String? in
                if case .blocked(let reason) = part.state { "\(part.id): \(reason)" } else { nil }
            }
            throw fail((plan.blockers + blocked).joined(separator: "\n"))
        }
        if let digest = plan.sourceDigest, let source = plan.source, Self.digest(source.realFolder) != digest {
            throw fail("\(shown(source.folder, home: env.homeDirectory)) changed since the preview. Look at the preview again.")
        }
        let coreFile = brain.root.appending(path: "layers/core/layer.yaml")
        func coreChanged() -> Bool {
            guard let edit = plan.coreEdit else { return false }
            return (try? String(contentsOf: coreFile, encoding: .utf8)) != edit.before
        }
        if coreChanged() { throw fail("layers/core/layer.yaml changed since the preview. Look at the preview again.") }
        // What goes to the Trash must be what the preview compared.
        let home = env.homeDirectory
        for (path, digest) in plan.trashDigests.sorted(by: { $0.key < $1.key }) where treeDigest(URL(filePath: path)) != digest {
            throw fail("\(shown(URL(filePath: path), home: home)) changed since the preview. Look at the preview again.")
        }
        // A project that keeps its own copy must still have it.
        for part in plan.parts where part.state == .keepOwn {
            var info = stat()
            if let own = part.ownFolder, lstat(own.path, &info) != 0 {
                throw fail("\(part.id)'s own \(plan.name) is gone since the preview. Look at the preview again.")
            }
        }

        // 1. The brain's library.
        var current = brain
        if let importPlan = plan.brainImport {
            do {
                try await BrainImport.apply(importPlan, importing: [plan.name], listInLayer: false, env: env)
            } catch {
                let copied = FileManager.default.fileExists(atPath: brain.root.appending(path: "skills/\(plan.name)").path)
                throw fail("Copying \(plan.name) into the brain stopped: \(error.message) "
                           + (copied ? "skills/\(plan.name) may be in the brain, uncommitted: commit or remove it, then move again. " : "")
                           + "Nothing else changed.")
            }
            outcome.imported = true
            current = Brain.load(from: brain.root) ?? brain
        }

        // 2. The projects, one Apply each; the first failure stops before anything global changes.
        for part in plan.adding {
            guard let projectPlan = part.plan else { continue }
            do {
                let result = try await hold(part.id) {
                    try await ProjectSetup.apply(projectPlan, excluding: part.excluded, deferring: part.excluded, brain: current,
                                                 home: env.homeDirectory, env: env, trash: trash)
                }
                outcome.projects.append((part.id, result))
            } catch {
                let done = outcome.projects.map(\.id)
                throw fail("Moving stopped at \(part.id): \(error.localizedDescription) \(plan.name) is still in the core layer and the home folder"
                           + (done.isEmpty ? "." : "; it is already in \(done.joined(separator: ", ")).")
                           + (outcome.imported ? " The brain's library has it now." : ""))
            }
        }
        // Projects on other Macs: only their answers, so their Mac renders the skill on its next Set Up.
        for part in plan.answersOnly {
            guard let answers = part.answers else { continue }
            do {
                try await ProjectRecords.saveAnswers(answers, id: part.id, in: plan.store, message: "Add skill \(plan.name) to \(part.id)'s answers", env: env)
                outcome.answersSaved.append(part.id)
            } catch {
                throw fail("Moving stopped at \(part.id)'s answers: \(error.message) \(plan.name) is still in the core layer and the home folder.")
            }
        }
        guard !plan.keepGlobal else { return outcome }

        // 3. The core layer.
        if plan.coreEdit != nil {
            if coreChanged() {
                throw fail("layers/core/layer.yaml changed while moving; \(plan.name) is in the projects and still in core. Take it out of core by hand (Brain → core).")
            }
            do {
                try await BrainRemove.removeSkill(plan.name, fromLayer: "core", in: current, env: env)
            } catch {
                throw fail("\(plan.name) is in the projects, but taking it out of core stopped: \(error.message)")
            }
            outcome.coreChanged = true
            current = Brain.load(from: brain.root) ?? current
        }

        // 4. The home folder: AKit's rendered copy goes to the Trash.
        if let homePlan = plan.home, !plan.homePaths.isEmpty {
            do {
                outcome.home = try await hold(homePlan.id) {
                    try await ProjectSetup.apply(homePlan, excluding: plan.homeExcluded, deferring: plan.homeExcluded, brain: current,
                                                 home: env.homeDirectory, env: env, trash: trash)
                }
            } catch {
                throw fail("\(plan.name) is in the projects and out of the core layer, but the home folder's copy stayed in ~/\(ProjectBundle.skillsFolder)/\(plan.name): \(error.localizedDescription) Brain → core → Update Home Folder… (akit apply --home) takes it out.")
            }
        }

        // 5. Copies AKit didn't write.
        for url in plan.trashSource {
            do {
                _ = try trash(url)
                outcome.trashed.append(shown(url, home: home))
            } catch {
                outcome.notes.append("Couldn't move \(shown(url, home: home)) to the Trash: \(error.localizedDescription)")
            }
        }
        for copy in plan.extraCopies {
            do {
                let items = try SkillRemover.items(for: copy)
                try SkillRemover.moveToTrash(copy, trash: trash)
                outcome.trashed += items.map { shown($0, home: home) }
            } catch {
                outcome.notes.append("Couldn't move \(shown(copy.folder, home: home)) to the Trash: \(error.localizedDescription)")
            }
        }
        return outcome
    }
}
