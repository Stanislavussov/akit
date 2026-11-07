import AKitBrain
import AKitFoundation
import Foundation

/// `akit skills builtin [NAME…] [--mode auto|manual] [--json] [--yes]`: AKit's own skills
/// (`/akit`, `/akit-context`) in an older brain. Shows where each stands; `--yes` adds the missing
/// ones to core and brings outdated copies up to this AKit's template, in one brain commit.
extension AKitCLI {
    static let builtInUsage = "Use: akit skills builtin [akit|akit-context …] [--mode auto|manual] [--json] [--yes]"

    struct BuiltInSkillJSON: Encodable {
        let name: String
        let state: String
        let inCore: Bool
        let mode: String
    }

    static func builtInSkills(_ args: inout Arguments, json: Bool, yes: Bool, brainRoot: URL, env: HarnessEnvironment,
                              out: (String) -> Void) async throws -> Int32 {
        let modeText = args.value("--mode")
        var names: [String] = []
        while let name = args.positional() { names.append(name) }
        try args.finish()
        let known = BuiltInSkills.templates.map(\.name)
        if let unknown = names.first(where: { !known.contains($0) }) {
            throw Failure(message: "AKit has no own skill named \(unknown). \(builtInUsage)")
        }
        var mode: LayerSkill.Mode?
        if let modeText {
            guard let chosen = LayerSkill.Mode(rawValue: modeText), chosen != .off else { throw Failure(message: "--mode is auto or manual.") }
            mode = chosen
        }
        let plan: BuiltInSkills.Plan
        do {
            plan = try BuiltInSkills.plan(brain: brainRoot)
        } catch {
            throw Failure(message: error.message)
        }
        let chosen = names.isEmpty ? plan.items.filter(\.needsWork).map(\.name) : names
        let modes = Dictionary(uniqueKeysWithValues: chosen.compactMap { name in mode.map { (name, $0) } })

        if !yes {
            if json {
                out(encode(plan.items.map { BuiltInSkillJSON(name: $0.name, state: "\($0.state)", inCore: $0.inCore, mode: $0.mode.rawValue) }))
                return 0
            }
            var lines = plan.items.map { item in
                let state: String = switch item.state {
                case .missing: "missing from the brain"
                case .outdated: "the brain's copy differs from this AKit's"
                case .current: "up to date"
                }
                return "\(item.name)\t\(state); \(item.inCore ? "in core as \(item.mode.rawValue)" : "not in core")"
            }
            if plan.needsWork {
                lines.append("")
                lines.append("akit skills builtin [NAME…] [--mode auto|manual] --yes adds or updates them in the brain (one commit).")
            }
            out(lines.joined(separator: "\n"))
            return 0
        }
        let message: String?
        do {
            message = try await BuiltInSkills.apply(plan, names: chosen, modes: modes, env: env)
        } catch {
            throw Failure(message: error.message)
        }
        guard let message else {
            out("Nothing to do: the chosen skills are in the brain, up to date and in core.")
            return 0
        }
        out("\(message): committed in the brain.\nPut them into this Mac's home folder: akit apply --home")
        return 0
    }
}
