import AKitBrain
import AKitCorrections
import AKitFoundation
import AKitInsights
import AKitProjectSetup
import Foundation

/// `akit corrections`: what the user corrects again and again, turned into rules with proof
/// (docs/design/corrections.md). Only `find --yes` calls a model.
extension AKitCLI {
    static let correctionsUsage = """
        Use: akit corrections [--days N] [--project ID|PATH] [--json]
             akit corrections find [--days N] [--project ID|PATH] [--model M] [--thinking T] [--show | --yes] [--json]
             akit corrections apply ID [--to global|PROJECT] [--yes]
             akit corrections dismiss ID
             akit corrections rules [--json]
             akit corrections remove ID [--yes]
        """

    static func corrections(_ args: inout Arguments, options: Options, env: HarnessEnvironment, cwd: URL, projectsRoot: URL,
                            hostName: String, installedTargets: [String], out: (String) -> Void) async throws -> Int32 {
        let daysText = args.value("--days"), projectArgument = args.value("--project"), to = args.value("--to")
        let model = args.value("--model"), thinking = args.value("--thinking"), show = args.flag("--show")
        let subcommand = args.positional()
        let id = ["apply", "dismiss", "remove"].contains(subcommand ?? "") ? args.positional() : nil
        try args.finish()
        guard subcommand == nil || ["find", "apply", "dismiss", "rules", "remove"].contains(subcommand!) else {
            throw Failure(message: "Unknown “akit corrections \(subcommand!)”.\n" + correctionsUsage)
        }
        let days = try positiveNumber(daysText, "--days") ?? Corrections.defaultDays
        let windowed = subcommand == nil || subcommand == "find"
        try refuse([(daysText != nil && !windowed, "--days"), (projectArgument != nil && !windowed, "--project"),
                    (to != nil && subcommand != "apply", "--to"), (model != nil && subcommand != "find", "--model"),
                    (thinking != nil && subcommand != "find", "--thinking"), (show && subcommand != "find", "--show"),
                    (show && options.yes, "--show and --yes; --show"),
                    (options.yes && !["find", "apply", "remove"].contains(subcommand ?? ""), "--yes"),
                    (options.json && !(windowed || subcommand == "rules"), "--json")], command: "corrections \(subcommand ?? "")")
        if ["apply", "dismiss", "remove"].contains(subcommand ?? ""), id == nil {
            throw Failure(message: "akit corrections \(subcommand!) needs a pattern or rule id (p-…).\n" + correctionsUsage)
        }
        func failure(_ error: Error) -> Failure { Failure(message: (error as? LocalizedError)?.errorDescription ?? "\(error)") }
        var project: String?
        if let projectArgument { project = await projectID(argument: projectArgument, cwd: cwd, projectsRoot: projectsRoot, env: env) }
        if windowed {
            let database = try IndexSchema.open(InsightsPaths(env: env).database)
            _ = try await QuickImport.run(env: env, projectsRoot: projectsRoot, database: database)
        }
        switch subcommand {
        case nil:
            let report = try Corrections.report(env: env, days: days, project: project)
            out(options.json ? encode(report) : report.text)
            return 0
        case "find":
            let report = try Corrections.report(env: env, days: days, project: project)
            let pick = CorrectionExcerpts.pick(report, env: env)
            if show {
                out(pick.input.isEmpty ? "Nothing to send." : pick.input)
                return 0
            }
            guard options.yes else {
                var lines = ["Find Pattern would send \(pick.excerpts.count) correction\(pick.excerpts.count == 1 ? "" : "s") from "
                             + "\(pick.sessions) session\(pick.sessions == 1 ? "" : "s") (≈ \(pick.approxTokens) tokens, the prompt not counted) "
                             + "to one model call, after the sending policy and the scrub."]
                if pick.cut > 0 { lines.append("\(pick.cut) more session\(pick.cut == 1 ? "" : "s") left out: the input's cap.") }
                if pick.sessions < 2 { lines.append("A pattern needs corrections in at least 2 sessions; there is nothing to send.") }
                else { lines.append("--show prints it (before the scrub); run again with --yes to send.") }
                out(lines.joined(separator: "\n"))
                return 0
            }
            let patterns: [CorrectionPattern]
            do { patterns = try await Corrections.find(pick, model: model ?? "", thinking: thinking ?? Corrections.defaultThinking, env: env) } catch {
                throw failure(error)
            }
            if options.json { out(encode(patterns)); return 0 }
            guard !patterns.isEmpty else {
                out("No correction repeats across sessions (or the patterns found were applied or dismissed before).")
                return 0
            }
            out(patterns.map(patternText).joined(separator: "\n\n"))
            return 0
        case "dismiss":
            var state: CorrectionsState
            do { state = try CorrectionsState.load(env: env) } catch { throw failure(error) }
            guard let pattern = state.pattern(id!) else { throw Failure(message: "No pattern \(id!). See akit corrections find.") }
            state.dismiss(pattern)
            do { try state.save(env: env) } catch { throw failure(error) }
            out("Dismissed \(pattern.id): it isn't shown again.")
            return 0
        case "rules":
            let verdicts: [CorrectionVerdict]
            do { verdicts = try Corrections.verdicts(env: env) } catch { throw failure(error) }
            if options.json { out(encode(verdicts)); return 0 }
            out(verdicts.isEmpty ? "No rules from corrections yet. Apply one with akit corrections apply ID."
                : verdicts.map(\.text).joined(separator: "\n\n"))
            return 0
        default:
            break
        }
        // apply and remove write files: the brain and the projects' folders.
        let root = brainRoot(options, cwd: cwd, env: env)
        let brain = Brain.load(from: root)
        let context = await skillContext(brainRoot: root, env: env, projectsRoot: projectsRoot, hostName: hostName, installedTargets: installedTargets)
        let rendered = InstructionEdit.renderedFiles(projects: context.projectFolders, store: context.store)
        var state: CorrectionsState
        do { state = try CorrectionsState.load(env: env) } catch { throw failure(error) }
        let plan: CorrectionRules.Plan
        if subcommand == "apply" {
            guard let pattern = state.pattern(id!) else { throw Failure(message: "No pattern \(id!). See akit corrections find.") }
            let target: CorrectionRules.Target
            switch to {
            case nil: target = CorrectionRules.proposedTarget(pattern, projectFolders: context.projectFolders)
            case CorrectionRules.globalTarget?: target = .global
            case let name?:
                let projectID = await projectID(argument: name, cwd: cwd, projectsRoot: projectsRoot, env: env)
                let named = resolve(name, cwd: cwd, env: env)
                guard let folder = FileWalk.isDirectory(named) ? named : context.projectFolders[projectID] else {
                    throw Failure(message: "No project \(name) on this Mac. Use --to global or a project id or folder.")
                }
                target = .project(id: projectID, folder: folder)
            }
            do { plan = try CorrectionRules.planApply(pattern, to: target, brain: brain, rendered: rendered, env: env) } catch { throw failure(error) }
            var lines = ["\(plan.shown):"] + TextDiff.unified(plan.lines) + plan.notes
            guard options.yes else {
                lines.append("Run again with --yes to write it\(to == nil ? " (--to global or --to PROJECT picks another target)" : "").")
                out(lines.joined(separator: "\n"))
                return 0
            }
            do { lines += try await CorrectionRules.apply(plan, pattern: pattern, brain: brain, context: context, env: env) } catch { throw failure(error) }
            lines.append("Marked for the verdict: akit corrections rules shows it after \(CorrectionVerdict.minAfter) sessions.")
            out(lines.joined(separator: "\n"))
            return 0
        }
        guard let rule = state.rules.first(where: { $0.id == id! && $0.removed == nil }) else {
            throw Failure(message: "No applied rule \(id!). See akit corrections rules.")
        }
        do { plan = try CorrectionRules.planRemove(rule, brain: brain, rendered: rendered, env: env) } catch { throw failure(error) }
        var lines = ["\(plan.shown):"] + TextDiff.unified(plan.lines)
        guard options.yes else {
            lines.append("Run again with --yes to take the rule out.")
            out(lines.joined(separator: "\n"))
            return 0
        }
        do { lines += try await CorrectionRules.remove(plan, brain: brain, context: context, env: env) } catch { throw failure(error) }
        out(lines.joined(separator: "\n"))
        return 0
    }

    static func patternText(_ pattern: CorrectionPattern) -> String {
        var lines = ["\(pattern.id)  \(pattern.title)",
                     "  \(pattern.sessions) sessions · scope: \(pattern.scope ?? "global")", "  You said:"]
        for reaction in pattern.reactions {
            let words = reaction.words.isEmpty ? "(no words)" : "“\(reaction.words.replacingOccurrences(of: "\n", with: " "))”"
            lines.append("    \(reaction.kind.title): \(words)")
        }
        lines.append("  Rule:")
        lines += CorrectionRules.bullet(pattern.rule).components(separatedBy: "\n").map { "    \($0)" }
        lines.append("  Apply: akit corrections apply \(pattern.id) · Dismiss: akit corrections dismiss \(pattern.id)")
        return lines.joined(separator: "\n")
    }
}
