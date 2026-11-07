import AKitFoundation
import AKitHarnesses
import AKitLab
import AKitModel
import AKitSkills
import Foundation

/// `akit skills port`: a Claude Code skill ported to Pi and checked (docs/design/skill-port.md).
extension AKitCLI {
    static var skillPortUsage: String {
        """
        akit skills port — a Claude Code skill rewritten as a Pi skill, then checked.

          akit skills port SKILL [--to global|project PATH] [--model HARNESS[:MODEL]] [--no-model] [--json] [--yes]
                                          SKILL: a skill folder, or the name of a skill Claude Code
                                          sees (plugin skills too). The port: frontmatter cut to Pi's
                                          fields, /plugin:x → /skill:x, .claude and .omc paths,
                                          tool names, OMC role prompts copied into references/;
                                          then one model call rewrites subagents, questions, task
                                          lists, MCP state and handoffs (a second one when the check
                                          still finds leftovers). --no-model: only the first part.
                                          --model: claude-code:haiku, pi, pi:PROVIDER/MODEL (default:
                                          the translation model). Without --to it only shows the
                                          check and SKILL.md. --to global: ~/.pi/agent/skills/NAME;
                                          --to project PATH: PATH/.pi/skills/NAME. Shows the diff;
                                          --yes writes it (an old folder goes to the Trash). A
                                          failed check is never written
          akit skills port --check-only PATH [--json]
                                          Check a Pi skill folder: leftovers and what Pi needs

        The check: pass, warnings (Claude Code leftovers by file and line, numbers or headings of
        the original lost) or fail (no name or description, name not the folder's or against Pi's
        rules, a referenced file missing). Exit 1 on fail. The model call goes through the sending
        policy, the monthly limit and the send log (purpose port-skill); each run calls again.
        """
    }

    struct SkillPortJSON: Encodable {
        let name: String
        let source: String
        let verdict: String
        let report: SkillPortCheck.Report
        let changes: [String]
        let files: [String]
        let skillMd: String
        let model: String?
        let rounds: Int
        let target: String?
        let replaces: Bool?
        let installed: Bool
        let trashed: String?
    }

    static func skillPort(_ args: inout Arguments, json: Bool, yes: Bool, env: HarnessEnvironment, cwd: URL, projectsRoot: URL,
                          out: (String) -> Void, trash: (URL) throws -> URL?) async throws -> Int32 {
        if args.flag("--help") || args.flag("-h") || args.isEmpty {
            out(skillPortUsage)
            return 0
        }
        let noModel = args.flag("--no-model")
        let checkOnly = args.value("--check-only")
        let modelText = args.value("--model")
        let toText = args.value("--to")
        let skillText = args.positional()
        let projectText = toText == "project" ? args.positional() : nil
        try args.finish()

        if let checkOnly {
            if skillText != nil || toText != nil || modelText != nil || noModel || yes {
                throw Failure(message: "--check-only PATH goes alone (and with --json).")
            }
            let folder = resolve(checkOnly, cwd: cwd, env: env)
            let report: SkillPortCheck.Report
            do { report = try SkillPortCheck.check(folder: folder) } catch { throw Failure(message: error.localizedDescription) }
            if json {
                out(try labJSON(report))
            } else {
                out((["\(FileWalk.tilde(folder, home: env.homeDirectory))"] + report.lines).joined(separator: "\n"))
            }
            return report.verdict == .fail ? 1 : 0
        }

        guard let skillText else { throw Failure(message: "Which skill? akit skills port SKILL (a folder or a skill name).") }
        let target: SkillPort.Target?
        switch toText {
        case nil: target = nil
        case "global": target = .global
        case "project":
            guard let projectText else { throw Failure(message: "--to project needs the project's folder: --to project PATH.") }
            target = .project(resolve(projectText, cwd: cwd, env: env))
        case let other?: throw Failure(message: "--to is global or project PATH, not \(other).")
        }
        if noModel, modelText != nil { throw Failure(message: "--model doesn't go with --no-model.") }
        if yes, target == nil { throw Failure(message: "--yes writes the port: say where with --to global or --to project PATH.") }
        let source = try portSource(skillText, env: env, cwd: cwd, projectsRoot: projectsRoot)

        var draft: SkillPort.Draft
        do { draft = try SkillPort.port(folder: source, env: env) } catch { throw Failure(message: error.localizedDescription) }
        var report = SkillPortCheck.check(draft)
        var modelLabel: String?
        var rounds = 0
        if !noModel {
            let settings = try LabSettings.loadForSending(env: env)
            let agent = try modelText.map(portAgent) ?? SkillPortModel.agent(settings: settings, env: env)
            let gate: SendGate
            do { gate = try await SkillPortModel.gate(agent: agent, env: env) } catch { throw Failure(message: error.localizedDescription) }
            let outcome: SkillPortModel.Outcome
            do { outcome = try await SkillPortModel.run(draft, agent: agent, gate: gate, env: env) } catch {
                throw Failure(message: error.localizedDescription)
            }
            draft = outcome.draft
            report = outcome.report
            rounds = outcome.rounds
            modelLabel = OutputTranslation.modelLabel(agent)
        }

        let plan = target.map { SkillPort.plan(draft, target: $0, env: env) }
        var installed = false
        var trashed: URL?
        if yes, let plan {
            guard report.verdict != .fail else {
                throw Failure(message: "The check failed; nothing written.\n" + report.lines.joined(separator: "\n"))
            }
            do { trashed = try SkillPort.install(draft, plan: plan, trash: trash) } catch { throw Failure(message: error.localizedDescription) }
            installed = true
        }

        if json {
            out(try labJSON(SkillPortJSON(name: draft.name, source: source.path, verdict: report.verdict.rawValue, report: report,
                                          changes: draft.changes, files: draft.paths.sorted(), skillMd: draft.skillText, model: modelLabel,
                                          rounds: rounds, target: plan?.folder.path, replaces: plan?.replaces, installed: installed,
                                          trashed: trashed?.path)))
            return report.verdict == .fail ? 1 : 0
        }
        let home = env.homeDirectory
        var lines = ["Port \(draft.name) from \(FileWalk.tilde(source, home: home)) to Pi"
                     + (modelLabel.map { " (model: \($0), \(rounds) round\(rounds == 1 ? "" : "s"))" } ?? " (no model)")]
        lines.append("Changes:")
        lines += draft.changes.isEmpty ? ["  none"] : draft.changes.map { "  - \($0)" }
        lines += report.lines
        if let plan {
            let place = FileWalk.tilde(plan.folder, home: home)
            lines.append(plan.replaces ? "Replaces \(place) (the old folder goes to the Trash). SKILL.md:" : "Creates \(place). SKILL.md:")
            lines += TextDiff.unified(plan.diff)
            if plan.changed.count > 1 { lines.append("Files: \(plan.changed.joined(separator: ", "))") }
            if installed {
                lines.append("Done.\(trashed.map { " The old folder is in the Trash: \(FileWalk.tilde($0, home: home))." } ?? "")")
                lines.append("Reload skills in running Pi sessions (/reload).")
            } else if report.verdict == .fail {
                lines.append("The check failed: --yes won't write it.")
            } else {
                lines.append("Run again with --yes to write it.")
            }
        } else {
            lines.append("--- SKILL.md (ported)")
            lines += TextDiff.unified(TextDiff.lines(from: draft.originals[SkillPort.skillFile] ?? "", to: draft.skillText))
            lines.append("Write it with --to global or --to project PATH.")
        }
        out(lines.joined(separator: "\n"))
        return report.verdict == .fail ? 1 : 0
    }

    /// `--model claude-code:haiku`, `pi`, `pi:zai/glm-5`.
    static func portAgent(_ text: String) throws -> LabAgent {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        let harnessName = parts.first == "claude" ? "claude-code" : parts.first ?? ""
        guard let harness = LabHarness(rawValue: harnessName) else { throw Failure(message: "--model is claude-code[:MODEL] or pi[:MODEL], not \(text).") }
        let model = parts.count > 1 ? parts[1] : (harness == .claudeCode ? OutputTranslation.defaultAgent.model : "")
        return LabAgent(harness: harness, model: model, effort: harness.efforts.contains("low") ? "low" : harness.efforts[0], mode: .call)
    }

    /// A folder with a SKILL.md, else the one skill of that name (or folder name) Claude Code sees.
    static func portSource(_ text: String, env: HarnessEnvironment, cwd: URL, projectsRoot: URL) throws -> URL {
        let folder = resolve(text, cwd: cwd, env: env)
        if FileManager.default.fileExists(atPath: folder.appending(path: SkillPort.skillFile).path) { return folder }
        if text.contains("/") { throw Failure(message: "\(folder.path) has no \(SkillPort.skillFile).") }
        let skills = SkillScanner.scan(installations: HarnessCatalog.detectAll(in: env),
                                       extraProjects: ProjectFinder.projects(inRoots: [projectsRoot]), in: env)
            .filter { $0.visibleTo.contains(.claudeCode) && !$0.isSingleFile && ($0.name == text || $0.folder.lastPathComponent == text) }
        let global = skills.filter { $0.scope == .global }
        let picked = global.count == 1 ? global : skills
        guard let skill = picked.first else { throw Failure(message: "No skill named \(text) that Claude Code sees. Give its folder instead.") }
        if picked.count > 1 {
            let places = picked.map { FileWalk.tilde($0.folder, home: env.homeDirectory) }.joined(separator: ", ")
            throw Failure(message: "Several skills named \(text): \(places). Give the folder.")
        }
        return skill.realFolder
    }
}
