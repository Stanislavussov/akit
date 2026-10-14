import AKitBrain
import AKitFoundation
import AKitModel
import AKitRender
import AKitSkills
import Foundation

/// Model invocation of many global skills at once, e.g. every global skill Manual to keep the
/// agent's skill listing short. The same two paths as one skill (`SkillInvocation.plan`):
///
/// ```
/// your own copies                each SKILL.md (backup first), one by one
/// global copies AKit rendered    the layers' modes (one brain commit) → one home folder Apply
/// ```
///
/// A skill that can't change (plugin, link into the brain, edited by hand, …) is skipped with
/// its reason; the others still change.
extension SkillInvocation {
    /// A skill the bulk change leaves as it is, and why.
    public struct Skip: Hashable, Sendable {
        public let skill: String
        public let reason: String
    }

    public struct BulkPlan: Sendable {
        /// The target: true = Manual, false = Auto.
        public let manual: Bool
        /// Your own copies, one plan each.
        public let own: [Plan]
        /// Global copies AKit rendered, by the brain's name, and the layers whose modes change.
        public let rendered: [String]
        public let layers: [String]
        public let diffs: [Diff]
        public let notes: [String]
        public let skipped: [Skip]
        /// The brain's names by layer, for `LayerEditor.setModes`; each layer's file before and after.
        let modes: [String: [String]]
        let layerEdits: [String: SkillMove.LayerEdit]
        let home: ProjectSetup.Plan?
        let homePaths: Set<String>
        let homeExcluded: Set<String>

        /// Every skill that changes, own copies first.
        public var skills: [String] { own.map(\.skill) + rendered }
        public var changesNothing: Bool { own.isEmpty && layerEdits.isEmpty && homePaths.isEmpty }
        /// The home folder's record, when Apply writes there (the app holds its worktree sync).
        public var holds: [String] { homePaths.isEmpty ? [] : (home.map { [$0.id] } ?? []) }
    }

    /// The global skills a bulk change to `manual` is about: those not already there, one per
    /// file (a skill two harnesses see through a link counts once).
    public static func globalCandidates(_ skills: [Skill], manual: Bool) -> [Skill] {
        var seen: Set<String> = []
        return skills.filter { $0.scope == .global && $0.disablesModelInvocation != manual }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .filter { seen.insert($0.realFile.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
    }

    /// What making all these skills Manual (or Auto) would change. Only reads. `links`: how each
    /// copy relates to the brain (`BrainLinks.links`).
    public static func planAll(_ skills: [Skill], links: [Skill.ID: BrainLink], manual: Bool, brain: Brain?,
                               context: SkillMove.Context) -> BulkPlan {
        let env = context.env, home = env.homeDirectory
        var skipped: [Skip] = []
        var own: [Plan] = []
        var rendered: [String] = []
        for skill in skills {
            if let reason = unavailable(skill, link: links[skill.id], brain: brain) {
                skipped.append(Skip(skill: skill.name, reason: reason))
                continue
            }
            if case .rendered(let name, _, let edited)? = links[skill.id] {
                if edited {
                    skipped.append(Skip(skill: skill.name, reason: "\(SkillMove.shown(skill.realFile, home: home)) was edited by hand since AKit wrote it. Bring the edits into the brain's skills/\(name) first (Edit in Brain)."))
                } else if !rendered.contains(name) {
                    rendered.append(name)
                }
                continue
            }
            do {
                let plan = try plan(skill, link: links[skill.id], manual: manual, brain: brain, context: context)
                if !plan.changesNothing { own.append(plan) }
            } catch {
                skipped.append(Skip(skill: skill.name, reason: error.message))
            }
        }

        var notes: [String] = []
        let sourced = skills.filter { skill in own.contains { $0.file == skill.realFile } && skill.origin.map { !$0.hasPrefix("Your copy of") } == true }
        if !sourced.isEmpty {
            notes.append("\(sourced.map(\.name).joined(separator: ", ")) came from a recorded source: updating or reinstalling from there may write over this edit.")
        }
        if !manual {
            let switched = skills.filter { skill in
                guard let entry = SkillSwitches.claudeEntry(for: skill, in: env) else { return false }
                return entry == .manual || entry == .off
            }
            if !switched.isEmpty {
                notes.append("Claude Code's own switch is Manual or Off for \(switched.map(\.name).joined(separator: ", ")), so Claude Code still won't offer them to the model. Set the Claude switch to On as well.")
            }
        }

        var layered = renderedPart(rendered, manual: manual, brain: brain, context: context)
        skipped += layered.skipped
        var diffs = own.flatMap(\.diffs)
        diffs += layered.diffs
        if !layered.layerEdits.isEmpty, let brain {
            let others = Set(layered.layerEdits.keys.flatMap { brain.projects(using: $0).map(\.id) }).filter { !$0.hasPrefix("home/") }.sorted()
            if !others.isEmpty {
                notes.append("The changed layers also go to \(others.joined(separator: ", ")): each gets the new modes at its next Apply.")
            }
            notes.append("Other Macs: Brain → Sync there offers Update Home Folder, which brings the new modes to their home folder.")
        }
        if layered.modes.isEmpty { layered.home = nil }
        return BulkPlan(manual: manual, own: own, rendered: layered.modes.values.flatMap { $0 }.sorted(), layers: layered.layerEdits.keys.sorted(),
                        diffs: diffs, notes: notes, skipped: skipped, modes: layered.modes, layerEdits: layered.layerEdits,
                        home: layered.home, homePaths: layered.homePaths, homeExcluded: layered.homeExcluded)
    }

    private struct Layered {
        var modes: [String: [String]] = [:]
        var layerEdits: [String: SkillMove.LayerEdit] = [:]
        var home: ProjectSetup.Plan?
        var homePaths: Set<String> = []
        var homeExcluded: Set<String> = []
        var diffs: [Diff] = []
        var skipped: [Skip] = []
    }

    /// The rendered copies: each one's layer mode set, then one home folder plan for all of them.
    /// A skill whose home copy can't follow is skipped and the plan made again without it.
    private static func renderedPart(_ names: [String], manual: Bool, brain: Brain?, context: SkillMove.Context) -> Layered {
        var result = Layered()
        guard !names.isEmpty else { return result }
        guard let brain else {
            result.skipped = names.map { Skip(skill: $0, reason: "The brain is not loaded; open the Brain screen again.") }
            return result
        }
        let env = context.env, home = env.homeDirectory
        var answers = ProjectRecords.savedAnswers(id: context.homeID, in: context.store) ?? ProjectAnswers(targets: context.targets)
        answers.layers = ["core"]
        func homePlan(_ brain: Brain) -> ProjectSetup.Plan {
            ProjectSetup.plan(project: home, id: context.homeID, answers: answers, brain: brain, store: context.store, forHome: true,
                              piAgentDirSetting: context.piAgentDirSetting, rememberPiAgentDir: context.rememberPiAgentDir, env: env)
        }

        // The layer whose entry wins in the home folder's render, per skill.
        let sources = homePlan(brain).render.skills
        var remaining: [String: String] = [:]
        for name in names {
            guard let source = sources.first(where: { $0.name == name })?.source else {
                result.skipped.append(Skip(skill: name, reason: "No layer brings \(name) into the home folder now. Brain → core → Update Home Folder… first."))
                continue
            }
            guard source != ProjectBundle.projectSource, brain.layers.contains(where: { $0.name == source }) else {
                result.skipped.append(Skip(skill: name, reason: "The home folder's own answers set the mode of \(name), not a layer. Change it on the Brain screen."))
                continue
            }
            remaining[name] = source
        }

        let mode: LayerSkill.Mode = manual ? .manual : .auto
        // Each round drops the skills that can't follow; it ends when none is dropped.
        while !remaining.isEmpty {
            var modes: [String: [String]] = [:]
            for (name, source) in remaining { modes[source, default: []].append(name) }
            var edits: [String: SkillMove.LayerEdit] = [:]
            var planning = brain
            var dropped = false
            for (source, skills) in modes.sorted(by: { $0.key < $1.key }) {
                guard let layer = brain.layers.first(where: { $0.name == source }) else { continue }
                do {
                    let edit = try LayerEditor.layerWithMode(mode, ofSkills: skills.sorted(), in: layer)
                    if edit.before != edit.after {
                        edits[source] = SkillMove.LayerEdit(before: edit.before, after: edit.after)
                        planning = planning.replacingLayer(source, text: edit.after) ?? planning
                    }
                } catch {
                    for skill in skills {
                        result.skipped.append(Skip(skill: skill, reason: "layers/\(source)/layer.yaml: \(error.message)"))
                        remaining[skill] = nil
                    }
                    dropped = true
                }
            }
            if dropped { continue }

            let plan = homePlan(planning)
            guard plan.canApply else {
                let reason = (plan.render.errors + plan.blockers).map { "Home folder: \($0)" }.joined(separator: "\n")
                result.skipped += remaining.keys.sorted().map { Skip(skill: $0, reason: reason) }
                return result
            }
            var paths: Set<String> = []
            for name in remaining.keys.sorted() {
                let prefix = SkillMove.prefix(name)
                let ours = plan.changes.filter { $0.path.hasPrefix(prefix) }
                var reason: String?
                if ours.contains(where: { $0.kind == .keepEdited || $0.editedSinceRender }) {
                    reason = "~/\(prefix) was edited by hand since AKit wrote it. Bring the edits into the brain's skills/\(name) first (Edit in Brain)."
                } else if ours.contains(where: { ($0.kind == .update && $0.replacesUnmanaged) || $0.kind == .suggest || $0.kind == .own }) {
                    reason = "~/\(prefix) holds a copy AKit didn't write. Compare it with the brain's, then remove or import it."
                } else {
                    let rendered = ours.first { $0.path == prefix + "SKILL.md" }
                    if let text = rendered.flatMap({ $0.kind == .same ? $0.oldText : $0.newText }), rendered?.kind != .remove {
                        if Frontmatter.disablesModelInvocation(text) != manual {
                            reason = manual
                                ? "The \(remaining[name] ?? "") layer's mode didn't make \(name) Manual in the home folder. Change it on the Brain screen."
                                : "The brain's skills/\(name)/SKILL.md sets disable-model-invocation itself, so the layer's mode can't make it Auto. Take the line out there (Edit in Brain)."
                        }
                    } else {
                        reason = "No layer brings \(name) into the home folder now. Brain → core → Update Home Folder… first."
                    }
                }
                if let reason {
                    result.skipped.append(Skip(skill: name, reason: reason))
                    remaining[name] = nil
                    dropped = true
                } else {
                    paths.formUnion(ours.filter { $0.kind == .create || $0.kind == .update || $0.kind == .remove }.map(\.path))
                }
            }
            if dropped { continue }

            result.modes = modes.mapValues { $0.sorted() }
            result.layerEdits = edits
            result.home = plan
            result.homePaths = paths
            result.homeExcluded = Set(plan.changes.map(\.path)).subtracting(paths)
            result.diffs = edits.sorted { $0.key < $1.key }.map { Diff(title: "layers/\($0.key)/layer.yaml (brain)", lines: TextDiff.lines(from: $0.value.before, to: $0.value.after)) }
                + plan.changes.filter { paths.contains($0.path) }.map { Diff(title: "~/\($0.path)", lines: TextDiff.lines(from: $0.oldText ?? "", to: $0.newText ?? "")) }
            return result
        }
        return result
    }

    /// Carries out the bulk plan: your own copies one by one (backup first, each refused when
    /// its file changed since the preview), then the layers' modes in one brain commit and the
    /// home folder's Apply for their copies. Returns the backups made.
    @discardableResult
    public static func applyAll(_ plan: BulkPlan, brain: Brain?, env: HarnessEnvironment, trash: @escaping (URL) throws -> URL? = Trash.move,
                                hold: SkillMove.Hold = { _, work in try await work() }) async throws(Failure) -> [URL] {
        let home = env.homeDirectory
        var backups: [URL] = []
        var failed: [String] = []
        for item in plan.own {
            do {
                if let backup = try await apply(item, brain: brain, env: env, trash: trash, hold: hold) { backups.append(backup) }
            } catch {
                failed.append("\(item.skill): \(error.message)")
            }
        }
        let done = plan.own.count - failed.count
        func failure(_ message: String) -> Failure {
            let ownPart = plan.own.isEmpty ? "" : "\(done) of \(plan.own.count) own copies changed. "
            return Failure(message: ownPart + (failed + [message]).filter { !$0.isEmpty }.joined(separator: "\n"))
        }

        if !plan.modes.isEmpty {
            guard let brain else { throw failure("The brain is not loaded; open the Brain screen again.") }
            for (layer, edit) in plan.layerEdits {
                let manifest = brain.root.appending(path: "layers/\(layer)/layer.yaml")
                if (try? String(contentsOf: manifest, encoding: .utf8)) != edit.before {
                    throw failure("layers/\(layer)/layer.yaml changed since the preview. Look at the preview again.")
                }
            }
            if let homePlan = plan.home, let path = ProjectSetup.changedSincePreview(homePlan, paths: plan.homePaths) {
                throw failure("~/\(path) changed since the preview. Look at the preview again.")
            }
            let mode: LayerSkill.Mode = plan.manual ? .manual : .auto
            var current = brain
            if !plan.layerEdits.isEmpty {
                do {
                    try await LayerEditor.setModes(mode, ofSkills: plan.modes.filter { plan.layerEdits[$0.key] != nil }, in: brain, env: env)
                } catch {
                    let written = plan.layerEdits.allSatisfy { layer, edit in
                        (try? String(contentsOf: brain.root.appending(path: "layers/\(layer)/layer.yaml"), encoding: .utf8)) == edit.after
                    }
                    guard written else { throw failure(error.message) }
                    throw failure("The layer files have the new modes, but they are not committed in the brain, and the home folder's copies were not updated: \(error.message) Commit the files in the brain (Brain → Sync shows them), then Brain → core → Update Home Folder… (akit apply --home) updates the home copies.")
                }
                current = Brain.load(from: brain.root) ?? brain
            }
            if let homePlan = plan.home, !plan.homePaths.isEmpty {
                do {
                    if let backup = try await hold(homePlan.id, {
                        try await ProjectSetup.apply(homePlan, excluding: plan.homeExcluded, deferring: plan.homeExcluded, brain: current,
                                                     home: home, env: env, trash: trash)
                    }).backup {
                        backups.append(backup)
                    }
                } catch {
                    throw failure("The brain has the new modes\(plan.layerEdits.isEmpty ? "" : " (committed)"), but the home folder's copies were not updated: \(error.localizedDescription) Brain → core → Update Home Folder… (akit apply --home) finishes it.")
                }
            }
        }
        if !failed.isEmpty { throw failure("") }
        return backups
    }
}
