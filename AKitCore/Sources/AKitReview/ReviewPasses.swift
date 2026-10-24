import AKitFoundation
import AKitLab
import AKitSessions
import Foundation

/// One pass as it ran (`<run>/passes.json`).
public struct ReviewPassRecord: Codable, Sendable, Hashable {
    /// `brief`, `role-<id>`, `verifier`.
    public var name: String
    public var role: String?
    public var model: String
    public var session: String?
    public var started: Date
    public var ended: Date?
    public var usage: SendUsage
    public var credits: Double
    /// Files the pass read, relative to its working folder or the run folder.
    public var paths: [String]
    public var error: String?

    public var succeeded: Bool { ended != nil && error == nil }
}

public struct ReviewPassLog: Codable, Sendable, Hashable {
    /// The Pi session of the brief and the role passes.
    public var mainSession: String
    /// The verifier's own session; Discuss in Pi… forks it.
    public var verifierSession: String?
    public var verifierSessionFile: String?
    public var estimate: Double?
    public var passes: [ReviewPassRecord] = []
    /// The brief's answer: intent, components, what people raised, AC, first gaps.
    public var brief: String?

    public var credits: Double { passes.map(\.credits).reduce(0, +) }
}

/// The findings of a run after the verifier (`<run>/findings.json`). Discuss in Pi… makes new
/// versions; the older ones stay as `findings-v<N>.json`.
public struct ReviewFindingsFile: Codable, Sendable, Hashable {
    public var version: Int
    public var created: Date
    public var findings: [ReviewFinding]
    /// Where this version came from: `passes`, or `discuss`.
    public var source: String
    /// Discuss in Pi… submissions already in a version (`passes/discuss-<time>.json`).
    public var appliedDiscuss: [String]?

    public init(version: Int, created: Date = .now, findings: [ReviewFinding], source: String) {
        self.version = version
        self.created = created
        self.findings = findings
        self.source = source
    }
}

/// Credits: AKit's unit for the per-run cap (R14). One credit is 1,000 tokens as Pi recorded
/// them (input, cache writes and output); a cached read counts one tenth. Recorded numbers
/// only, never a price (step 0 checks how this lines up with the Copilot plan).
public enum ReviewCredits {
    public static func of(_ usage: SendUsage) -> Double {
        Double(usage.input + usage.output) / 1000 + Double(usage.cached) / 10_000
    }

    /// Before the passes: the brief reads the pack once, each role pass resends the session
    /// (cached) and reads about half the pack again, the verifier's strong model reads it all
    /// uncached (another model, another cache). Tool calls resend the history: × 1.5.
    public static func estimate(contextCharacters: Int, systemCharacters: Int, roles: Int) -> Double {
        let pack = Double(contextCharacters) / 4
        let system = Double(systemCharacters) / 4
        let brief = pack + system + 1_000
        let role = (pack + system) * 0.1 + pack * 0.5 + 1_500
        let verifier = (pack + system) * 1.2 + 2_000
        return (brief + Double(roles) * role + verifier) * 1.5 / 1000
    }
}

/// Step 4 of a run: brief → roles → Pi steps in one Pi session (R6), then the verifier in a
/// session of its own.
public enum ReviewPasses {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public struct Options: Sendable {
        /// Told when the run goes over a limit (the credit cap, `max_changed_lines`): the review
        /// goes on, the user only learns it. Also a progress line.
        public var alert: (@Sendable (String) -> Void)?
        /// Asked when the merge request is a draft, its pipeline failed, or AKit already reviewed
        /// this commit (R27): true goes on. nil = never ask, stop.
        public var confirmConcerns: (@Sendable (_ concerns: [String]) async -> Bool)?
        public var timeout: TimeInterval
        public var progress: @Sendable (String) -> Void

        public init(alert: (@Sendable (String) -> Void)? = nil, confirmConcerns: (@Sendable ([String]) async -> Bool)? = nil,
                    timeout: TimeInterval = 30 * 60, progress: @escaping @Sendable (String) -> Void = { _ in }) {
            self.alert = alert
            self.confirmConcerns = confirmConcerns
            self.timeout = timeout
            self.progress = progress
        }

        /// Over a limit: a progress line and the alert.
        func over(_ message: String) {
            progress("Over a limit: " + message)
            alert?(message)
        }
    }

    public static let tools = "read,grep,find,ls,akit_submit_findings,akit_report_context_gap"

    /// Why a review may not be worth its credits now (R27): a draft, a pipeline that failed on
    /// the reviewed commit, or an earlier run of AKit with passes on the same commit. Triviality
    /// isn't judged. A local review has none of these.
    public static func concerns(folder: URL, spec: ReviewRunSpec, home: URL) -> [String] {
        guard spec.local == nil, let head = spec.headSHA else { return [] }
        var result: [String] = []
        if let mr = ReviewJSON.read(ReviewSnapshot.self, from: folder.appending(path: "gitlab/snapshot.json"))?.mergeRequest {
            if mr.draft == true { result.append("The merge request is a draft: its author may not be done.") }
            if let status = mr.pipelineStatus, ["failed", "canceled"].contains(status), mr.pipelineSHA == head {
                result.append("Its pipeline \(status == "failed" ? "failed" : "was canceled"): CI finds what it checks for less.")
            }
        }
        let earlier = ReviewRuns.list(home: home).filter { run in
            run.id != folder.lastPathComponent && run.spec.mergeRequest.url == spec.mergeRequest.url && run.spec.headSHA == head
                && FileManager.default.fileExists(atPath: ReviewPaths(home: home).run(run.id).appending(path: "findings.json").path)
        }
        if let last = earlier.first {
            result.append("AKit already reviewed this commit (\(head.prefix(10))) in run \(last.id).")
        }
        // R28: after three rounds another one rarely helps; the approach needs a talk.
        let round = ReviewRerun.round(folder: folder, spec: spec, home: home)
        if round > ReviewRerun.maxRounds {
            result.append("This is review round \(round) of this merge request: after \(ReviewRerun.maxRounds), talk with the author about the "
                          + "approach instead of another round.")
        }
        return result
    }

    /// What one Pi process of a run is: its mode for the extension and what it may reach.
    struct PassSetup: Sendable {
        var name: String
        var mode: String
        var role: ReviewRunSpec.Role?
        var prompt: String
        var model: ReviewModelChoice
        var gate: SendGate
        /// `--session-id …` or `--fork …`.
        var session: [String]
        var skills: [String]
        var tools: String
        /// Pi's MCP (with codemode) for this pass, limited to the run's servers.
        var mcp: Bool
        var cwd: URL
        var systemPrompt: URL?
        var roots: String
        /// The run's extra Pi flags (brief, roles, steps, verifier).
        var flags: [String] = []
    }

    /// The Pi arguments of a pass. Pi's own MCP support (`builtin:mcp`, with `builtin:codemode`
    /// to call the tools) loads the user's servers from Pi's `mcp.json`; nothing else of the
    /// user's Pi set-up is loaded (R2, R15).
    static func arguments(_ setup: PassSetup, folder: URL, access: ReviewMCPAccess) -> [String] {
        let sessions = folder.appending(path: "sessions")
        var arguments = ["-p", "--mode", "json"] + setup.session + ["--session-dir", sessions.path]
        if !setup.model.model.isEmpty { arguments += ["--model", setup.model.model] }
        if !setup.model.thinking.isEmpty { arguments += ["--thinking", setup.model.thinking] }
        arguments += ["--no-skills", "--no-context-files", "--no-prompt-templates", "--no-extensions", "--offline"]
        var tools = setup.tools
        if setup.mcp {
            // `tool_search` reaches a server with `deferred` exposure (a large one, such as GitLab's own
            // MCP server): its tools are in no tool list until a search loads them.
            arguments += ["-e", "builtin:mcp", "-e", "builtin:codemode", "-e", "builtin:tool-search"]
            let patterns = setup.mode == "review" ? access.passPatterns : access.toolPatterns
            tools += ",codemode,tool_search" + patterns.map { "," + $0 }.joined()
        } else {
            arguments += ["--no-mcp"]
        }
        arguments += setup.skills
        if let system = setup.systemPrompt { arguments += ["--append-system-prompt", system.path] }
        arguments += setup.flags
        arguments += ["-e", folder.appending(path: "akit-review.ts").path, "--tools", tools, "--", setup.prompt]
        return arguments
    }

    /// Runs one pass: checks the sending policy and the run's limit, starts Pi, records the pass
    /// in `passes.json` and the send log. Throws when the pass failed.
    /// `limit` stops a pass that would start over it (Sync Outcomes' own small one); `cap` only
    /// alerts once when the run's credits pass it: a review never stops at its cap.
    static func runPass(_ setup: PassSetup, spec: ReviewRunSpec, folder: URL, log: inout ReviewPassLog, limit: Double = .infinity,
                        cap: Double? = nil, env: HarnessEnvironment, options: Options, pi: URL) async throws -> PassOutput {
        guard log.credits < limit else {
            throw Failure(message: String(format: "Stopped before %@: %.0f credits used, the run's limit is %.0f.", setup.name, log.credits, limit))
        }
        options.progress("Pass \(setup.name)…")
        try setup.gate.check(.mergeRequest)
        try write(setup.prompt, to: folder.appending(path: "prompts/\(setup.name).md"))
        try write(ReviewExtension.source, to: folder.appending(path: "akit-review.ts"))
        try FileManager.default.createDirectory(at: folder.appending(path: "sessions"), withIntermediateDirectories: true)
        // The send pass gets only the run's own servers: context servers never reach it.
        let access = setup.mode == "send" ? spec.access.withoutExtras : spec.access
        var environment = passEnvironment(env)
        environment["AKIT_REVIEW_RUN"] = folder.path
        environment["AKIT_REVIEW_RUN_ID"] = spec.id
        environment["AKIT_REVIEW_MODE"] = setup.mode
        environment["AKIT_REVIEW_PASS"] = setup.name
        environment["AKIT_REVIEW_ROLE"] = setup.role?.id ?? ""
        environment["AKIT_REVIEW_MAX"] = String(setup.role?.maxFindings ?? 50)
        environment["AKIT_REVIEW_ROOTS"] = setup.roots
        environment["AKIT_REVIEW_MCP"] = String(decoding: (try? JSONEncoder().encode(access)) ?? Data("{}".utf8), as: UTF8.self)
        environment["AKIT_REVIEW_SCENARIO"] = spec.scenario.value
        environment["AKIT_REVIEW_HEAD"] = spec.headSHA ?? ""
        environment["AKIT_REVIEW_LINKS"] = String(decoding: (try? JSONEncoder().encode(spec.links ?? [])) ?? Data("[]".utf8), as: UTF8.self)
        var record = ReviewPassRecord(name: setup.name, role: setup.role?.id, model: setup.model.model, session: nil, started: .now, ended: nil,
                                      usage: SendUsage(), credits: 0, paths: [], error: nil)
        let output = await runPi(pi, arguments: arguments(setup, folder: folder, access: access), directory: setup.cwd,
                                 environment: environment, timeout: options.timeout, stream: folder.appending(path: "passes/\(setup.name).jsonl"),
                                 progress: { line in options.progress("  \(setup.name) · \(line)") })
        ReviewMask.saved(in: folder)
        record.ended = .now
        record.session = output.session
        record.usage = output.usage
        record.credits = ReviewCredits.of(output.usage)
        record.paths = output.paths.map { relative($0, to: setup.cwd, run: folder) }
        record.error = output.error
        options.progress(String(format: "Pass %@ %@: %.1f credits, %.0f s, %@ in / %@ cached / %@ out", setup.name,
                                output.error == nil ? "done" : "failed", record.credits, record.ended!.timeIntervalSince(record.started),
                                ReviewRunLog.tokens(output.usage.input), ReviewRunLog.tokens(output.usage.cached), ReviewRunLog.tokens(output.usage.output)))
        let before = log.credits
        log.passes.append(record)
        try ReviewJSON.write(log, to: folder.appending(path: "passes.json"))
        if let cap, before <= cap, log.credits > cap {
            options.over(String(format: "%.0f credits spent, over the cap of %.0f. The review goes on.", log.credits, cap))
        }
        let system = setup.systemPrompt.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        var send = SendRecord(purpose: "review-\(setup.name)", session: output.session, runID: spec.id, destination: setup.gate.destination,
                              model: setup.model.model, inputCharacters: setup.prompt.count, systemCharacters: system.count, usage: output.usage)
        send.paths = record.paths
        send.error = output.error
        _ = SendLog.appendAfterRun(send, env: env, out: options.progress)
        if let error = output.error { throw Failure(message: "Pass \(setup.name) failed: \(error)") }
        return output
    }

    /// The fetch pass (Gather, R3): Pi reads the merge request, its threads, the user's drafts
    /// and the work items through the user's MCP servers. The extension saves every answer in
    /// `<run>/mcp/calls/`; AKit reads them there. Its own session, so the review session
    /// starts clean.
    static func fetch(folder: URL, spec: ReviewRunSpec, env: HarnessEnvironment, options: Options) async throws {
        guard let pi = env.findExecutable("pi") else { throw Failure(message: "Pi (pi) is not installed.") }
        let gate = try await gate(model: spec.passes.value.model, env: env)
        var log = ReviewJSON.read(ReviewPassLog.self, from: folder.appending(path: "passes.json"))
            ?? ReviewPassLog(mainSession: UUID().uuidString.lowercased())
        log.passes.removeAll { $0.name == "fetch" }
        try? FileManager.default.removeItem(at: folder.appending(path: "mcp/calls"))
        try? FileManager.default.removeItem(at: folder.appending(path: "mcp/blocked.jsonl"))
        let cwd = folder.appending(path: "fetch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        // A local review's fetch pass reads only the links: there is no merge request.
        var tools = spec.local == nil ? "akit_submit_context,akit_report_context_gap" : "akit_report_context_gap"
        if !(spec.links ?? []).isEmpty { tools += ",akit_reading_link" }
        let setup = PassSetup(name: "fetch", mode: "fetch", role: nil, prompt: ReviewPrompts.fetch(spec: spec), model: spec.passes.value,
                              gate: gate, session: ["--session-id", UUID().uuidString.lowercased()], skills: [],
                              tools: tools, mcp: true, cwd: cwd, systemPrompt: nil, roots: "")
        _ = try await runPass(setup, spec: spec, folder: folder, log: &log, cap: Double(spec.capCredits.value), env: env, options: options, pi: pi)
    }

    /// Sync Outcomes (R31): a fetch-mode pass that reads only the merge request and its threads;
    /// its answers are saved as `mcp/calls/sync-*.json`, the run's earlier answers stay.
    static func sync(folder: URL, spec: ReviewRunSpec, env: HarnessEnvironment, options: Options) async throws {
        guard let pi = env.findExecutable("pi") else { throw Failure(message: "Pi (pi) is not installed.") }
        let gate = try await gate(model: spec.passes.value.model, env: env)
        var log = ReviewJSON.read(ReviewPassLog.self, from: folder.appending(path: "passes.json"))
            ?? ReviewPassLog(mainSession: UUID().uuidString.lowercased())
        for file in FileWalk.children(of: folder.appending(path: "mcp/calls")) where file.lastPathComponent.hasPrefix("sync-") {
            try? FileManager.default.removeItem(at: file)
        }
        let cwd = folder.appending(path: "fetch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        // GitLab only, as in Send Drafts. The run's cap doesn't stop a sync: it is one small pass.
        var syncSpec = spec
        syncSpec.mcp = spec.access.withoutExtras
        let name = "sync-\(log.passes.filter { $0.name.hasPrefix("sync") }.count + 1)"
        let setup = PassSetup(name: name, mode: "fetch", role: nil, prompt: ReviewPrompts.sync(spec: spec), model: spec.passes.value,
                              gate: gate, session: ["--session-id", UUID().uuidString.lowercased()], skills: [],
                              tools: "akit_report_context_gap", mcp: true, cwd: cwd, systemPrompt: nil, roots: "")
        _ = try await runPass(setup, spec: syncSpec, folder: folder, log: &log, limit: log.credits + 30, env: env, options: options, pi: pi)
    }

    /// The send pass (Send Drafts…, R4–R5): Pi writes the approved requests of
    /// `<run>/send/approved.json` as draft notes through the user's GitLab MCP server. The
    /// extension lets through only calls that carry an approved request word for word and logs
    /// each in `<run>/send/log.jsonl`.
    static func send(folder: URL, spec: ReviewRunSpec, count: Int, env: HarnessEnvironment, options: Options) async throws {
        guard let pi = env.findExecutable("pi") else { throw Failure(message: "Pi (pi) is not installed.") }
        let gate = try await gate(model: spec.passes.value.model, env: env)
        var log = ReviewJSON.read(ReviewPassLog.self, from: folder.appending(path: "passes.json"))
            ?? ReviewPassLog(mainSession: UUID().uuidString.lowercased())
        let cwd = folder.appending(path: "send", directoryHint: .isDirectory)
        let name = "send-\(log.passes.filter { $0.name.hasPrefix("send") }.count + 1)"
        let setup = PassSetup(name: name, mode: "send", role: nil, prompt: ReviewPrompts.send(spec: spec, count: count), model: spec.passes.value,
                              gate: gate, session: ["--session-id", UUID().uuidString.lowercased()], skills: [],
                              tools: "akit_approved_requests", mcp: true, cwd: cwd, systemPrompt: nil, roots: "")
        // Sending is never stopped by the run's credit cap: the user asked for it.
        _ = try await runPass(setup, spec: spec, folder: folder, log: &log, env: env, options: options, pi: pi)
    }

    /// Runs every pass of a gathered run and writes `findings.json` and `gaps.json`.
    @discardableResult
    public static func run(folder: URL, env: HarnessEnvironment, options: Options = Options()) async throws -> ReviewFindingsFile {
        guard var spec = ReviewJSON.read(ReviewRunSpec.self, from: folder.appending(path: "run.json")), spec.headSHA != nil else {
            throw Failure(message: "\(folder.lastPathComponent) has no gathered run.json; gather it first.")
        }
        guard let pi = env.findExecutable("pi") else { throw Failure(message: "Pi (pi) is not installed.") }
        if let problem = spec.verifierProblem { throw Failure(message: problem) }
        // A rerun needs the earlier run's findings (R28); without them (moved to the Trash) the
        // run reviews the whole merge request, so no earlier thread is taken for fixed.
        let previousFindings = spec.rerun.flatMap { rerun in
            ReviewJSON.read(ReviewFindingsFile.self, from: ReviewPaths(home: env.homeDirectory).run(rerun.previousRun).appending(path: "findings.json"))
        }
        if let rerun = spec.rerun, previousFindings == nil {
            spec.rerun = nil
            try ReviewJSON.write(spec, to: folder.appending(path: "run.json"))
            var gaps = ReviewJSON.read([ContextGap].self, from: folder.appending(path: "gaps.json")) ?? []
            gaps.append(ContextGap(id: "g\(gaps.count + 1)", system: "repository", needed: "The findings of the earlier run \(rerun.previousRun)",
                                   why: "They are gone, so this run reviews the whole merge request.", reportedBy: "gather"))
            try ReviewJSON.write(gaps, to: folder.appending(path: "gaps.json"))
            try? FileManager.default.removeItem(at: folder.appending(path: "context/since-last-review.md"))
        }
        // No work item (the branch names none): nothing to check requirements against, so the
        // review checks the code alone.
        if spec.workItems.isEmpty && spec.roles.contains(where: { $0.id == "requirements" }) {
            spec.roles.removeAll { $0.id == "requirements" }
            try ReviewJSON.write(spec, to: folder.appending(path: "run.json"))
            options.progress("No work item: the requirements role doesn't run.")
        }
        // R44 decides again on every run of the passes: the contracts role it added earlier goes,
        // with its definition when AKit wrote it.
        if spec.roles.contains(where: { $0.reason == contractsReason }) {
            let added = spec.roles.filter { $0.reason == contractsReason }
            spec.roles.removeAll { $0.reason == contractsReason }
            for role in added where !spec.roles.contains(where: { $0.id == role.id }) {
                let roleFolder = folder.appending(path: "roles/review-\(role.id)")
                if let text = try? String(contentsOf: roleFolder.appending(path: "SKILL.md"), encoding: .utf8), ReviewHash.sha256(text) == role.sha256 {
                    try? FileManager.default.removeItem(at: roleFolder)
                }
            }
            try ReviewJSON.write(spec, to: folder.appending(path: "run.json"))
        }
        var roles = spec.roles
        // Every send checks the policy first: a merge request goes only to a destination on
        // the allowed list (a work Mac's list is the company's).
        let passesGate = try await gate(model: spec.passes.value.model, env: env)
        let verifierGate = spec.verifier.value.model == spec.passes.value.model ? passesGate
            : try await gate(model: spec.verifier.value.model, env: env)

        let context = folder.appending(path: "context")
        let worktree = folder.appending(path: "worktree")
        let hasWorktree = FileManager.default.fileExists(atPath: worktree.appending(path: ".git").path)
        let cwd = hasWorktree ? worktree : folder
        let system = ReviewPrompts.system(spec: spec, hasWorktree: hasWorktree)
        let systemFile = folder.appending(path: "prompts/system.md")
        try write(system, to: systemFile)

        let contextSize = directorySize(context)
        let steps = spec.steps ?? []
        // The impact pass may run (R42) and add the contracts role (R44): both count, so the cap and
        // the monthly limit are checked against the most the passes may cost.
        let mayImpact = spec.impactMode != .off && spec.access.inPasses && !ReviewConsumers.gitlabServers(folder: folder, spec: spec).isEmpty
        let mayAddContracts = mayImpact && !roles.contains { $0.id == "contracts" } && !(spec.rolesOff ?? []).contains("contracts")
        let extraPasses = (mayImpact ? 1 : 0) + (mayAddContracts ? 1 : 0)
        let estimate = ReviewCredits.estimate(contextCharacters: contextSize, systemCharacters: system.count,
                                              roles: roles.count + steps.count + extraPasses)
        try ReviewRuns.setStatus(.estimating, message: String(format: "≈ %.0f credits (cap %d)", estimate, spec.capCredits.value), folder: folder)
        // A change too big to review well: the passes ask first (`max_changed_lines`).
        let scan = ReviewJSON.read(ReviewScan.self, from: folder.appending(path: "scan.json"))
        if let scan, let limit = spec.maxChangedLines?.value, scan.changedLines > limit {
            options.over("The change has \(scan.changedLines) changed lines, over max_changed_lines \(limit). The review goes on; "
                         + "reviews of big changes miss more.")
        }
        // Reasons not to review now (R27): one question for all of them.
        let concerns = Self.concerns(folder: folder, spec: spec, home: env.homeDirectory)
        if !concerns.isEmpty {
            guard let confirm = options.confirmConcerns, await confirm(concerns) else {
                let message = "Stopped before the passes: " + concerns.joined(separator: " ")
                try ReviewRuns.setStatus(.stopped, message: message, folder: folder)
                throw Failure(message: message)
            }
        }
        // The fetch pass counts against the cap too.
        let previous = ReviewJSON.read(ReviewPassLog.self, from: folder.appending(path: "passes.json"))
        let fetched = previous?.passes.filter { $0.name == "fetch" } ?? []
        let spent = fetched.map(\.credits).reduce(0, +)
        // Over the cap only alerts: the review goes on (the passes alert again when they pass it).
        let cap = Double(spec.capCredits.value)
        if estimate + spent > cap {
            options.over(String(format: "The estimate is ≈ %.0f credits, over the cap of %d. The review goes on.", estimate + spent,
                                spec.capCredits.value))
        }
        // The monthly limit (US dollars, Settings → Lab) counts review passes too.
        let records = SendLog.records(env: env)
        let dollars = SendLog.estimate(characters: contextSize * (roles.count + steps.count + extraPasses + 2), harness: .pi, model: spec.passes.value.model, records: records)
        try SendLog.checkLimit(estimate: dollars, settings: passesGate.settings, env: env)

        var log = ReviewPassLog(mainSession: UUID().uuidString.lowercased(), estimate: estimate)
        log.passes = fetched
        let logFile = folder.appending(path: "passes.json")
        try ReviewJSON.write(log, to: logFile)
        try ReviewRuns.setStatus(.passes, folder: folder)
        var skills = roles.flatMap { ["--skill", folder.appending(path: "roles/review-\($0.id)").path] }
        let roots = readRoots(folder: folder, worktree: hasWorktree ? worktree : nil)

        // A subagent step with its own model goes where that model goes: the policy checks it too.
        var stepGates: [String: SendGate] = [:]
        for step in steps where step.model.model != spec.passes.value.model && stepGates[step.model.model] == nil {
            stepGates[step.model.model] = step.model.model == spec.verifier.value.model ? verifierGate : try await gate(model: step.model.model, env: env)
        }

        func pass(_ name: String, role: ReviewRunSpec.Role?, prompt: String, model: ReviewModelChoice, gate: SendGate,
                  session: [String], tools: String = Self.tools) async throws -> PassOutput {
            var setup = PassSetup(name: name, mode: "review", role: role, prompt: prompt, model: model, gate: gate, session: session,
                                  skills: skills, tools: tools, mcp: spec.access.inPasses, cwd: cwd, systemPrompt: systemFile, roots: roots)
            setup.flags = spec.extraFlags
            return try await runPass(setup, spec: spec, folder: folder, log: &log, cap: cap, env: env, options: options, pi: pi)
        }

        do {
            let main = ["--session-id", log.mainSession]
            for path in ["passes/boundaries.json", "passes/overview.json", "overview.json"] {
                try? FileManager.default.removeItem(at: folder.appending(path: path))
            }
            let brief = try await pass("brief", role: nil, prompt: ReviewPrompts.brief(spec: spec), model: spec.passes.value, gate: passesGate,
                                       session: main, tools: tools + ",akit_submit_boundaries,akit_submit_overview")
            log.brief = brief.answer.map(SecretFilter.masked)
            try ReviewJSON.write(log, to: logFile)
            // The boundaries the brief named (R41): only those whose quote is in a changed file.
            let boundaries = ReviewBoundaries.check(folder: folder, worktree: hasWorktree ? worktree : nil)
            try ReviewJSON.write(boundaries, to: folder.appending(path: "boundaries.json"))
            options.progress("Boundaries: \(boundaries.count) kept.")
            // Other repositories (R42–R44): the impact pass, in the main session, before the roles.
            let consumers = try await impact(folder: folder, spec: spec, boundaries: boundaries, options: options) { name, prompt, tools in
                _ = try await pass(name, role: nil, prompt: prompt, model: spec.passes.value, gate: passesGate, session: main, tools: tools)
            }
            // The overview (R45–R47), after the impact pass so the flow shows the other repositories.
            // For the user only: a failure never fails the run.
            if let overview = ReviewOverview.check(folder: folder, spec: spec) {
                do {
                    try overview.save(in: folder)
                    options.progress("Overview: \(overview.points.count) points, \(overview.modules.count) modules"
                                     + (overview.flow == nil ? ", no flow." : ", a flow."))
                } catch {
                    options.progress("The overview failed: \(error.localizedDescription)")
                }
            } else {
                options.progress("Overview: the brief submitted none.")
            }
            // A use this change breaks is a contracts finding: that role runs whenever there are uses,
            // unless the user turned it off.
            if !consumers.isEmpty, !roles.contains(where: { $0.id == "contracts" }) {
                if (spec.rolesOff ?? []).contains("contracts") {
                    options.progress("Other repositories use the change, but the contracts role is off by the user's choice.")
                } else if let role = try addContractsRole(folder: folder, spec: &spec) {
                    roles.append(role)
                    skills += ["--skill", folder.appending(path: "roles/review-\(role.id)").path]
                    options.progress("Other repositories use the change: the contracts role runs too.")
                }
            }
            for role in roles {
                let definition = try? String(contentsOf: folder.appending(path: "roles/review-\(role.id)/SKILL.md"), encoding: .utf8)
                _ = try await pass("role-\(role.id)", role: role,
                                   prompt: ReviewPrompts.role(role, body: definition.map(ReviewYAML.body) ?? "", spec: spec,
                                                              consumers: !consumers.isEmpty),
                                   model: spec.passes.value, gate: passesGate, session: main)
            }
            for step in steps {
                try write(step.instructions, to: folder.appending(path: "steps/\(step.id).md"))
                _ = try await pass("step-\(step.id)", role: step.role, prompt: ReviewPrompts.step(step, spec: spec), model: step.model,
                                   gate: stepGates[step.model.model] ?? passesGate, session: main)
            }
            var candidates = ReviewCandidates.collect(folder: folder, spec: spec, worktree: hasWorktree ? worktree : nil)
            // A rerun (R28): the earlier findings on unchanged lines carry over; those whose code
            // changed go to the verifier again, which says whether they are fixed.
            var carried: [ReviewFinding] = []
            var earlierIDs: [String: String] = [:]
            if let rerun = spec.rerun, let previous = previousFindings {
                let split = ReviewRerun.split(previous.findings, rerun: rerun, candidates: candidates, worktree: hasWorktree ? worktree : nil)
                // A role that found an earlier problem again: it is the earlier finding, with all its fingerprints.
                for (index, prints) in split.refound {
                    candidates[index].carriedFrom = rerun.previousRun
                    let extra = prints.filter { !candidates[index].fingerprints.contains($0) }
                    if !extra.isEmpty { candidates[index].foldedFingerprints = (candidates[index].foldedFingerprints ?? []) + extra }
                }
                for var finding in split.recheck {
                    finding.id = "f\(candidates.count + 1)"
                    candidates.append(finding)
                }
                carried = split.carried
                earlierIDs = split.earlierIDs
                // What the earlier rerun kept stays kept: the chain of runs never loses a thread.
                let earlierKept = ReviewJSON.read([String].self, from: ReviewPaths(home: env.homeDirectory).run(rerun.previousRun)
                    .appending(path: "rerun-kept.json")) ?? []
                try ReviewJSON.write(split.kept.union(earlierKept).sorted(), to: folder.appending(path: "rerun-kept.json"))
            }
            try ReviewJSON.write(candidates, to: folder.appending(path: "candidates.json"))
            if !candidates.isEmpty {
                let input = ReviewCandidates.verifierInput(candidates, worktree: hasWorktree ? worktree : nil)
                try write(input, to: folder.appending(path: "prompts/candidates.md"))
                // A session of its own: the verifier doesn't inherit the roles' reasoning.
                let verified = try await pass("verifier", role: nil, prompt: ReviewPrompts.verifier(candidates: input, brief: log.brief, spec: spec),
                                              model: spec.verifier.value, gate: verifierGate,
                                              session: ["--session-id", UUID().uuidString.lowercased()])
                log.verifierSession = verified.session
                log.verifierSessionFile = verified.session.flatMap { sessionFile(id: $0, in: folder.appending(path: "sessions")) }?.path
                try ReviewJSON.write(log, to: logFile)
                candidates = ReviewCandidates.apply(verdictsFile: folder.appending(path: "passes/verifier.json"), to: candidates)
            }
            for var finding in carried {
                finding.id = "f\(candidates.count + 1)"
                candidates.append(finding)
            }
            // What the user moved inline in the earlier run stays inline (its draft stays).
            if let rerun = spec.rerun {
                let paths = ReviewPaths(home: env.homeDirectory)
                let earlierForced = Set(ReviewJSON.read([String].self, from: paths.run(rerun.previousRun).appending(path: "forced-inline.json")) ?? [])
                let forced = candidates.filter { finding in earlierIDs[finding.fingerprint ?? ""].map(earlierForced.contains) == true }.map(\.id)
                if !forced.isEmpty {
                    let file = folder.appending(path: "forced-inline.json")
                    let own = ReviewJSON.read([String].self, from: file) ?? []
                    try ReviewJSON.write(own + forced.filter { !own.contains($0) }, to: file)
                }
            }
            if let scan, !scan.secrets.isEmpty {
                candidates = ReviewScan.addSecrets(scan, to: candidates, worktree: hasWorktree ? worktree : nil)
            }
            let findings = ReviewFindingsFile(version: 1, findings: candidates, source: "passes")
            try ReviewJSON.write(findings, to: folder.appending(path: "findings.json"))
            try mergeGaps(folder: folder, codeOnly: spec.workItems.isEmpty)
            // The change map (R40) is for the user only: a failure never fails the run.
            do {
                // A map of an earlier run never stays when this one fails.
                try? FileManager.default.removeItem(at: folder.appending(path: "map.json"))
                try ReviewMap.make(folder: folder).save(in: folder)
            } catch {
                options.progress("The change map failed: \(error.localizedDescription)")
            }
            try await ReviewWorkflow.plan(folder, env: env)
            try ReviewRuns.setStatus(.planned, folder: folder)
            return findings
        } catch {
            try? mergeGaps(folder: folder, codeOnly: spec.workItems.isEmpty)
            try? ReviewRuns.setStatus(error is CancellationError ? .stopped : .failed, message: error.localizedDescription, folder: folder)
            throw error
        }
    }

    /// The impact pass (R42–R43) and AKit's check of it. It runs when `impact` is `always`, or
    /// `auto` and the brief kept a boundary, and the run has a GitLab server; needed without
    /// one, the run gets a gap instead. Writes `consumers.json` and `context/consumers.md` and
    /// returns the kept uses. A failed pass is a gap too: the review goes on with the uses it
    /// submitted before it failed.
    static func impact(folder: URL, spec: ReviewRunSpec, boundaries: [ReviewBoundary], options: Options,
                       run: (_ name: String, _ prompt: String, _ tools: String) async throws -> Void) async throws -> [ReviewConsumer] {
        // Nothing of an earlier run of the passes counts.
        for path in ["passes/consumers.json", "consumers.json", "context/consumers.md", "passes/gaps-impact.jsonl"] {
            try? FileManager.default.removeItem(at: folder.appending(path: path))
        }
        for file in FileWalk.children(of: folder.appending(path: "mcp/calls")) where file.lastPathComponent.hasPrefix("impact-") {
            try? FileManager.default.removeItem(at: file)
        }
        let mode = spec.impactMode
        guard mode == .always || (mode == .auto && !boundaries.isEmpty) else {
            if mode == .off { options.progress("Other repositories: impact is off.") }
            return []
        }
        func gap(_ needed: String, _ why: String, how: String) throws {
            let line = try JSONSerialization.data(withJSONObject: ["system": "gitlab", "needed": needed, "why": why, "howToGet": how,
                                                                   "effect": "Breaks in other repositories that use this change aren't checked.",
                                                                   "reportedBy": "impact"])
            // After the gaps the pass itself reported, never over them.
            let file = folder.appending(path: "passes/gaps-impact.jsonl")
            let earlier = (try? String(contentsOf: file, encoding: .utf8)).map { $0.isEmpty || $0.hasSuffix("\n") ? $0 : $0 + "\n" } ?? ""
            try write(earlier + String(decoding: line, as: UTF8.self) + "\n", to: file)
        }
        let what = boundaries.isEmpty ? "The uses of this change in other repositories"
            : "The uses of \(boundaries.count) boundar\(boundaries.count == 1 ? "y" : "ies") of this change in other repositories"
        let servers = ReviewConsumers.gitlabServers(folder: folder, spec: spec)
        guard spec.access.inPasses, !servers.isEmpty else {
            let why = spec.local != nil ? "A local review has no GitLab server: AKit didn't look in other repositories."
                : !spec.access.inPasses ? "MCP is off in the review passes (mcp: in_passes: false): AKit didn't look in other repositories."
                : "The run has no GitLab MCP server that read the merge request: AKit didn't look in other repositories."
            try gap(what, why, how: "Give Pi a GitLab MCP server (akit review check) and name it in the project profile (mcp: servers).")
            options.progress("Other repositories: skipped, no GitLab server.")
            return []
        }
        let tools = "read,grep,find,ls,akit_submit_consumers,akit_report_context_gap" + (boundaries.isEmpty ? ",akit_submit_boundaries" : "")
        do {
            try await run("impact", ReviewPrompts.impact(spec: spec, boundaries: boundaries, servers: servers), tools)
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            try gap(what, "The impact pass failed: \(SecretFilter.masked(error.localizedDescription))",
                    how: "Run the passes again (akit review passes RUN), or check the GitLab server in Pi.")
            // The uses it submitted before it failed are checked like any others.
            options.progress("Other repositories: the impact pass failed; the review goes on.")
        }
        // `always` with no boundary from the brief: the pass named them, checked like the brief's.
        var kept = boundaries
        if boundaries.isEmpty {
            let worktree = folder.appending(path: "worktree")
            kept = ReviewBoundaries.check(folder: folder, worktree: FileManager.default.fileExists(atPath: worktree.appending(path: ".git").path) ? worktree : nil)
            try ReviewJSON.write(kept, to: folder.appending(path: "boundaries.json"))
        }
        let usage = ReviewConsumers.usage(folder: folder)
        if usage.searches > ReviewConsumers.maxSearches {
            options.over("The impact pass made \(usage.searches) searches in GitLab, over its budget of \(ReviewConsumers.maxSearches). The review goes on.")
        }
        if usage.files > ReviewConsumers.maxFileReads {
            options.over("The impact pass read \(usage.files) files in GitLab, over its budget of \(ReviewConsumers.maxFileReads). The review goes on.")
        }
        let consumers = ReviewConsumers.check(folder: folder, spec: spec, boundaries: kept, servers: servers)
        try ReviewJSON.write(consumers, to: folder.appending(path: "consumers.json"))
        if !consumers.isEmpty {
            try write(ReviewConsumers.markdown(consumers, boundaries: kept), to: folder.appending(path: "context/consumers.md"))
        }
        let projects = Set(consumers.map(\.project)).count
        options.progress("Other repositories: \(consumers.count) use\(consumers.count == 1 ? "" : "s") kept in \(projects) project\(projects == 1 ? "" : "s").")
        return consumers
    }

    /// The reason in `run.json` of the contracts role R44 added.
    static let contractsReason = "added: other repositories use the change"

    /// R44: the built-in `contracts` role joins a run whose change other repositories use. Its
    /// definition goes where Gather puts the run's roles; the run's spec lists it.
    static func addContractsRole(folder: URL, spec: inout ReviewRunSpec) throws -> ReviewRunSpec.Role? {
        guard let text = ReviewBuiltIns.roleFiles["contracts"], let role = try? ReviewRole.parse(text, source: .builtIn) else { return nil }
        try write(role.text, to: folder.appending(path: "roles/\(role.skillName)/SKILL.md"))
        let added = ReviewRunSpec.Role(id: role.id, source: role.source, reason: contractsReason, minSeverity: role.minSeverity,
                                       maxFindings: role.maxFindings, needs: role.needs, doNotComment: role.doNotComment,
                                       sha256: ReviewHash.sha256(role.text))
        spec.roles.append(added)
        try ReviewJSON.write(spec, to: folder.appending(path: "run.json"))
        return added
    }

    /// The checked destination of a pass model: Pi with the model's provider, the account the
    /// user entered for it. Throws the policy's reason when a merge request may not go there.
    static func gate(model: String, env: HarnessEnvironment) async throws -> SendGate {
        let gate = try await SendGate.open(agent: LabAgent(harness: .pi, model: model, effort: ""), env: env)
        try gate.check(.mergeRequest)
        return gate
    }

    /// What a pass may read (`AKIT_REVIEW_ROOTS`): the worktree and the scrubbed parts of the run
    /// folder. Never `gitlab/` or `tracker/`: AKit's raw, unscrubbed copies (other drafts too).
    static func readRoots(folder: URL, worktree: URL?) -> String {
        ((worktree.map { [$0] } ?? []) + ["context", "roles", "prompts"].map { folder.appending(path: $0) })
            .map(\.path).joined(separator: ":")
    }

    /// The environment of a pass or a discussion: the user's, so Pi's MCP servers find the
    /// variables their `mcp.json` entries name (`${GITLAB_TOKEN}`). The model has no shell and no
    /// tool that reads the environment. Values of an earlier run's `AKIT_REVIEW_*` never leak in.
    static func passEnvironment(_ env: HarnessEnvironment) -> [String: String] {
        ChildProcess.harnessEnvironment(env).filter { key, _ in !key.uppercased().hasPrefix("AKIT_REVIEW") }
    }

    /// Gaps of Gather and of every pass, numbered again: `gaps.json`. A code-only run (no work
    /// item in the branch) drops the passes' gaps about a work item: the review didn't need one.
    static func mergeGaps(folder: URL, codeOnly: Bool = false) throws {
        var gaps = (ReviewJSON.read([ContextGap].self, from: folder.appending(path: "gaps.json")) ?? []).filter { $0.reportedBy == "gather" }
        for file in FileWalk.children(of: folder.appending(path: "passes")).sorted(by: { $0.path < $1.path })
        where file.lastPathComponent.hasPrefix("gaps-") && file.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: file) else { continue }
            for line in data.split(separator: 0x0A) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let needed = object["needed"] as? String, let why = object["why"] as? String else { continue }
                func text(_ key: String) -> String { SecretFilter.masked(object[key] as? String ?? "") }
                let gap = ContextGap(id: "", system: text("system"), needed: SecretFilter.masked(needed), why: SecretFilter.masked(why),
                                     howToGet: text("howToGet"), effect: text("effect"), reportedBy: text("reportedBy"))
                if codeOnly && isWorkItemGap(gap) { continue }
                // The same gap from two passes is one gap.
                if !gaps.contains(where: { $0.needed.lowercased() == gap.needed.lowercased() }) { gaps.append(gap) }
            }
        }
        for index in gaps.indices { gaps[index].id = "g\(index + 1)" }
        try ReviewJSON.write(gaps, to: folder.appending(path: "gaps.json"))
    }

    /// A gap that asks for the work item, its acceptance criteria or repro steps (English or Czech).
    static func isWorkItemGap(_ gap: ContextGap) -> Bool {
        if ["azure-devops", "tracker", "jira"].contains(gap.system.lowercased()) { return true }
        let text = (gap.needed + " " + gap.why).lowercased()
        return ["work item", "acceptance", "repro", "pracovní polož", "akceptační", "reprodukc", "zadání"].contains { text.contains($0) }
    }

    // MARK: - Pi

    struct PassOutput: Sendable {
        var session: String?
        var usage = SendUsage()
        var answer: String?
        var error: String?
        var paths: [String] = []
    }

    /// Runs one `pi -p --mode json` and reads its events: the session id, the recorded usage,
    /// the last answer, an error, and the paths of the read tools. The raw stream goes to `stream`.
    static func runPi(_ pi: URL, arguments: [String], directory: URL, environment: [String: String], timeout: TimeInterval,
                      stream: URL, progress: (@Sendable (String) -> Void)? = nil) async -> PassOutput {
        try? FileManager.default.createDirectory(at: stream.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: stream.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: stream)
        let collector = Collector()
        let exit = await ChildProcess.run(pi, arguments: arguments, directory: directory, environment: environment, timeout: timeout) { line in
            collector.add(line)
            handle?.write(Data((ReviewMask.jsonLine(line) + "\n").utf8))
            if let progress, let text = liveLine(line) { progress(text) }
        }
        try? handle?.close()
        var output = parse(collector.lines)
        if exit == nil { output.error = "Pi couldn't start." }
        else if exit?.cancelled == true { output.error = "Stopped." }
        else if exit?.timedOut == true { output.error = "The pass timed out." }
        else if exit?.succeeded != true, output.error == nil {
            let tail = collector.lines.filter { !$0.hasPrefix("{") }.suffix(5).joined(separator: " ")
            output.error = "Pi exited with status \(exit?.status ?? -1)" + (tail.isEmpty ? "." : ": \(SecretFilter.masked(String(tail.suffix(300))))")
        }
        return output
    }

    /// One Pi event as a line of the live log: what the pass does now. Tool names and file paths
    /// only, never MCP arguments or answers.
    static func liveLine(_ line: String) -> String? {
        // Only these events make a line: never parse the frequent, large message updates.
        guard line.hasPrefix("{"), line.contains("\"tool_execution_start\"") || line.contains("\"tool_execution_end\"")
                || line.contains("\"message_end\""),
              let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        switch event["type"] as? String {
        case "tool_execution_start":
            let name = event["toolName"] as? String ?? "?"
            let args = event["args"] as? [String: Any] ?? [:]
            switch name {
            case "read", "ls", "find", "grep":
                let target = (args["path"] as? String) ?? "."
                let pattern = (args["pattern"] as? String).map { " \"\(SecretFilter.masked(String($0.prefix(60))))\"" } ?? ""
                return "\(name) \(SecretFilter.masked(target))\(pattern)"
            case "codemode": return "runs a script that calls MCP tools"
            case "akit_submit_findings":
                let count = (args["findings"] as? [Any])?.count ?? 0
                let verdicts = (args["verdicts"] as? [Any])?.count ?? 0
                return verdicts > 0 ? "submits \(verdicts) verdicts" : "submits \(count) finding\(count == 1 ? "" : "s")"
            case "akit_submit_boundaries":
                let count = (args["boundaries"] as? [Any])?.count ?? 0
                return "submits \(count) boundar\(count == 1 ? "y" : "ies")"
            case "akit_submit_overview": return "submits the overview"
            case "akit_submit_consumers":
                let count = (args["consumers"] as? [Any])?.count ?? 0
                return "submits \(count) use\(count == 1 ? "" : "s") in other repositories"
            case "akit_report_context_gap": return "reports a context gap: " + SecretFilter.masked(String((args["needed"] as? String ?? "").prefix(80)))
            case "akit_submit_context": return "hands the merge request's data to AKit"
            case "akit_reading_link": return "reads a link"
            default:
                if name.hasPrefix("mcp__") {
                    let rest = name.dropFirst(5)
                    let parts = rest.components(separatedBy: "__")
                    return "MCP \(parts.first ?? ""): \(parts.dropFirst().joined(separator: "__"))"
                }
                return "tool \(name)"
            }
        case "tool_execution_end":
            guard event["isError"] as? Bool == true else { return nil }
            return "\(event["toolName"] as? String ?? "a tool") failed"
        case "message_end":
            guard let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" else { return nil }
            if message["stopReason"] as? String == "error" {
                return "model error: " + SecretFilter.masked(String((message["errorMessage"] as? String ?? "").prefix(200)))
            }
            let model = message["model"] as? String
            let usage = (message["usage"] as? [String: Any]).map { PiLogFormat.tokens(fromPiUsage: $0) }
            return "model answered" + (model.map { " (\($0))" } ?? "")
                + (usage.map { " · \(ReviewRunLog.tokens($0.input + $0.cacheWrite)) in, \(ReviewRunLog.tokens($0.cacheRead)) cached, \(ReviewRunLog.tokens($0.output)) out" } ?? "")
        default:
            return nil
        }
    }

    static func parse(_ lines: [String]) -> PassOutput {
        var output = PassOutput()
        for line in lines where line.hasPrefix("{") {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "session":
                output.session = output.session ?? event["id"] as? String
            case "tool_execution_start":
                let name = event["toolName"] as? String ?? ""
                if ["read", "grep", "find", "ls"].contains(name), let args = event["args"] as? [String: Any] {
                    output.paths.append(args["path"] as? String ?? ".")
                } else if name.hasPrefix("mcp__") {
                    // What a pass read through MCP, by tool (never the arguments).
                    output.paths.append("mcp:" + name)
                }
            case "message_end":
                guard let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" else { continue }
                if let usage = message["usage"] as? [String: Any] {
                    let tokens = PiLogFormat.tokens(fromPiUsage: usage)
                    output.usage = output.usage + SendUsage(input: tokens.input + tokens.cacheWrite, cached: tokens.cacheRead,
                                                            output: tokens.output, cost: PiLogFormat.cost(fromPiUsage: usage))
                }
                if message["stopReason"] as? String == "error" {
                    output.error = SecretFilter.masked(String((message["errorMessage"] as? String ?? "The model call failed.").prefix(300)))
                } else {
                    output.error = nil
                    let text = (message["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
                        .compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !text.isEmpty { output.answer = text }
                }
            default:
                break
            }
        }
        // Read twice is read once.
        var seen = Set<String>()
        output.paths = output.paths.filter { seen.insert($0).inserted }
        return output
    }

    /// Why a fetch pass read nothing, from its own records: the tools Pi called (from the pass's
    /// event stream), the calls AKit blocked, answers of servers the run doesn't use, the
    /// servers the run uses, and the pass's error. Names only, never arguments or answers.
    static func fetchDiagnosis(folder: URL, access: ReviewMCPAccess) -> String {
        var lines: [String] = []
        var tools: [String: Int] = [:]
        if let text = try? String(contentsOf: folder.appending(path: "passes/fetch.jsonl"), encoding: .utf8) {
            for line in text.split(separator: "\n") where line.contains("\"tool_execution_start\"") {
                guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let name = event["toolName"] as? String else { continue }
                tools[name, default: 0] += 1
            }
        }
        lines.append("Tools Pi called: " + (tools.isEmpty ? "none"
            : tools.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")) + ".")
        let blocked = ReviewRunLog.blocked(in: folder).filter { $0.pass == "fetch" }
        if !blocked.isEmpty {
            lines.append("Blocked by AKit: " + blocked.prefix(5).map { "\($0.tool) (\($0.reason))" }.joined(separator: "; ") + ".")
        }
        let others = Set(ReviewMCPData.calls(in: folder, pass: "fetch").filter { !access.answeredByBase($0) }
            .compactMap { $0.server ?? ReviewRunLog.server(of: $0.tool) }.filter { !$0.isEmpty })
        if !others.isEmpty {
            lines.append("Answers from servers this run doesn't use as GitLab or the tracker: \(others.sorted().joined(separator: ", ")). "
                         + "Name your GitLab server in the project profile (mcp: servers: [<name>]).")
        }
        lines.append("The run uses Pi servers matching: " + access.basePatterns.joined(separator: ", ") + ".")
        if let error = ReviewJSON.read(ReviewPassLog.self, from: folder.appending(path: "passes.json"))?.passes.last(where: { $0.name == "fetch" })?.error {
            lines.append("The pass said: \(SecretFilter.masked(String(error.prefix(300))))")
        }
        return "\n" + lines.joined(separator: "\n")
    }

    /// `<dir>/<time>_<id>.jsonl`.
    static func sessionFile(id: String, in folder: URL) -> URL? {
        FileWalk.children(of: folder).first { $0.lastPathComponent.hasSuffix("_\(id).jsonl") }
    }

    static func relative(_ path: String, to cwd: URL, run: URL) -> String {
        let absolute = path.hasPrefix("/") ? path : cwd.appending(path: path).standardizedFileURL.path
        if path.hasPrefix("mcp:") { return path }
        for root in [cwd.path, run.path] where absolute.hasPrefix(root + "/") { return String(absolute.dropFirst(root.count + 1)) }
        return absolute == cwd.path ? "." : absolute
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func directorySize(_ folder: URL) -> Int {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in walker { total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.withLock { stored.append(line) } }
        var lines: [String] { lock.withLock { stored } }
    }
}

extension SendUsage {
    static func + (a: SendUsage, b: SendUsage) -> SendUsage {
        SendUsage(input: a.input + b.input, cached: a.cached + b.cached, output: a.output + b.output,
                  cost: a.cost.map { $0 + (b.cost ?? 0) } ?? b.cost)
    }
}
