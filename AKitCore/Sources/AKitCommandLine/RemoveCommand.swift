import AKitBrain
import AKitFoundation
import AKitProjectSetup
import AKitSkills
import Foundation

/// `akit remove skill NAME --everywhere [--library] [--yes]`: Remove Everywhere (docs/design/layers.md,
/// "Remove a skill everywhere"). Prints every place a harness loads the skill from with its
/// action; `--yes` carries out the default ones.
extension AKitCLI {
    static func removeEverywhere(_ name: String, library: Bool, yes: Bool, brainRoot: URL, env: HarnessEnvironment, projectsRoot: URL,
                                 hostName: String, installedTargets: [String], out: (String) -> Void, err: (String) -> Void,
                                 trash: @escaping (URL) throws -> URL?) async throws -> Int32 {
        let brain = Brain.load(from: brainRoot)
        if let problem = MachineProfile.load(home: env.homeDirectory).problem { err("akit: \(problem)") }
        let context = await skillContext(brainRoot: brainRoot, env: env, projectsRoot: projectsRoot, hostName: hostName,
                                         installedTargets: installedTargets)
        var plan = SkillRemoval.plan(name: name, brain: brain, context: context)
        if library {
            plan = SkillRemoval.plan(name: name, brain: brain, context: context, leaving: plan.leaving.subtracting(["library"]))
        }
        out(removeText(plan, home: env.homeDirectory))
        guard plan.places.contains(where: { $0.skill != nil || $0.action != .library }) else { return 1 }
        guard plan.canApply else { return 1 }
        guard yes else {
            out("Run again with --yes to remove it.")
            return 0
        }
        do {
            let outcome = try await SkillRemoval.apply(plan, brain: brain, env: env, trash: trash)
            out((outcome.done.map { "Done: \($0)." } + outcome.notes).joined(separator: "\n"))
            return 0
        } catch {
            throw Failure(message: error.message)
        }
    }

    /// The places by group, each with its action, then what stays and why.
    static func removeText(_ plan: SkillRemoval.Plan, home: URL) -> String {
        guard !plan.places.isEmpty else { return "No skill named \(plan.name) on this Mac or in the brain." }
        var lines = ["Remove \(plan.name) everywhere a harness loads it from:"]
        var groups: [String] = []
        for place in plan.places where !groups.contains(place.group) { groups.append(place.group) }
        for group in groups {
            lines.append(group + ":")
            for place in plan.places where place.group == group {
                let mark = place.selected ? "[x]" : place.canSelect ? "[ ]" : " - "
                let harnesses = place.harnesses.isEmpty ? "" : " [\(place.harnesses.map(\.displayName).joined(separator: ", "))]"
                var line = "  \(mark) \(place.title)\(harnesses): \(actionText(place))"
                if place.byHeader { line += " (maybe the same skill: its header says \(plan.name); not ticked)" }
                lines.append(line)
                if let reason = place.reason { lines.append("      \(reason)") }
                if place.selected, let before = place.before, let after = place.after {
                    lines += TextDiff.unified(TextDiff.lines(from: before, to: after)).map { "      " + $0 }
                }
            }
        }
        lines += plan.blockers.map { "blocked: \($0)" }
        lines += plan.notes.map { "note: \($0)" }
        lines.append(plan.summary)
        if plan.places.contains(where: { $0.action == .claudeOff && !$0.selected }) {
            lines.append("claude.ai skills: turn them off with akit skills set \(plan.name) --harness claude --state off, or tick them in the app.")
        }
        if let plugin = plan.places.first(where: { $0.plugin != nil })?.plugin {
            lines.append("Plugin skills: Remove Everywhere… in the app offers Disable Plugin… for \(plugin) (enabledPlugins), or /plugin in Claude Code.")
        }
        return lines.joined(separator: "\n")
    }

    static func actionText(_ place: SkillRemoval.Place) -> String {
        switch place.action {
        case .trash: place.skill.map { SkillRemover.removesOnlyLink($0) } == true ? "the link goes to the Trash" : "to the Trash"
        case .layer(let layer): "\(place.selected ? "" : "keep: ")out of layer \(layer), committed"
        case .answers(let id): "\(place.selected ? "" : "keep: ")out of \(id)'s answers"
        case .claudeOff: "Claude switch Off (skillOverrides)"
        case .rendered: place.selected ? "AKit's copy, to the Trash with its Apply" : "AKit's copy, stays with its brain entry"
        case .library: place.selected ? "out of the brain library, committed (history stays)" : "stays in the brain library (--library deletes it)"
        case .keep: "stays"
        }
    }
}
