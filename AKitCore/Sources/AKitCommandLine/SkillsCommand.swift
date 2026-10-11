import AKitFoundation
import AKitHarnesses
import AKitModel
import AKitSkills
import Foundation

/// `akit skills state` and `akit skills set`: turning installed skills on or off per harness
/// through the harness's own settings (docs/design/harness-support.md, "Skill switches").
extension AKitCLI {
    static let skillSwitchUsage = "Use: akit skills state [NAME] | akit skills set NAME --harness claude|pi "
        + "--state on|name-only|manual|off [--project PATH] [--yes]"

    static func skillSwitches(_ subcommand: String, _ args: inout Arguments, yes: Bool, env: HarnessEnvironment, cwd: URL,
                              projectsRoot: URL, out: (String) -> Void) throws -> Int32 {
        let harnessName = args.value("--harness"), stateName = args.value("--state"), projectPath = args.value("--project")
        let name = args.positional()
        try args.finish()
        let skills = SkillScanner.scan(installations: HarnessCatalog.detectAll(in: env),
                                       extraProjects: ProjectFinder.projects(inRoots: [projectsRoot]), in: env)
            .filter { skill in SkillSwitches.harnesses.contains { skill.visibleTo.contains($0) } }

        if subcommand == "state" {
            if harnessName != nil || stateName != nil || projectPath != nil || yes { throw Failure(message: skillSwitchUsage) }
            let shown = name.map { name in skills.filter { skill in skill.name == name || SkillSwitches.harnesses.contains { folderName(skill, $0) == name } } } ?? skills
            if let name, shown.isEmpty { throw Failure(message: "No skill named \(name) that Claude Code or Pi sees.") }
            out(skillStatesText(shown, env: env))
            return 0
        }

        guard let name, let harnessName, let stateName else { throw Failure(message: skillSwitchUsage) }
        let harness: HarnessID
        switch harnessName {
        case "claude", "claude-code": harness = .claudeCode
        case "pi": harness = .pi
        default: throw Failure(message: "--harness is claude or pi.")
        }
        guard let state = SkillSwitchState(argument: stateName) else { throw Failure(message: "--state is on, name-only, manual or off.") }
        let project = projectPath.map { resolve($0, cwd: cwd, env: env).path }
        // The harness's own name (the folder) first; the SKILL.md name only when no folder has it.
        let visible = skills.filter { $0.visibleTo.contains(harness) }
        var matches = visible.filter { folderName($0, harness) == name }
        var renamed: String?
        if matches.isEmpty {
            matches = visible.filter { $0.name == name }
            renamed = matches.first.flatMap { folderName($0, harness) }
        }
        func scope(_ skill: Skill) -> SkillScope { skill.places[harness]?.scope ?? skill.scope }
        if let project {
            matches = matches.filter { if case .project(let url) = scope($0) { url.standardizedFileURL.path == project } else { false } }
        } else if matches.contains(where: { scope($0) == .global }) {
            matches = matches.filter { scope($0) == .global }
        }
        guard let skill = matches.first else {
            throw Failure(message: "No skill named \(name) that \(harness.displayName) sees\(project.map { " in \($0)" } ?? "").")
        }
        // Claude Code's entry is by name, so any copy gives the same plan; Pi's file depends on the copy.
        if harness == .pi, matches.count > 1 {
            let places = matches.map { FileWalk.tilde($0.file, home: env.homeDirectory) }.joined(separator: ", ")
            throw Failure(message: "Several skills named \(name): \(places). Pick one with --project PATH.")
        }
        let plan: SkillSwitches.Plan
        do { plan = try SkillSwitches.plan(skill, harness: harness, to: state, in: env) } catch { throw Failure(message: error.message) }
        let file = FileWalk.tilde(plan.file, home: env.homeDirectory)
        if plan.changesNothing {
            out("\(name) is already \(plan.to.title) in \(harness.displayName) (\(file)). Nothing to do.")
            return 0
        }
        var lines: [String] = []
        if let renamed, renamed != name {
            lines.append("\(name) is the name in its SKILL.md; \(harness.displayName) knows the skill as \(renamed) (its folder), so that is used.")
        }
        lines.append("\(name) in \(harness.displayName): \(plan.from.title) → \(plan.to.title). Changes \(file):")
        lines += TextDiff.unified(plan.diff)
        lines += plan.notes
        if !yes {
            lines.append("Run again with --yes to do it.")
            out(lines.joined(separator: "\n"))
            return 0
        }
        let backup: URL?
        do { backup = try SkillSwitches.apply(plan, home: env.homeDirectory) } catch { throw Failure(message: error.message) }
        lines.append("Done.\(backup.map { " A backup is in \(FileWalk.tilde($0, home: env.homeDirectory))." } ?? "")")
        out(lines.joined(separator: "\n"))
        return 0
    }

    /// The name a harness gives the skill: Claude Code's command name (the folder), Pi's folder
    /// (or the file name of a single-file skill).
    static func folderName(_ skill: Skill, _ harness: HarnessID) -> String? {
        if harness == .claudeCode { return SkillSwitches.claudeName(of: skill) }
        guard let place = skill.places[harness] else { return nil }
        return skill.isSingleFile ? place.file.deletingPathExtension().lastPathComponent : place.folderName
    }

    /// One line per skill: its name, where it lives, and its state in each harness that sees it.
    static func skillStatesText(_ skills: [Skill], env: HarnessEnvironment) -> String {
        guard !skills.isEmpty else { return "No skills that Claude Code or Pi sees." }
        let states = SkillSwitches.states(of: skills, in: env)
        let sorted = skills.sorted { ($0.name, $0.file.path) < ($1.name, $1.file.path) }
        let width = min(sorted.map(\.name.count).max() ?? 0, 40)
        return sorted.map { skill in
            let parts = SkillSwitches.harnesses.compactMap { harness -> String? in
                guard skill.visibleTo.contains(harness) else { return nil }
                guard let reading = states[skill.id]?[harness] else { return "\(harness.displayName): no switch" }
                if case .unknown(let reason) = reading { return "\(harness.displayName): unknown (\(reason))" }
                let alias = harness == .claudeCode ? SkillSwitches.claudeName(of: skill).flatMap { $0 == skill.name ? nil : " (as \($0))" } : nil
                return "\(harness.displayName): \(reading.title)\(alias ?? "")"
            }
            let padded = skill.name.padding(toLength: max(width, skill.name.count), withPad: " ", startingAt: 0)
            // The scanner's problems (descriptions a harness cuts or warns about, name collisions), one per line.
            return (["\(padded)  \(parts.joined(separator: ", "))  \(FileWalk.tilde(skill.file, home: env.homeDirectory))"]
                    + skill.warnings.map { "  ! \($0)" }).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}
