import AKitBrain
import AKitFoundation
import AKitModel
import AKitRender
import AKitSkills
import Foundation

/// Model invocation of one skill, Auto or Manual: `disable-model-invocation: true` in its SKILL.md
/// (harness-support.md, "Model invocation"). Unlike a skill switch this is the skill's own file,
/// so every harness that reads the key follows it. Two paths:
///
/// ```
/// your own copy                      SKILL.md: the line added or taken out (backup first)
/// a global copy AKit rendered        the layer's mode (committed in the brain) → the home copy
/// ```
///
/// A rendered copy edited by hand would come back at the next render, so its mode changes in the
/// layer that brings it and the home folder's Apply rewrites only that skill's files.
public enum SkillInvocation {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// One file's change, for the preview.
    public struct Diff: Identifiable, Hashable, Sendable {
        /// Where the file is, e.g. `~/.agents/skills/tdd/SKILL.md` or `layers/core/layer.yaml (brain)`.
        public let title: String
        public let lines: [TextDiff.Line]
        public var id: String { title }
    }

    public struct Plan: Sendable {
        /// The skill's name, as its SKILL.md gives it.
        public let skill: String
        /// The target: true = Manual (only `/name` runs it), false = Auto.
        public let manual: Bool
        /// The SKILL.md that gains or loses the line.
        public let file: URL
        /// A rendered copy: the layer whose mode changes; nil for your own copy.
        public let layer: String?
        public let diffs: [Diff]
        public let notes: [String]
        /// Your own copy: the file's bytes when the plan was made, and what Apply writes.
        let before: Data?
        let after: Data?
        /// A rendered copy: the brain's name for the skill, the layer's file before and after
        /// (nil when the layer has the mode already), and the home folder's Apply for its files.
        let name: String
        let layerEdit: SkillMove.LayerEdit?
        let home: ProjectSetup.Plan?
        let homePaths: Set<String>
        let homeExcluded: Set<String>

        public var changesNothing: Bool { before == after && layerEdit == nil && homePaths.isEmpty }
        /// The home folder's record, when Apply writes there (the app holds its worktree sync).
        public var holds: [String] { homePaths.isEmpty ? [] : (home.map { [$0.id] } ?? []) }
    }

    /// Why AKit can't change the skill's model invocation; nil when it can. `brain`: a skill whose
    /// file lies in the brain's folder (a link into it) is the brain's to change, with a commit.
    public static func unavailable(_ skill: Skill, link: BrainLink?, brain: Brain? = nil) -> String? {
        switch skill.scope {
        case .plugin: return "A plugin's skill belongs to its plugin; AKit doesn't edit plugin files."
        case .synced: return "claude.ai manages this skill and would write over the edit."
        case .bundled: return "This skill ships with the harness; AKit doesn't edit it."
        case .package: return "A Pi package's skill belongs to its package; AKit doesn't edit package files."
        case .project:
            if link?.isRendered == true {
                return "AKit rendered this copy into the project. Change its mode on the Brain screen (the layer, or the project's own skills)."
            }
        case .global: break
        }
        if skill.isReadOnly { return "This skill is read-only." }
        if let root = brain?.root.resolvingSymlinksInPath().standardizedFileURL.path,
           skill.realFile.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/") {
            return "This skill's file is inside the brain's folder (a link into it). Change it on the Brain screen: edit the brain's skill, or set its mode in a layer."
        }
        return nil
    }

    /// What making the skill Manual (or Auto) would change. Only reads. `link`: how the copy
    /// relates to the brain (`BrainLinks.links`); `brain` is needed for a rendered copy.
    public static func plan(_ skill: Skill, link: BrainLink?, manual: Bool, brain: Brain?, context: SkillMove.Context) throws(Failure) -> Plan {
        if let reason = unavailable(skill, link: link, brain: brain) { throw Failure(message: reason) }
        let env = context.env, home = env.homeDirectory
        let file = skill.realFile, shown = SkillMove.shown(file, home: home)
        var notes: [String] = []
        if !manual, let entry = SkillSwitches.claudeEntry(for: skill, in: env), entry == .manual || entry == .off {
            notes.append("Claude Code's own switch for this skill is \(entry.title), so Claude Code still won't offer it to the model. Set the Claude switch to On as well.")
        }

        guard case .rendered(let name, _, let edited)? = link else {
            guard let before = try? Data(contentsOf: file), let text = String(data: before, encoding: .utf8) else {
                throw Failure(message: "\(shown) can't be read as text.")
            }
            var after = text
            if Frontmatter.disablesModelInvocation(text) != manual {
                guard let changed = manual ? Render.manualOnly(text) : Render.modelInvocable(text) else {
                    throw Failure(message: "\(shown) has no --- header, so it can't be made Manual. Add a header with name and description first.")
                }
                after = changed
            }
            if after != text, let origin = skill.origin, !origin.hasPrefix("Your copy of") {
                notes.append("This skill came from \(origin): updating or reinstalling it from there may write over this edit.")
            }
            return Plan(skill: skill.name, manual: manual, file: file, layer: nil,
                        diffs: after == text ? [] : [Diff(title: shown, lines: TextDiff.lines(from: text, to: after))], notes: notes,
                        before: before, after: Data(after.utf8), name: skill.folder.lastPathComponent, layerEdit: nil, home: nil,
                        homePaths: [], homeExcluded: [])
        }

        // A global copy AKit rendered: the mode of the layer that brings it, then the home copy.
        guard let brain else { throw Failure(message: "The brain is not loaded; open the Brain screen again.") }
        let editedReason = "\(shown) was edited by hand since AKit wrote it. Bring the edits into the brain's skills/\(name) first (Edit in Brain), then change the mode."
        if edited { throw Failure(message: editedReason) }
        var answers = ProjectRecords.savedAnswers(id: context.homeID, in: context.store) ?? ProjectAnswers(targets: context.targets)
        answers.layers = ["core"]
        func homePlan(_ brain: Brain) -> ProjectSetup.Plan {
            ProjectSetup.plan(project: home, id: context.homeID, answers: answers, brain: brain, store: context.store, forHome: true,
                              piAgentDirSetting: context.piAgentDirSetting, rememberPiAgentDir: context.rememberPiAgentDir, env: env)
        }
        // The layer whose entry wins in the home folder's render (an `override: true` one, when two list it).
        guard let source = homePlan(brain).render.skills.first(where: { $0.name == name })?.source else {
            throw Failure(message: "No layer brings \(name) into the home folder now. Brain → core → Update Home Folder… first.")
        }
        guard source != ProjectBundle.projectSource, let layer = brain.layers.first(where: { $0.name == source }) else {
            throw Failure(message: "The home folder's own answers set the mode of \(name), not a layer. Change it on the Brain screen.")
        }
        var layerEdit: SkillMove.LayerEdit?
        var planning = brain
        do {
            let edit = try LayerEditor.layerWithMode(manual ? .manual : .auto, ofSkill: name, in: layer)
            if edit.before != edit.after {
                layerEdit = SkillMove.LayerEdit(before: edit.before, after: edit.after)
                planning = brain.replacingLayer(source, text: edit.after) ?? brain
            }
        } catch {
            throw Failure(message: "layers/\(source)/layer.yaml: \(error.message)")
        }

        let plan = homePlan(planning)
        let prefix = SkillMove.prefix(name)
        let ours = plan.changes.filter { $0.path.hasPrefix(prefix) }
        if ours.contains(where: { $0.kind == .keepEdited || $0.editedSinceRender }) { throw Failure(message: editedReason) }
        if ours.contains(where: { ($0.kind == .update && $0.replacesUnmanaged) || $0.kind == .suggest || $0.kind == .own }) {
            throw Failure(message: "~/\(prefix) holds a copy AKit didn't write. Compare it with the brain's, then remove or import it, and change the mode again.")
        }
        guard plan.canApply else {
            throw Failure(message: (plan.render.errors + plan.blockers).map { "Home folder: \($0)" }.joined(separator: "\n"))
        }
        let rendered = ours.first { $0.path == prefix + "SKILL.md" }
        guard let result = rendered.flatMap({ $0.kind == .same ? $0.oldText : $0.newText }), rendered?.kind != .remove else {
            throw Failure(message: "No layer brings \(name) into the home folder now. Brain → core → Update Home Folder… first.")
        }
        guard Frontmatter.disablesModelInvocation(result) == manual else {
            throw Failure(message: manual
                ? "The \(source) layer's mode didn't make \(name) Manual in the home folder. Change it on the Brain screen."
                : "The brain's skills/\(name)/SKILL.md sets disable-model-invocation itself, so the layer's mode can't make it Auto. Take the line out there (Edit in Brain), then Brain → core → Update Home Folder….")
        }
        let changed = ours.filter { $0.kind == .create || $0.kind == .update || $0.kind == .remove }
        let homePaths = Set(changed.map(\.path))
        var diffs: [Diff] = []
        if let layerEdit {
            diffs.append(Diff(title: "layers/\(source)/layer.yaml (brain)", lines: TextDiff.lines(from: layerEdit.before, to: layerEdit.after)))
        }
        diffs += changed.map { Diff(title: "~/\($0.path)", lines: TextDiff.lines(from: $0.oldText ?? "", to: $0.newText ?? "")) }
        if layerEdit != nil {
            let others = brain.projects(using: source).map(\.id).filter { !$0.hasPrefix("home/") }
            if !others.isEmpty {
                notes.append("The \(source) layer also goes to \(others.joined(separator: ", ")): each gets the new mode at its next Apply.")
            }
            notes.append("Other Macs: Brain → Sync there offers Update Home Folder, which brings the new mode to their home folder.")
        }
        return Plan(skill: skill.name, manual: manual, file: file, layer: source, diffs: diffs, notes: notes, before: nil, after: nil,
                    name: name, layerEdit: layerEdit, home: plan, homePaths: homePaths,
                    homeExcluded: Set(plan.changes.map(\.path)).subtracting(homePaths))
    }

    /// Carries out the plan: your own copy is backed up and written; for a rendered copy the
    /// layer's mode is set (a commit in the brain), then the home folder's Apply updates the
    /// skill's files. Refused when a file changed since the plan. Returns the backup, if one was made.
    @discardableResult
    public static func apply(_ plan: Plan, brain: Brain?, env: HarnessEnvironment, trash: @escaping (URL) throws -> URL? = Trash.move,
                             hold: SkillMove.Hold = { _, work in try await work() }) async throws(Failure) -> URL? {
        let home = env.homeDirectory
        guard let layer = plan.layer else {
            guard let after = plan.after else { return nil }
            do {
                return try SettingsFile.write(after, to: plan.file, expecting: plan.before, home: home)
            } catch {
                throw Failure(message: error.message)
            }
        }
        guard let brain else { throw Failure(message: "The brain is not loaded; open the Brain screen again.") }
        let manifest = brain.root.appending(path: "layers/\(layer)/layer.yaml")
        if let edit = plan.layerEdit, (try? String(contentsOf: manifest, encoding: .utf8)) != edit.before {
            throw Failure(message: "layers/\(layer)/layer.yaml changed since the preview. Look at the preview again.")
        }
        if let homePlan = plan.home, let path = ProjectSetup.changedSincePreview(homePlan, paths: plan.homePaths) {
            throw Failure(message: "~/\(path) changed since the preview. Look at the preview again.")
        }
        let mode: LayerSkill.Mode = plan.manual ? .manual : .auto
        var current = brain
        if plan.layerEdit != nil {
            do {
                try await LayerEditor.setMode(mode, ofSkill: plan.name, inLayer: layer, in: brain, env: env)
            } catch {
                // Stopped before the write (the brain's git identity, the file): the reason as it is.
                guard (try? String(contentsOf: manifest, encoding: .utf8)) == plan.layerEdit?.after else { throw Failure(message: error.message) }
                throw Failure(message: "layers/\(layer)/layer.yaml has the new mode (\(plan.name) is \(mode.rawValue)), but it is not committed in the brain, and the home folder's copy was not updated: \(error.message) Commit the file in the brain (Brain → Sync shows it), then Brain → core → Update Home Folder… (akit apply --home) updates the home copy.")
            }
            current = Brain.load(from: brain.root) ?? brain
        }
        guard let homePlan = plan.home, !plan.homePaths.isEmpty else { return nil }
        do {
            return try await hold(homePlan.id) {
                try await ProjectSetup.apply(homePlan, excluding: plan.homeExcluded, deferring: plan.homeExcluded, brain: current,
                                             home: home, env: env, trash: trash)
            }.backup
        } catch {
            throw Failure(message: "The brain has the new mode (\(plan.name) is \(mode.rawValue) in the \(layer) layer\(plan.layerEdit == nil ? "" : ", committed")), but the home folder's copy was not updated: \(error.localizedDescription) Brain → core → Update Home Folder… (akit apply --home) finishes it.")
        }
    }
}
