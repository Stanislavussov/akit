import AKitFoundation
import AKitBrain
import AKitErrorAnalysis
import AKitLab
import Foundation

/// `akit lab …`: measuring agent sessions (docs/design/lab.md).
extension AKitCLI {
    public static let labUsage = """
        akit lab — measure agent sessions (Claude Code); files in ~/.akit/lab

          akit lab analyze SESSION [--json]
                                          Calls, fresh tokens, context rent, tool errors, re-reads,
                                          rejected calls, interrupts, commits (and whether they reached
                                          the main branch) of one session. SESSION: a transcript path
                                          or a Claude Code session id

        Runs (one at a time; each opens a tab that runs `akit lab run ID`):
          akit lab new review SESSION [--harness claude-code|pi] [--model M] [--effort E]
                              [--mode call|agent] [--language en|ru|cs] [--env orca|herdr|background]
                              [--no-start]
                                          A model reads the session (masked) and AKit's numbers and
                                          writes one paragraph and up to 3 improvements. Opens where
                                          the session ran; --env overrides. It runs through Claude
                                          Code (default) or Pi, with their sign-in; model and effort
                                          default to the harness's settings (Pi: --effort is its
                                          thinking level). call (default): one model call on a
                                          digest, no tools; agent: an agent reads the whole
                                          transcript with file tools. --language: the language of the
                                          review (default: Lab settings in AKit, else English)
          akit lab new replay COMMIT [--repo DIR] [--setups full,lean] [--model M] [--effort E]
                              [--repeats N] [--env orca|herdr|background] [--keep] [--no-start]
                                          Redo a commit from its parent in an isolated clone (no refs,
                                          no remote, not the answer), headless; then the commit's own
                                          tests judge it. N (3) repeats of each setup. full = your
                                          setup, lean = --setting-sources project. Model and effort
                                          default to ~/.claude/settings.json (else opus, high).
                                          --keep keeps the clone; otherwise it goes to the Trash
          akit lab new analysis [--project ID|DIR] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--size N]
                              [--harness claude-code|pi] [--model M] [--effort E] [--matching-model M]
                              [--language en|ru|cs] [--env orca|herdr|background] [--no-start] [--yes]
                                          Error analysis over a sample of N (20) sessions of the index
                                          (5+ requests each): a random quarter, the rest stratified by
                                          cheap signals, harness and model. Per session notes, verifier
                                          and matching, 2 at a time; clustering at the end. Sends notes
                                          and transcripts under the sending policy. Shows how many
                                          sessions and the ≈ cost first; --yes queues it
          akit lab task COMMIT [--repo DIR]
                                          Check a commit as a task now: its tests on the parent and on
                                          the commit (fail-to-pass, pass-to-pass). A replay does this
                                          first when the task isn't checked yet
          akit lab compare COMMIT [--json]
                                          Replays of a commit per setup: passed, fresh tokens, calls,
                                          wall time (median and range)
          akit lab list [--json]          Runs, newest first, with status
          akit lab show ID [--json]       One run: state, metrics, test results, review
          akit lab start                  Start the next queued run, if none is running
          akit lab cancel ID              Stop a running run (its tab stays), or drop a queued one
          akit lab remove ID              Move a run's folder to the Trash
          akit lab run ID                 Do the run here (what the tab runs)

        Sending policy (every model call that sends session data or code; Settings → Lab):
          akit lab policy [--json]        This Mac's kind, allowed destinations, Pi accounts, scrub
                                          patterns and monthly limit
          akit lab policy check HARNESS [--model M]
                                          Who that harness sends to now (account check) and whether
                                          a Claude Code or Pi session may go there
          akit lab policy allow HARNESS PROVIDER ACCOUNT ORG
          akit lab policy remove HARNESS PROVIDER ACCOUNT ORG
                                          Add or remove an allowed destination
          akit lab policy pi-account PROVIDER ACCOUNT ORG
                                          The account behind a Pi provider (Pi has no whoami)
          akit lab policy limit DOLLARS|none
                                          Monthly limit on recorded cost
          akit lab sends [--json]         The send log: what went where, tokens, recorded cost
        """

    /// `akit` itself, for the tab command: `<akit> lab run ID`.
    static var ownExecutable: URL {
        Bundle.main.executableURL?.resolvingSymlinksInPath() ?? URL(filePath: CommandLine.arguments[0])
    }

    static func lab(_ arguments: [String], env: HarnessEnvironment, cwd: URL,
                    out: (String) -> Void, err: (String) -> Void, trash: (URL) throws -> URL?) async throws -> Int32 {
        var args = Arguments(arguments)
        if args.flag("--help") || args.flag("-h") || args.isEmpty {
            out(labUsage)
            return 0
        }
        let json = args.flag("--json")
        let noStart = args.flag("--no-start")
        let environmentText = args.value("--env")
        let repoText = args.value("--repo")
        let setupsText = args.value("--setups")
        let modelText = args.value("--model")
        let effortText = args.value("--effort")
        let harnessText = args.value("--harness")
        let modeText = args.value("--mode")
        let languageText = args.value("--language")
        let repeatsText = args.value("--repeats")
        let keep = args.flag("--keep")
        let command = args.positional()
        let repo = repoText.map { resolve($0, cwd: cwd, env: env) } ?? cwd
        switch command {
        case "analyze":
            guard let session = args.positional() else { throw Failure(message: "Which session? akit lab analyze SESSION.") }
            try args.finish()
            let file = try transcript(session, cwd: cwd, env: env)
            let metrics: SessionMetrics
            do {
                metrics = try await LabAnalysis.analyze(file: file, env: env)
            } catch {
                throw Failure(message: "Couldn't read \(file.path): \(error.localizedDescription)")
            }
            out(json ? try labJSON(metrics) : ([file.path] + MetricsText.lines(metrics)).joined(separator: "\n"))
            return 0
        case "new" where args.peek == "analysis":
            _ = args.positional()
            let project = args.value("--project")
            let from = try args.value("--from").map { try day($0, "--from") }
            let to = try args.value("--to").map { try day($0, "--to").addingTimeInterval(86_399) }
            let size = try positiveNumber(args.value("--size"), "--size") ?? 20
            let matchingModel = args.value("--matching-model")
            let yes = args.flag("--yes")
            try args.finish()
            let environment = try labEnvironment(environmentText, env: env)
            // No --harness or --model: a reviewer of another family than the sessions', when allowed.
            var agent: LabAgent?
            if harnessText != nil || modelText != nil || effortText != nil {
                guard let harness = LabHarness(rawValue: harnessText ?? "claude-code") else { throw Failure(message: "--harness is claude-code or pi.") }
                var chosen = LabRuns.defaultAgent(harness, env: env)
                chosen.mode = .call
                if let modelText { chosen.model = modelText }
                if let effortText { chosen.effort = effortText }
                guard harness.efforts.contains(chosen.effort) else {
                    throw Failure(message: "--effort for \(harness.title) is one of \(harness.efforts.joined(separator: ", ")).")
                }
                agent = chosen
            }
            var matching = agent
            if let matchingModel {
                matching = matching ?? LabRuns.defaultAgent(.claudeCode, env: env)
                matching?.model = matchingModel
                matching?.mode = .call
            }
            let language = try languageText.map { text in
                guard let language = LabLanguage(rawValue: text) else { throw Failure(message: "--language is en, ru or cs.") }
                return language
            }
            let projectFilter = project.map { text -> String in
                text.contains("/") || text.hasPrefix("~") ? resolve(text, cwd: cwd, env: env).path : text
            }
            // Before any model work: how many sessions and what it would cost.
            let filter = Sampling.Filter(project: projectFilter, from: from, to: to)
            let estimateAgent = agent ?? { var claude = LabRuns.defaultAgent(.claudeCode, env: env); claude.mode = .call; return claude }()
            out(Batches.estimateText(sessions: Batches.sampleSize(filter: filter, size: size, env: env), agent: estimateAgent, env: env)
                + (agent == nil ? " (with your Claude Code model; the reviewer is picked when the sample is drawn)" : ""))
            guard yes else {
                out("Run it again with --yes to queue it.")
                return 0
            }
            let run: LabRun
            do {
                run = try await Batches.new(filter: filter, size: size, notesAgent: agent,
                                            matchingAgent: matching, language: language, environment: environment, akit: ownExecutable, env: env)
            } catch {
                throw Failure(message: error.localizedDescription)
            }
            let batch = BatchStore(env: env).load(run.id)
            out("Queued \(run.id): \(run.spec.title), notes by \(batch?.notesAgent.label ?? "?") (\(run.spec.environment.title)).")
            if !noStart { try await startNext(env: env, out: out) }
            return 0
        case "new" where args.peek == "replay":
            _ = args.positional()
            guard let commit = args.positional() else { throw Failure(message: "Which commit? akit lab new replay COMMIT.") }
            try args.finish()
            guard harnessText == nil, modeText == nil, languageText == nil else {
                throw Failure(message: "Replays run a Claude Code agent; --harness, --mode and --language are for reviews.")
            }
            let environment = try labEnvironment(environmentText, env: env)
            let defaults = LabRuns.defaultModelAndEffort(env: env)
            let effort = effortText ?? defaults.effort
            guard LabRuns.efforts.contains(effort) else { throw Failure(message: "--effort is one of \(LabRuns.efforts.joined(separator: ", ")).") }
            let names = try (setupsText ?? "full").split(separator: ",").map { name in
                guard let setup = LabSetup.Name(rawValue: String(name)) else { throw Failure(message: "--setups takes full and lean.") }
                return setup
            }
            let repeats = try positiveNumber(repeatsText, "--repeats") ?? 3
            let setups = names.map { LabSetup(name: $0, model: modelText ?? defaults.model, effort: effort) }
            let runs: [LabRun]
            do {
                runs = try await LabRuns.newReplays(commit: commit, repo: repo, setups: setups, repeats: repeats,
                                                    environment: environment, keep: keep, akit: ownExecutable, env: env)
            } catch {
                throw Failure(message: error.localizedDescription)
            }
            out("Queued \(runs.count) runs: \(repeats) × \(setups.map(\.label).joined(separator: ", ")) (\(runs[0].spec.environment.title)).")
            if !noStart { try await startNext(env: env, out: out) }
            return 0
        case "task":
            guard let commit = args.positional() else { throw Failure(message: "Which commit? akit lab task COMMIT.") }
            try args.finish()
            do {
                let draft = try await ReplayTasks.draft(commit: commit, repo: repo, env: env)
                let printer = LinePrinter.shared
                let task = try await ReplayTasks.validate(draft, env: env, out: { printer.print($0) })
                out(taskText(task))
            } catch {
                throw Failure(message: error.localizedDescription)
            }
            return 0
        case "compare":
            guard let commit = args.positional() else { throw Failure(message: "Which commit? akit lab compare COMMIT.") }
            try args.finish()
            let runs = LabStore.list(env: env)
            guard let full = runs.compactMap(\.spec.commit).first(where: { $0.hasPrefix(commit) }) else {
                throw Failure(message: "No replays of \(commit).")
            }
            let comparison = LabComparison.compare(commit: full, runs: runs)
            out(json ? try labJSON(comparison.rows.map(CompareJSON.init)) : comparison.text)
            return 0
        case "new":
            let kind = args.positional()
            guard kind == "review" else { throw Failure(message: "akit lab new review SESSION, or akit lab new replay COMMIT.") }
            guard let session = args.positional() else { throw Failure(message: "Which session? akit lab new review SESSION.") }
            try args.finish()
            let environment = try labEnvironment(environmentText, env: env)
            let file = try transcript(session, cwd: cwd, env: env)
            guard let harness = LabHarness(rawValue: harnessText ?? "claude-code") else {
                throw Failure(message: "--harness is claude-code or pi.")
            }
            var agent = LabRuns.defaultAgent(harness, env: env)
            if let modelText { agent.model = modelText }
            if let effortText { agent.effort = effortText }
            if let modeText {
                guard let mode = LabAgent.Mode(rawValue: modeText) else { throw Failure(message: "--mode is call or agent.") }
                agent.mode = mode
            }
            guard harness.efforts.contains(agent.effort) else {
                throw Failure(message: "--effort for \(harness.title) is one of \(harness.efforts.joined(separator: ", ")).")
            }
            guard harness == .pi || !agent.model.isEmpty else { throw Failure(message: "Which model? --model.") }
            let language = try languageText.map { text in
                guard let language = LabLanguage(rawValue: text) else { throw Failure(message: "--language is en, ru or cs.") }
                return language
            }
            let run = try await LabRuns.newReview(transcript: file, title: nil, agent: agent, language: language,
                                                  environment: environment, akit: ownExecutable, env: env)
            out("Queued \(run.id): \(run.spec.title) by \(agent.label) in \(run.spec.language?.name ?? "English") (\(run.spec.environment.title), \(run.spec.folder)).")
            if !noStart { try await startNext(env: env, out: out) }
            return 0
        case "list":
            try args.finish()
            let runs = LabStore.list(env: env)
            if json {
                out(try labJSON(runs.map(RunJSON.init)))
            } else {
                out(runs.isEmpty ? "No Lab runs." : runs.map(listLine).joined(separator: "\n"))
            }
            return 0
        case "show":
            let run = try labRun(args.positional(), env: env)
            try args.finish()
            out(json ? try labJSON(RunJSON(run)) : showText(run))
            return 0
        case "start":
            try args.finish()
            try await startNext(env: env, out: out)
            return 0
        case "cancel":
            let run = try labRun(args.positional(), env: env)
            try args.finish()
            let wasRunning = run.status == .running
            do {
                try await LabStore.cancel(run, env: env)
            } catch {
                throw Failure(message: error.localizedDescription)
            }
            out(wasRunning ? "Asked \(run.id) to stop; its tab shows when it has." : "Dropped \(run.id) from the queue.")
            return 0
        case "remove":
            let run = try labRun(args.positional(), env: env)
            try args.finish()
            do {
                try LabStore.remove(run, trash: trash)
            } catch {
                throw Failure(message: error.localizedDescription)
            }
            out("Moved \(run.folder.path) to the Trash.")
            return 0
        case "policy":
            return try await policy(&args, json: json, model: modelText, env: env, out: out)
        case "sends":
            try args.finish()
            let records = SendLog.records(env: env)
            if json {
                out(try labJSON(records))
            } else if records.isEmpty {
                out("Nothing sent yet.")
            } else {
                out(records.map(sendLine).joined(separator: "\n"))
                out(String(format: "This month: $%.2f recorded", SendLog.monthCost(records))
                    + (LabSettings.load(env: env).monthlyLimit.map { String(format: " of a $%.2f limit.", $0) } ?? "."))
            }
            return 0
        case "run":
            guard let id = args.positional() else { throw Failure(message: "Which run? akit lab run ID.") }
            try args.finish()
            // The worker prints from background threads, straight to the terminal that hosts it.
            return await LabWorker.run(id: id, env: env, execute: AnalysisRuns.execute, out: { LinePrinter.shared.print($0) })
        default:
            throw Failure(message: "Unknown “akit lab \(command ?? "")”. Run akit lab --help.")
        }
    }

    private static func policy(_ args: inout Arguments, json: Bool, model: String?, env: HarnessEnvironment,
                               out: (String) -> Void) async throws -> Int32 {
        var settings = LabSettings.load(env: env)
        func harness(_ text: String?) throws -> LabHarness {
            guard let text, let harness = LabHarness(rawValue: text) else { throw Failure(message: "HARNESS is claude-code or pi.") }
            return harness
        }
        func destination() throws -> SendDestination {
            let harness = try harness(args.positional())
            guard let provider = args.positional(), let account = args.positional(), let org = args.positional() else {
                throw Failure(message: "Give HARNESS PROVIDER ACCOUNT ORG.")
            }
            return SendDestination(harness: harness, provider: provider, account: account, org: org)
        }
        switch args.positional() {
        case nil:
            try args.finish()
            let isWork = MachineProfile.load(home: env.homeDirectory).isWork
            if json {
                out(try labJSON(settings))
                return 0
            }
            var lines = [isWork ? "Work Mac: session data goes only to the allowed list." :
                            "Personal Mac: the same origin, plus the allowed list."]
            lines.append("Allowed: " + (settings.allowedDestinations.isEmpty ? "none" : ""))
            lines += settings.allowedDestinations.map { "  \($0.label)" }
            lines.append("Pi accounts: " + (settings.piAccounts.isEmpty ? "none" : ""))
            lines += settings.piAccounts.map { "  \($0.provider): \($0.account) · \($0.org)" }
            lines.append("Scrub: e-mails \(settings.scrub.maskEmails ? "masked" : "kept"), \(settings.scrub.hosts.count) host patterns, "
                         + "\(settings.scrub.extra.count) other patterns (scrub v\(Scrubber.version))")
            lines.append("Monthly limit: " + (settings.monthlyLimit.map { String(format: "$%.2f", $0) } ?? "none"))
            out(lines.joined(separator: "\n"))
        case "check":
            var agent = LabRuns.defaultAgent(try harness(args.positional()), env: env)
            try args.finish()
            if let model { agent.model = model }
            let gate: SendGate
            do {
                gate = try await SendGate.open(agent: agent, env: env)
            } catch {
                throw Failure(message: error.localizedDescription)
            }
            out("\(agent.harness.title) sends to \(gate.destination.label).")
            for (name, origin) in [("A Claude Code session", SendOrigin.claudeSession),
                                   ("A Pi session through \(gate.destination.provider)", .piSession(providers: [gate.destination.provider]))] {
                let decision = gate.decide(origin)
                out("\(name): \(decision.allowed ? "allowed" : "refused"). \(decision.reason)")
            }
        case "allow":
            let entry = try destination()
            try args.finish()
            if !settings.allowedDestinations.contains(where: { $0.matches(entry) }) { settings.allowedDestinations.append(entry) }
            try settings.save(env: env)
            out("Allowed \(entry.label).")
        case "remove":
            let entry = try destination()
            try args.finish()
            let before = settings.allowedDestinations.count
            settings.allowedDestinations.removeAll { $0.matches(entry) }
            guard settings.allowedDestinations.count < before else { throw Failure(message: "\(entry.label) isn't on the list.") }
            try settings.save(env: env)
            out("Removed \(entry.label).")
        case "pi-account":
            guard let provider = args.positional(), let account = args.positional(), let org = args.positional() else {
                throw Failure(message: "Give PROVIDER ACCOUNT ORG.")
            }
            try args.finish()
            settings.piAccounts.removeAll { $0.provider.caseInsensitiveCompare(provider) == .orderedSame }
            settings.piAccounts.append(PiAccount(provider: provider, account: account, org: org))
            try settings.save(env: env)
            out("Pi \(provider): \(account) · \(org).")
        case "limit":
            guard let text = args.positional() else { throw Failure(message: "Give DOLLARS or none.") }
            try args.finish()
            if text == "none" {
                settings.monthlyLimit = nil
            } else {
                guard let value = Double(text), value >= 0 else { throw Failure(message: "The limit is a number of dollars, or none.") }
                settings.monthlyLimit = value
            }
            try settings.save(env: env)
            out("Monthly limit: " + (settings.monthlyLimit.map { String(format: "$%.2f", $0) } ?? "none") + ".")
        case let other:
            throw Failure(message: "Unknown “akit lab policy \(other ?? "")”. Run akit lab --help.")
        }
        return 0
    }

    private static func sendLine(_ record: SendRecord) -> String {
        let date = record.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        let cost = record.usage.cost.map { String(format: "$%.3f", $0) } ?? "no cost recorded"
        return "\(date)  \(record.purpose.padding(toLength: 9, withPad: " ", startingAt: 0))  \(record.harness.title) · \(record.provider) · "
            + "\(record.account) · \(record.model)  in \(record.usage.input) cached \(record.usage.cached) out \(record.usage.output)  \(cost)"
            + (record.session.map { "  \($0)" } ?? "")
    }

    static func startNext(env: HarnessEnvironment, out: (String) -> Void) async throws {
        do {
            if let run = try await LabQueue.startNext(env: env) {
                out("Started \(run.id) in \(run.spec.environment.title).")
            } else if LabStore.list(env: env).contains(where: { $0.status == .running }) {
                out("Another run is running; this one starts after it.")
            } else {
                out("Nothing queued.")
            }
        } catch {
            throw Failure(message: "The run didn't start: \(error.localizedDescription)")
        }
    }

    /// `2026-10-01` as the start of that day here.
    static func day(_ text: String, _ option: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: text) else { throw Failure(message: "\(option) is a day: YYYY-MM-DD.") }
        return date
    }

    static func labEnvironment(_ text: String?, env: HarnessEnvironment) throws -> LabEnvironment? {
        guard let text else { return nil }
        guard let environment = LabEnvironment(rawValue: text) else {
            throw Failure(message: "--env is orca, herdr or background.")
        }
        guard Launcher.available(env: env).contains(environment) else { throw Failure(message: "\(environment.title) is not installed.") }
        return environment
    }

    private static func labRun(_ id: String?, env: HarnessEnvironment) throws -> LabRun {
        guard let id else { throw Failure(message: "Which run? Give its id (akit lab list).") }
        guard let run = LabStore.load(id, env: env) else { throw Failure(message: "No Lab run \(id).") }
        return run
    }

    private static func listLine(_ run: LabRun) -> String {
        var line = "\(run.id)  \(run.status.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))  \(run.spec.title)"
        if let metrics = run.result?.metrics { line += "  · \(metrics.calls) calls, \(MetricsText.short(metrics.freshTokens)) fresh" }
        if let tests = run.result?.tests { line += "  · tests \(tests.status.rawValue)" }
        return line
    }

    private static func showText(_ run: LabRun) -> String {
        var lines = ["\(run.spec.title)", "Run      \(run.id) · \(run.spec.kind.rawValue) · \(run.status.rawValue)"
                     + (run.state?.phase.map { " (\($0.title))" } ?? ""),
                     "Opens in \(run.spec.environment.title) · \(run.spec.folder)",
                     "Folder   \(run.folder.path)"]
        if let agent = run.spec.agent { lines.append("Agent    \(agent.label)") }
        if let language = run.spec.language, language != .english { lines.append("Language \(language.name)") }
        if let message = run.message { lines.append("Message  \(message)") }
        if let result = run.result {
            if let metrics = result.metrics { lines += [""] + MetricsText.lines(metrics) }
            lines += LabWorker.resultLines(result)
        }
        if let summary = run.summary { lines += ["", summary.trimmingCharacters(in: .whitespacesAndNewlines)] }
        if let review = run.review {
            lines += ["", review.findings.isEmpty ? "Nothing worth changing." : "What to improve:"]
            for (index, finding) in review.findings.enumerated() {
                lines.append("\(index + 1). \(finding.title)")
                if let evidence = finding.evidence { lines.append("   Evidence: \(evidence)") }
                lines.append("   \(finding.detail)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func taskText(_ task: ReplayTask) -> String {
        var lines = ["Task \(task.shortCommit) “\(task.subject)” from \(String(task.base.prefix(7)))",
                     "Package  \(task.package.isEmpty ? "(root)" : task.package)",
                     "Tests    \(task.testFiles.joined(separator: ", "))",
                     "Fail-to-pass (\(task.failToPass.count)): \(task.failToPass.map(\.id).joined(separator: ", "))",
                     "Pass-to-pass (\(task.passToPass.count)): \(task.passToPass.map(\.id).joined(separator: ", "))"]
        lines += task.notes
        return lines.joined(separator: "\n")
    }

    struct CompareJSON: Encodable {
        struct Spread: Encodable {
            let median: Int, min: Int, max: Int
        }

        let setup: String
        let runs: Int, passed: Int, leaked: Int, pending: Int, stopped: Int
        let freshTokens: Spread?, calls: Spread?, wallSeconds: Spread?

        init(_ row: LabComparison.Row) {
            func spread(_ value: LabComparison.Spread?) -> Spread? { value.map { Spread(median: $0.median, min: $0.min, max: $0.max) } }
            setup = row.setup
            runs = row.runs
            passed = row.passed
            leaked = row.leaked
            pending = row.pending
            stopped = row.failed
            freshTokens = spread(row.freshTokens)
            calls = spread(row.calls)
            wallSeconds = spread(row.wallSeconds)
        }
    }

    /// A transcript path, or a Claude Code session id.
    static func transcript(_ argument: String, cwd: URL, env: HarnessEnvironment) throws -> URL {
        if argument.hasSuffix(".jsonl") || argument.contains("/") {
            let file = resolve(argument, cwd: cwd, env: env)
            guard FileManager.default.fileExists(atPath: file.path) else { throw Failure(message: "No file at \(file.path).") }
            return file
        }
        guard let file = LabPaths.transcript(sessionID: argument, env: env) else {
            throw Failure(message: "No Claude Code session \(argument) in \(LabPaths.claudeRoot(env: env).path)/projects.")
        }
        return file
    }

    static func labJSON<Value: Encodable>(_ value: Value) throws -> String {
        String(decoding: try LabStore.encoder.encode(value), as: UTF8.self)
    }

    /// A run as `--json` prints it.
    struct RunJSON: Encodable {
        let id: String
        let status: RunState.Status
        let message: String?
        let spec: RunSpec
        let state: RunState?
        let launch: LaunchInfo?
        let result: RunResult?
        let review: Review?

        init(_ run: LabRun) {
            id = run.id
            status = run.status
            message = run.message
            spec = run.spec
            state = run.state
            launch = run.launch
            result = run.result
            review = run.review
        }
    }
}

/// Standard output for the worker, which prints from background threads.
final class LinePrinter: @unchecked Sendable {
    static let shared = LinePrinter()
    private let lock = NSLock()

    func print(_ line: String) {
        lock.withLock {
            Swift.print(line)
            fflush(stdout)
        }
    }
}
