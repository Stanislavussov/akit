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
          akit skills port --check-only PATH [--rule …] [--forbid X] [--rules FILE|PRESET] [--json]
                                          Check a Pi skill folder: leftovers and what Pi needs,
                                          and leftovers of your rules
          akit skills port SKILL --questions [--no-model] [--json]
                                          The choice points found in the skill (test framework,
                                          package manager, subagents, questions, state, handoffs,
                                          model hints), each with options and the recommended one.
                                          and the model's for any other technology,
                                          command, path or convention it finds
                                          (--no-model: only the catalog's)
          akit skills port presets        The rules presets (built-in: vitest-to-jest; saved ones in
                                          ~/.akit/port-presets)
          akit skills port presets save NAME FILE

        Extra rules for any port: --rule 'FROM => TO' or --rule 're:PATTERN => TO' (after the
        built-in replacements), --note TEXT (a hard requirement for the model), --forbid X (must
        not remain), --rules FILE|PRESET (one rule per line, also allow: RULE, answer: ID=OPTION,
        # comments). --change TEXT (repeatable): a change in plain words ("replace axios with
        fetch"); the model writes its rules and forbid checks. --answer ID=OPTION answers a
        question (ID=other:TEXT in your own words); an unanswered one takes its
        recommended option, and the report lists it as (default). Each FROM and forbidden token
        is a lint rule: its hits show as [your rule …] and go to the model's feedback round.

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
        let answers: [String: String]
        let defaulted: [String]
        let rules: String
    }

    static func skillPort(_ args: inout Arguments, json: Bool, yes: Bool, env: HarnessEnvironment, cwd: URL, projectsRoot: URL,
                          out: (String) -> Void, trash: (URL) throws -> URL?) async throws -> Int32 {
        if args.flag("--help") || args.flag("-h") || args.isEmpty {
            out(skillPortUsage)
            return 0
        }
        if args.peek == "presets" {
            _ = args.positional()
            return try portPresets(&args, env: env, cwd: cwd, out: out)
        }
        let noModel = args.flag("--no-model")
        let checkOnly = args.value("--check-only")
        let modelText = args.value("--model")
        let toText = args.value("--to")
        let ruleLines = args.values("--rule")
        let notes = args.values("--note")
        let forbids = args.values("--forbid")
        let rulesSource = args.value("--rules")
        let answerTexts = args.values("--answer")
        let questionsOnly = args.flag("--questions")
        let changes = args.values("--change")
        let skillText = args.positional()
        let projectText = toText == "project" ? args.positional() : nil
        try args.finish()

        // The extra rules: a preset or rules file, then --rule, --forbid and --note.
        var extra = SkillPortRules()
        do {
            if let rulesSource {
                let file = resolve(rulesSource, cwd: cwd, env: env)
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    extra = try SkillPortRules.parse(text)
                } else if let text = SkillPortRules.preset(rulesSource, env: env) {
                    extra = try SkillPortRules.parse(text)
                } else {
                    throw Failure(message: "--rules is a file or a preset; \(rulesSource) is neither (akit skills port presets).")
                }
            }
            extra = extra.merged(with: try SkillPortRules.parse(ruleLines.joined(separator: "\n")))
            extra.forbids += forbids
            extra.notes += notes
        } catch let failure as SkillPortRules.Failure {
            throw Failure(message: failure.message)
        }

        if let checkOnly {
            if skillText != nil || toText != nil || modelText != nil || noModel || yes || questionsOnly || !changes.isEmpty || !answerTexts.isEmpty {
                throw Failure(message: "--check-only PATH goes alone (with --rule, --forbid, --rules and --json).")
            }
            let folder = resolve(checkOnly, cwd: cwd, env: env)
            let report: SkillPortCheck.Report
            do { report = try SkillPortCheck.check(folder: folder, rules: extra) } catch { throw Failure(message: error.localizedDescription) }
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
        if noModel, !changes.isEmpty || answerTexts.contains(where: { $0.contains("=" + SkillPortQuestions.otherPrefix) }) {
            throw Failure(message: "--change and other: answers need the model, which turns them into rules: leave out --no-model.")
        }
        if yes, target == nil { throw Failure(message: "--yes writes the port: say where with --to global or --to project PATH.") }
        let source = try portSource(skillText, env: env, cwd: cwd, projectsRoot: projectsRoot)

        // Questions: the detectors' (and, asked for, the model's); answers from --answer, then the preset's.
        var draft: SkillPort.Draft
        do { draft = try SkillPort.port(folder: source, env: env) } catch { throw Failure(message: error.localizedDescription) }
        let catalog: SkillPortCatalog
        do { catalog = try SkillPortCatalog.load(env: env) } catch { throw Failure(message: error.localizedDescription) }
        var questions = SkillPortQuestions.analyze(draft.originals, skill: draft.name, catalog: catalog)
        let settings = noModel ? LabSettings() : try LabSettings.loadForSending(env: env)
        let agent = try modelText.map(portAgent) ?? SkillPortModel.agent(settings: settings, env: env)
        var gate: SendGate?
        func openGate() async throws -> SendGate {
            if let gate { return gate }
            do { gate = try await SkillPortModel.gate(agent: agent, env: env) } catch { throw Failure(message: error.localizedDescription) }
            return gate!
        }
        // The model's questions: on whenever a model is used, for whatever the catalog doesn't know.
        if !noModel {
            do {
                questions += try await SkillPortModel.suggestQuestions(draft, known: questions, agent: agent, gate: try await openGate(), env: env)
            } catch let failure as Failure { throw failure } catch { throw Failure(message: error.localizedDescription) }
        }
        if questionsOnly {
            if json {
                out(try labJSON(questions))
            } else if questions.isEmpty {
                out("No questions: the port needs no choice for \(draft.name).")
            } else {
                out(questions.map { question in
                    ([" \(question.id): \(question.question)"] + question.options.map {
                        "    \(question.id)=\($0.id)  \($0.title)\($0.id == question.recommended ? "  (recommended)" : "")"
                    }).joined(separator: "\n")
                }.joined(separator: "\n") + "\nAnswer with --answer ID=OPTION, or --answer ID=other:TEXT in your own words; an unanswered question takes its recommended option. --change TEXT adds a change of your own.")
            }
            return 0
        }
        var answers = extra.answers
        for text in answerTexts {
            let pair = text.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { throw Failure(message: "--answer is ID=OPTION, not \(text).") }
            answers[pair[0]] = pair[1]
        }
        answers = answers.filter { id, _ in questions.contains { $0.id == id } || answerTexts.contains { $0.hasPrefix(id + "=") } }
        let answered: (rules: SkillPortRules, chosen: [String: String], defaulted: [String], others: [String])
        do { answered = try SkillPortQuestions.rules(questions, answers: answers) } catch let failure as SkillPortRules.Failure {
            throw Failure(message: failure.message)
        }
        var all = answered.rules.merged(with: extra)
        var unchecked: [String] = []
        // "Other…" answers and free changes: the model writes their rules and forbid checks.
        let free = answered.others + changes
        if !free.isEmpty {
            do {
                let made = try await SkillPortModel.rules(forChanges: free, draft: draft, agent: agent, gate: try await openGate(), env: env)
                all = all.merged(with: made.rules)
                unchecked = made.unchecked
            } catch let failure as Failure { throw failure } catch { throw Failure(message: error.localizedDescription) }
        }
        all.answers = answered.chosen
        if !all.isEmpty {
            do { draft = try SkillPort.port(folder: source, env: env, rules: all) } catch { throw Failure(message: error.localizedDescription) }
        }
        let answerLines = questions.map { "\($0.id)=\(answered.chosen[$0.id] ?? "")\(answered.defaulted.contains($0.id) ? " (default)" : "")" }
        var report = SkillPortCheck.check(draft)
        var modelLabel: String?
        var rounds = 0
        if !noModel {
            let gate = try await openGate()
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
                                          trashed: trashed?.path, answers: answered.chosen, defaulted: answered.defaulted, rules: all.text)))
            return report.verdict == .fail ? 1 : 0
        }
        let home = env.homeDirectory
        var lines = ["Port \(draft.name) from \(FileWalk.tilde(source, home: home)) to Pi"
                     + (modelLabel.map { " (model: \($0), \(rounds) round\(rounds == 1 ? "" : "s"))" } ?? " (no model)")]
        if !answerLines.isEmpty { lines.append("Answers: \(answerLines.joined(separator: ", "))") }
        lines += unchecked.map { "Note: no check for “\($0)”: its rules have no replacement or forbidden token." }
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

    /// `akit skills port presets` lists the presets; `presets save NAME FILE` saves one.
    static func portPresets(_ args: inout Arguments, env: HarnessEnvironment, cwd: URL, out: (String) -> Void) throws -> Int32 {
        if args.peek == "save" {
            _ = args.positional()
            guard let name = args.positional(), let path = args.positional() else { throw Failure(message: "Use: akit skills port presets save NAME FILE") }
            try args.finish()
            let file = resolve(path, cwd: cwd, env: env)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw Failure(message: "Can't read \(file.path).") }
            do {
                let saved = try SkillPortRules.save(preset: name, text: text, env: env)
                out("Saved preset \(name): \(FileWalk.tilde(saved, home: env.homeDirectory))")
            } catch let failure as SkillPortRules.Failure { throw Failure(message: failure.message) }
            return 0
        }
        try args.finish()
        let saved = SkillPortRules.savedPresets(env: env)
        var lines = SkillPortRules.builtIns.keys.sorted().map { "\($0)  (built-in)" }
        lines += saved.keys.sorted().map { "\($0)  \(FileWalk.tilde(SkillPortRules.presetsFolder(env: env).appending(path: "\($0).rules"), home: env.homeDirectory))" }
        out(lines.joined(separator: "\n"))
        return 0
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
