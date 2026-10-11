import AKitBrain
import AKitFoundation
import AKitInsights
import AKitSkills
import Foundation

/// Move to Global (layers.md, "Move a skill to a project", the reverse): a skill some projects
/// have moves into the core layer, so every session on this Mac gets it. The order keeps it
/// present at every point:
///
/// ```
/// a project's own copy only: into the brain's library      commit "Import skill X"
/// layers/core/layer.yaml + X                               commit "Add X to layer core"
/// home folder Apply: ~/.agents/skills/X (+ the Claude link when new)
/// each project: answers − X → Apply (its copy to the Trash, worktree links with the sync);
///   not on this Mac: answers only; its own copy (not in git): to the Trash
/// ```
///
/// A failure stops the move and says where the skill is.
extension SkillMove {
    /// One project the skill leaves.
    public struct GlobalPart: Identifiable, Sendable {
        public enum State: Hashable, Sendable {
            /// Its answers list the skill: they lose it, and Apply trashes the rendered copy.
            case answers
            /// Not on this Mac: only its answers lose the skill.
            case answersOnly
            /// Its own copy (not AKit's, not in git) goes to the Trash once the home folder has the skill.
            case ownCopy
            case blocked(String)
        }

        public let id: String
        public let state: State
        public let folder: URL?
        /// The Apply that drops the skill (answers on this Mac).
        public let plan: ProjectSetup.Plan?
        public let paths: Set<String>
        public let excluded: Set<String>
        /// `answersOnly`: the answers saved, and whether a work Mac sends them to the brain.
        public let answers: ProjectAnswers?
        public let workBrainAnswers: Bool
        /// `ownCopy`: what goes to the Trash.
        public let own: Skill?
        public let worktrees: [URL]
    }

    public struct GlobalPlan: Sendable {
        public let name: String
        public let mode: LayerSkill.Mode
        /// The project's own copy imported into the brain's library first; nil: the brain has it.
        public let brainImport: BrainImport.Plan?
        public let importSource: Skill?
        let importDigest: String?
        /// core's layer.yaml before and after; nil when core lists it already.
        public let coreEdit: LayerEdit?
        public let home: ProjectSetup.Plan?
        public let homePaths: Set<String>
        public let homeExcluded: Set<String>
        public let parts: [GlobalPart]
        let trashDigests: [String: String]
        let store: ProjectStore
        public let edits: [Edit]
        public let blockers: [String]
        public let warnings: [String]
        public let notes: [String]

        public var canApply: Bool {
            blockers.isEmpty && !parts.isEmpty && !parts.contains { if case .blocked = $0.state { true } else { false } }
        }
        /// Projects on this Mac whose files change (the app holds their worktree sync), and the home folder.
        public var holds: [String] { parts.filter { $0.folder != nil }.map(\.id) + (home.map { [$0.id] } ?? []) }
    }

    /// Projects whose saved answers list the skill (the default `--from`), home records left out.
    public static func projectsListing(_ name: String, brain: Brain, store: ProjectStore) -> [String] {
        var ids = BrainRemove.savedAnswers(in: store).filter { $0.answers.skills.contains { $0.name == name } }.map(\.id)
        if store.isLocal {
            ids += BrainRemove.savedAnswers(in: .brain(brain.root)).filter { $0.answers.skills.contains { $0.name == name } }.map(\.id)
        }
        return Array(Set(ids)).filter { !$0.hasPrefix("home/") }.sorted()
    }

    /// What moving `name` from `from` (project ids; nil: every project whose answers list it) into
    /// the core layer would do. `mode` nil: the first project's mode, else auto. Only reads.
    public static func planToGlobal(name: String, from: [String]?, mode chosen: LayerSkill.Mode?, brain: Brain,
                                    context: Context) -> GlobalPlan {
        let env = context.env, home = env.homeDirectory, store = context.store
        var blockers: [String] = [], warnings: [String] = [], notes: [String] = [], edits: [Edit] = []
        let ids = from ?? projectsListing(name, brain: brain, store: store)
        if ids.isEmpty { blockers.append("No project's answers list \(name); name the project with its own copy (--from).") }
        let brainOnly = store.isLocal ? Set(BrainRemove.savedAnswers(in: .brain(brain.root)).map(\.id))
            .subtracting(BrainRemove.savedAnswers(in: store).map(\.id)) : []

        // Each project: its answers entry, or its own copy.
        struct Found { let id: String; let folder: URL?; let answers: ProjectAnswers?; let own: Skill? }
        var found: [Found] = []
        for id in ids {
            let folder = context.projectFolders[id].flatMap { FileWalk.isDirectory($0) ? $0 : nil }
            let answers = ProjectRecords.savedAnswers(id: id, in: store)
            let lock = ProjectRecords.savedLock(id: id, in: store)
            let own = folder.flatMap { folder in
                context.installed.first { skill in
                    guard case .project(let url) = skill.scope, folderName(skill) == name, !skill.isReadOnly, !skill.isSingleFile else { return false }
                    let base = ProjectSkills.folder(of: folder).resolvingSymlinksInPath().standardizedFileURL.path
                    return url.standardizedFileURL.path == folder.standardizedFileURL.path
                        && skill.realFolder.deletingLastPathComponent().standardizedFileURL.path == base
                        && !(lock?.files.keys.contains { $0.hasPrefix(prefix(name)) } ?? false)
                }
            }
            found.append(Found(id: id, folder: folder, answers: answers, own: own))
        }
        let mode = chosen ?? found.lazy.compactMap { $0.answers?.skills.first { $0.name == name }?.mode }.first ?? .auto

        // The brain's library: an own copy is imported when the brain lacks the skill; it must equal the brain's otherwise.
        var planning = brain
        var brainImport: BrainImport.Plan?, importSource: Skill?, importDigest: String?
        let library = brain.root.appending(path: "skills/\(name)")
        let owns = found.compactMap(\.own)
        if !FileWalk.isDirectory(library) {
            if let source = owns.first {
                let importPlan = BrainImport.plan(skill: source.folder, name: name, into: brain.root, env: env)
                if importPlan.candidates.first?.state == .new {
                    brainImport = importPlan
                    importSource = source
                    importDigest = digest(source.realFolder)
                    planning = brain.addingSkill(name, from: source.realFolder)
                } else {
                    blockers.append("\(shown(source.folder, home: home)) can't be copied into the brain (its folder name is not a valid skill name).")
                }
            } else {
                blockers.append("The brain has no skills/\(name), and no chosen project has its own copy to import.")
            }
        }
        let canonical = FileWalk.isDirectory(library) ? library : importSource?.realFolder
        for own in owns where own.id != importSource?.id {
            guard let canonical else { continue }
            let differing = differences(brain: canonical, copy: own.realFolder, shownCopy: shown(own.folder, home: home))
            if !differing.isEmpty {
                blockers.append("\(shown(own.folder, home: home)) differs from the brain's \(name). Show Edits, bring what you want to keep into one of them, then move again.")
                edits += differing
            }
        }

        // The core layer with the skill.
        var coreEdit: LayerEdit?
        if let core = brain.layers.first(where: { $0.name == "core" }) {
            if core.skills.contains(where: { $0.name == name }) {
                notes.append("The core layer lists \(name) already.")
            } else {
                do {
                    let edit = try LayerEditor.layerWithSkill(name, mode: mode, in: core)
                    coreEdit = LayerEdit(before: edit.before, after: edit.after)
                    planning = planning.replacingLayer("core", text: edit.after) ?? planning
                } catch {
                    blockers.append("layers/core/layer.yaml: \(error.message)")
                }
            }
        } else {
            blockers.append("The brain has no core layer.")
        }

        // The home folder: only the skill's files (and the Claude link when new).
        var answers = ProjectRecords.savedAnswers(id: context.homeID, in: store) ?? ProjectAnswers(targets: context.targets)
        answers.layers = ["core"]
        let homePlan = ProjectSetup.plan(project: home, id: context.homeID, answers: answers, brain: planning, store: store, forHome: true,
                                         piAgentDirSetting: context.piAgentDirSetting, rememberPiAgentDir: context.rememberPiAgentDir, env: env)
        let ours = homePlan.changes.filter { $0.path.hasPrefix(prefix(name)) }
        var homePaths = Set(ours.filter { $0.kind == .create || ($0.kind == .update && !$0.replacesUnmanaged) }.map(\.path))
        if let link = homePlan.changes.first(where: { $0.path == ".claude/skills" }), link.kind == .create { homePaths.insert(link.path) }
        if ours.contains(where: { $0.kind == .update && $0.replacesUnmanaged }) || ours.contains(where: { $0.kind == .suggest || $0.kind == .own }) {
            blockers.append("~/\(prefix(name)) already holds a copy AKit didn't write. Compare it with the brain's, then remove it (Remove Everywhere… keeps the brain's) or import it, and move again.")
        }
        if ours.contains(where: { $0.kind == .keepEdited }) {
            blockers.append("~/\(prefix(name)) was edited by hand since AKit wrote it. Bring the edits into the brain's skills/\(name) first.")
        }
        if !homePlan.canApply { blockers += (homePlan.render.errors + homePlan.blockers).map { "Home folder: \($0)" } }
        let claudeMissesHome = homePlan.answers.targets.contains("claude") && !homePaths.contains(".claude/skills") && !claudeSeesSkills(in: home)
        for other in context.installed where other.scope == .global && folderName(other) == name
            && other.realFolder.deletingLastPathComponent().standardizedFileURL.path != home.appending(path: ProjectBundle.skillsFolder).resolvingSymlinksInPath().standardizedFileURL.path {
            warnings.append("\(shown(other.folder, home: home)) is another global \(name): harnesses that read both folders will see two. Remove it with Remove Everywhere… afterwards if it is the same skill.")
        }

        // Each project.
        var parts: [GlobalPart] = []
        var trashDigests: [String: String] = [:]
        for item in found {
            func part(_ state: GlobalPart.State, plan: ProjectSetup.Plan? = nil, paths: Set<String> = [], excluded: Set<String> = [],
                      answers: ProjectAnswers? = nil, work: Bool = false, own: Skill? = nil, worktrees: [URL] = []) -> GlobalPart {
                GlobalPart(id: item.id, state: state, folder: item.folder, plan: plan, paths: paths, excluded: excluded, answers: answers,
                           workBrainAnswers: work, own: own, worktrees: worktrees)
            }
            if let saved = item.answers, saved.skills.contains(where: { $0.name == name }) {
                var without = saved
                without.skills.removeAll { $0.name == name }
                guard let folder = item.folder else {
                    // A work Mac: a personal project's record only the brain has goes through WorkFilter.
                    parts.append(part(.answersOnly, answers: without, work: brainOnly.contains(item.id)))
                    continue
                }
                let plan = ProjectSetup.plan(project: folder, id: item.id, answers: without, brain: brain, store: store, env: env)
                let changes = plan.changes.filter { $0.path.hasPrefix(prefix(name)) }
                if changes.contains(where: { $0.kind == .keepEdited }) {
                    for change in changes where change.kind == .keepEdited {
                        let relative = String(change.path.dropFirst(prefix(name).count))
                        edits.append(Edit(path: "\(shown(folder, home: home))/\(change.path)",
                                          brainText: try? String(contentsOf: library.appending(path: relative), encoding: .utf8), copyText: change.oldText))
                    }
                    parts.append(part(.blocked("its \(prefix(name)) was edited by hand since AKit wrote it. Show Edits, bring the edits into the brain first.")))
                    continue
                }
                guard plan.canApply else {
                    parts.append(part(.blocked((plan.render.errors + plan.blockers).joined(separator: " "))))
                    continue
                }
                let paths = Set(changes.filter { $0.kind == .remove }.map(\.path))
                parts.append(part(.answers, plan: plan, paths: paths, excluded: Set(plan.changes.map(\.path)).subtracting(paths),
                                  worktrees: plan.localOnly ? ProjectWorktrees.family(of: folder, env: env).worktrees : []))
            } else if let own = item.own, let folder = item.folder {
                if let reason = SkillRemoval.trackedReason(folder: own.isSingleFile ? own.file : own.folder, env: env) {
                    parts.append(part(.blocked("its own \(name): \(reason)")))
                    continue
                }
                var skipped: [String] = []
                if let blocked = leftOut(own, home: home, &skipped).first {
                    warnings += skipped
                    parts.append(part(.blocked(blocked)))
                    continue
                }
                warnings += skipped
                do {
                    for item in try SkillRemover.items(for: own) {
                        let digest = treeDigest(item)
                        if digest == digestTooLarge || digest == digestUnreadable {
                            blockers.append("\(shown(item, home: home)) can't be checked again before the Trash (too many files, or parts AKit can't read); move it by hand.")
                        }
                        trashDigests[item.path] = digest
                    }
                    parts.append(part(.ownCopy, own: own))
                } catch {
                    parts.append(part(.blocked(error.localizedDescription)))
                }
            } else {
                parts.append(part(.blocked("doesn't list \(name) in its answers and has no copy of its own on this Mac.")))
            }
        }
        // Claude Code would lose the skill: the home folder's copy can't reach it, and a project's copy it loads goes.
        if claudeMissesHome {
            let claudeLoads = parts.filter { part in
                guard let folder = part.folder else { return false }
                switch part.state {
                case .answers where !part.paths.isEmpty, .ownCopy:
                    return context.installed.contains { skill in
                        guard case .project(let url) = skill.scope, url.standardizedFileURL.path == folder.standardizedFileURL.path else { return false }
                        return folderName(skill) == name && skill.visibleTo.contains(.claudeCode)
                    }
                default: return false
                }
            }.map(\.id)
            let why = "~/.claude/skills \((try? FileManager.default.destinationOfSymbolicLink(atPath: home.appending(path: ".claude/skills").path)).map { "links to \($0)" } ?? "is a folder of its own"), so Claude Code wouldn't see \(name) from the home folder"
            if claudeLoads.isEmpty {
                warnings.append(why + ".")
            } else {
                blockers.append(why + ", and the move takes it out of \(claudeLoads.joined(separator: ", ")), where Claude Code loads it now. Point ~/.claude/skills at ~/.agents/skills (Update Home Folder offers the link when the folder is empty), or take Claude out of the home folder's harnesses.")
            }
        }
        notes.append("Projects set up on a work Mac keep their records on that Mac, out of AKit's sight here: they keep their copy of \(name) until it leaves there.")
        // Projects not chosen that still list it keep their own render next to the global one.
        let others = projectsListing(name, brain: brain, store: store).filter { !ids.contains($0) }
        if !others.isEmpty {
            notes.append("\(others.joined(separator: ", ")) also list\(others.count == 1 ? "s" : "") \(name) in their answers and keep that copy; harnesses there see it twice until it leaves those answers too.")
        }
        notes.append("Other Macs: Brain → Sync there offers Update Home Folder, which adds \(name) to their home folder; each project there needs its own Apply.")
        return GlobalPlan(name: name, mode: mode, brainImport: brainImport, importSource: importSource, importDigest: importDigest,
                          coreEdit: coreEdit, home: homePlan, homePaths: homePaths, homeExcluded: Set(homePlan.changes.map(\.path)).subtracting(homePaths),
                          parts: parts, trashDigests: trashDigests, store: store, edits: edits, blockers: blockers, warnings: warnings, notes: notes)
    }

    static func prefix(_ name: String) -> String { "\(ProjectBundle.skillsFolder)/\(name)/" }

    public struct GlobalOutcome: Sendable {
        public var imported = false
        public var coreChanged = false
        public var home: ProjectSetup.Outcome?
        public var projects: [(id: String, outcome: ProjectSetup.Outcome)] = []
        public var answersSaved: [String] = []
        public var trashed: [String] = []
        public var notes: [String] = []
    }

    public struct GlobalFailure: Error, LocalizedError {
        public let message: String
        public let outcome: GlobalOutcome
        public var errorDescription: String? { message }
    }

    /// Carries out the plan in the order that keeps the skill present everywhere (see above).
    @discardableResult
    public static func applyToGlobal(_ plan: GlobalPlan, brain: Brain, env: HarnessEnvironment, trash: @escaping (URL) throws -> URL? = Trash.move,
                                     hold: Hold = { _, work in try await work() }) async throws(GlobalFailure) -> GlobalOutcome {
        var outcome = GlobalOutcome()
        func fail(_ message: String) -> GlobalFailure { GlobalFailure(message: message, outcome: outcome) }
        guard plan.canApply else {
            let blocked = plan.parts.compactMap { part -> String? in if case .blocked(let reason) = part.state { "\(part.id): \(reason)" } else { nil } }
            throw fail((plan.blockers + blocked).joined(separator: "\n"))
        }
        let home = env.homeDirectory
        // Before the first write: the import source, core's file, the home folder's and projects' files, the own copies.
        if let digest = plan.importDigest, let source = plan.importSource, Self.digest(source.realFolder) != digest {
            throw fail("\(shown(source.folder, home: home)) changed since the preview. Look at the preview again.")
        }
        let coreFile = brain.root.appending(path: "layers/core/layer.yaml")
        if let edit = plan.coreEdit, (try? String(contentsOf: coreFile, encoding: .utf8)) != edit.before {
            throw fail("layers/core/layer.yaml changed since the preview. Look at the preview again.")
        }
        if let homePlan = plan.home, let path = ProjectSetup.changedSincePreview(homePlan, paths: plan.homePaths) {
            throw fail("~/\(path) changed since the preview. Look at the preview again.")
        }
        for part in plan.parts {
            if let setup = part.plan, let path = ProjectSetup.changedSincePreview(setup, paths: part.paths) {
                throw fail("\(part.id): \(path) changed since the preview. Look at the preview again.")
            }
        }
        for (path, digest) in plan.trashDigests.sorted(by: { $0.key < $1.key }) where treeDigest(URL(filePath: path)) != digest {
            throw fail("\(shown(URL(filePath: path), home: home)) changed since the preview. Look at the preview again.")
        }

        // 1. The brain's library.
        var current = brain
        if let importPlan = plan.brainImport {
            do {
                try await BrainImport.apply(importPlan, importing: [plan.name], listInLayer: false, env: env)
            } catch {
                throw fail("Copying \(plan.name) into the brain stopped: \(error.message) It is still only in its project\(plan.parts.count == 1 ? "" : "s").")
            }
            outcome.imported = true
            current = Brain.load(from: brain.root) ?? brain
        }
        // 2. The core layer.
        if plan.coreEdit != nil {
            do {
                try await LayerEditor.addSkills([plan.name], mode: plan.mode, toLayer: "core", in: current, env: env)
            } catch {
                throw fail("Adding \(plan.name) to the core layer stopped: \(error.message) It is still only in its projects"
                           + (outcome.imported ? "; the brain's library has it now." : "."))
            }
            outcome.coreChanged = true
            current = Brain.load(from: brain.root) ?? current
        }
        // 3. The home folder.
        if let homePlan = plan.home, !plan.homePaths.isEmpty {
            do {
                outcome.home = try await hold(homePlan.id) {
                    try await ProjectSetup.apply(homePlan, excluding: plan.homeExcluded, deferring: plan.homeExcluded, brain: current,
                                                 home: home, env: env, trash: trash)
                }
            } catch {
                throw fail("\(plan.name) is in the core layer, but the home folder's Apply stopped: \(error.localizedDescription) It is still in its projects; Brain → core → Update Home Folder… (akit apply --home) puts it in the home folder.")
            }
        }
        // 4. The projects: the global copy is there now.
        let stopped = { (id: String, reason: String) -> GlobalFailure in
            let done = outcome.projects.map(\.id) + outcome.answersSaved + outcome.trashed
            return fail("\(plan.name) is in the core layer and the home folder, but taking it out of \(id) stopped: \(reason)"
                        + (done.isEmpty ? "" : " Already out of: \(done.joined(separator: ", ")).") + " The other projects still have their copy as well.")
        }
        for part in plan.parts {
            switch part.state {
            case .answers:
                guard let setup = part.plan else { continue }
                do {
                    let result = try await hold(part.id) {
                        try await ProjectSetup.apply(setup, excluding: part.excluded, deferring: part.excluded, brain: current, home: home,
                                                     env: env, trash: trash)
                    }
                    outcome.projects.append((part.id, result))
                } catch {
                    throw stopped(part.id, error.localizedDescription)
                }
            case .answersOnly:
                guard let answers = part.answers else { continue }
                do {
                    if part.workBrainAnswers {
                        try await WorkAnswers.removeSkill(plan.name, from: part.id, brain: brain.root, env: env)
                    } else {
                        try await ProjectRecords.saveAnswers(answers, id: part.id, in: plan.store,
                                                             message: "Remove skill \(plan.name) from \(part.id)'s answers", env: env)
                    }
                    outcome.answersSaved.append(part.id)
                } catch {
                    throw stopped(part.id, error.localizedDescription)
                }
            case .ownCopy, .blocked:
                continue
            }
        }
        // 5. Own copies last, each checked again right before it goes.
        for part in plan.parts where part.state == .ownCopy {
            guard let own = part.own else { continue }
            do {
                let items = try SkillRemover.items(for: own)
                for item in items where treeDigest(item) != plan.trashDigests[item.path] {
                    throw stopped(part.id, "\(shown(item, home: home)) changed since the preview, so it stays.")
                }
                try SkillRemover.moveToTrash(own, trash: trash)
                outcome.trashed += items.map { shown($0, home: home) }
            } catch let failure as GlobalFailure {
                throw failure
            } catch {
                throw stopped(part.id, error.localizedDescription)
            }
        }
        return outcome
    }
}
