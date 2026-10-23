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
        /// Asked when the estimate is over the cap: true goes on. nil = never ask, stop.
        public var confirmOverCap: (@Sendable (_ estimate: Double, _ cap: Int) async -> Bool)?
        /// Asked when the change has more changed lines than `max_changed_lines`: true goes on.
        /// nil = never ask, stop.
        public var confirmLarge: (@Sendable (_ lines: Int, _ limit: Int) async -> Bool)?
        public var timeout: TimeInterval
        public var progress: @Sendable (String) -> Void

        public init(confirmOverCap: (@Sendable (Double, Int) async -> Bool)? = nil, confirmLarge: (@Sendable (Int, Int) async -> Bool)? = nil,
                    timeout: TimeInterval = 30 * 60, progress: @escaping @Sendable (String) -> Void = { _ in }) {
            self.confirmOverCap = confirmOverCap
            self.confirmLarge = confirmLarge
            self.timeout = timeout
            self.progress = progress
        }
    }

    public static let tools = "read,grep,find,ls,akit_submit_findings,akit_report_context_gap"

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
            arguments += ["-e", "builtin:mcp", "-e", "builtin:codemode"]
            let patterns = setup.mode == "review" ? access.passPatterns : access.toolPatterns
            tools += ",codemode" + patterns.map { "," + $0 }.joined()
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
    static func runPass(_ setup: PassSetup, spec: ReviewRunSpec, folder: URL, log: inout ReviewPassLog, limit: Double, env: HarnessEnvironment,
                        options: Options, pi: URL) async throws -> PassOutput {
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
                                 environment: environment, timeout: options.timeout, stream: folder.appending(path: "passes/\(setup.name).jsonl"))
        ReviewMask.saved(in: folder)
        record.ended = .now
        record.session = output.session
        record.usage = output.usage
        record.credits = ReviewCredits.of(output.usage)
        record.paths = output.paths.map { relative($0, to: setup.cwd, run: folder) }
        record.error = output.error
        log.passes.append(record)
        try ReviewJSON.write(log, to: folder.appending(path: "passes.json"))
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
        _ = try await runPass(setup, spec: spec, folder: folder, log: &log, limit: Double(spec.capCredits.value), env: env, options: options, pi: pi)
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
        _ = try await runPass(setup, spec: spec, folder: folder, log: &log, limit: .infinity, env: env, options: options, pi: pi)
    }

    /// Runs every pass of a gathered run and writes `findings.json` and `gaps.json`.
    @discardableResult
    public static func run(folder: URL, env: HarnessEnvironment, options: Options = Options()) async throws -> ReviewFindingsFile {
        guard let spec = ReviewJSON.read(ReviewRunSpec.self, from: folder.appending(path: "run.json")), spec.headSHA != nil else {
            throw Failure(message: "\(folder.lastPathComponent) has no gathered run.json; gather it first.")
        }
        guard let pi = env.findExecutable("pi") else { throw Failure(message: "Pi (pi) is not installed.") }
        if let problem = spec.verifierProblem { throw Failure(message: problem) }
        let roles = spec.roles
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
        let estimate = ReviewCredits.estimate(contextCharacters: contextSize, systemCharacters: system.count, roles: roles.count + steps.count)
        try ReviewRuns.setStatus(.estimating, message: String(format: "≈ %.0f credits (cap %d)", estimate, spec.capCredits.value), folder: folder)
        // A change too big to review well: the passes ask first (`max_changed_lines`).
        let scan = ReviewJSON.read(ReviewScan.self, from: folder.appending(path: "scan.json"))
        if let scan, let limit = spec.maxChangedLines?.value, scan.changedLines > limit {
            guard let confirm = options.confirmLarge, await confirm(scan.changedLines, limit) else {
                let message = "Stopped before the passes: the change has \(scan.changedLines) changed lines, over the limit of \(limit). "
                    + "Reviews of big changes miss more: split it, or review it anyway."
                try ReviewRuns.setStatus(.stopped, message: message, folder: folder)
                throw Failure(message: message)
            }
        }
        // The fetch pass counts against the cap too.
        let previous = ReviewJSON.read(ReviewPassLog.self, from: folder.appending(path: "passes.json"))
        let fetched = previous?.passes.filter { $0.name == "fetch" } ?? []
        let spent = fetched.map(\.credits).reduce(0, +)
        // A confirmed estimate over the cap raises the run's limit to half again the estimate.
        var limit = Double(spec.capCredits.value)
        if estimate + spent > limit {
            guard let confirm = options.confirmOverCap, await confirm(estimate + spent, spec.capCredits.value) else {
                let message = String(format: "Stopped before the passes: the estimate is ≈ %.0f credits, over the cap of %d.", estimate + spent,
                                     spec.capCredits.value)
                try ReviewRuns.setStatus(.stopped, message: message, folder: folder)
                throw Failure(message: message)
            }
            limit = (estimate + spent) * 1.5
        }
        // The monthly limit (US dollars, Settings → Lab) counts review passes too.
        let records = SendLog.records(env: env)
        let dollars = SendLog.estimate(characters: contextSize * (roles.count + steps.count + 2), harness: .pi, model: spec.passes.value.model, records: records)
        try SendLog.checkLimit(estimate: dollars, settings: passesGate.settings, env: env)

        var log = ReviewPassLog(mainSession: UUID().uuidString.lowercased(), estimate: estimate)
        log.passes = fetched
        let logFile = folder.appending(path: "passes.json")
        try ReviewJSON.write(log, to: logFile)
        try ReviewRuns.setStatus(.passes, folder: folder)
        let skills = roles.flatMap { ["--skill", folder.appending(path: "roles/review-\($0.id)").path] }
        let roots = readRoots(folder: folder, worktree: hasWorktree ? worktree : nil)

        // A subagent step with its own model goes where that model goes: the policy checks it too.
        var stepGates: [String: SendGate] = [:]
        for step in steps where step.model.model != spec.passes.value.model && stepGates[step.model.model] == nil {
            stepGates[step.model.model] = step.model.model == spec.verifier.value.model ? verifierGate : try await gate(model: step.model.model, env: env)
        }

        func pass(_ name: String, role: ReviewRunSpec.Role?, prompt: String, model: ReviewModelChoice, gate: SendGate,
                  session: [String]) async throws -> PassOutput {
            var setup = PassSetup(name: name, mode: "review", role: role, prompt: prompt, model: model, gate: gate, session: session,
                                  skills: skills, tools: tools, mcp: spec.access.inPasses, cwd: cwd, systemPrompt: systemFile, roots: roots)
            setup.flags = spec.extraFlags
            return try await runPass(setup, spec: spec, folder: folder, log: &log, limit: limit, env: env, options: options, pi: pi)
        }

        do {
            let main = ["--session-id", log.mainSession]
            let brief = try await pass("brief", role: nil, prompt: ReviewPrompts.brief(spec: spec), model: spec.passes.value, gate: passesGate,
                                       session: main)
            log.brief = brief.answer.map(SecretFilter.masked)
            try ReviewJSON.write(log, to: logFile)
            for role in roles {
                let definition = try? String(contentsOf: folder.appending(path: "roles/review-\(role.id)/SKILL.md"), encoding: .utf8)
                _ = try await pass("role-\(role.id)", role: role,
                                   prompt: ReviewPrompts.role(role, body: definition.map(ReviewYAML.body) ?? "", spec: spec),
                                   model: spec.passes.value, gate: passesGate, session: main)
            }
            for step in steps {
                try write(step.instructions, to: folder.appending(path: "steps/\(step.id).md"))
                _ = try await pass("step-\(step.id)", role: step.role, prompt: ReviewPrompts.step(step, spec: spec), model: step.model,
                                   gate: stepGates[step.model.model] ?? passesGate, session: main)
            }
            var candidates = ReviewCandidates.collect(folder: folder, spec: spec, worktree: hasWorktree ? worktree : nil)
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
            if let scan, !scan.secrets.isEmpty {
                candidates = ReviewScan.addSecrets(scan, to: candidates, worktree: hasWorktree ? worktree : nil)
            }
            let findings = ReviewFindingsFile(version: 1, findings: candidates, source: "passes")
            try ReviewJSON.write(findings, to: folder.appending(path: "findings.json"))
            try mergeGaps(folder: folder)
            try await ReviewWorkflow.plan(folder, env: env)
            try ReviewRuns.setStatus(.planned, folder: folder)
            return findings
        } catch {
            try? mergeGaps(folder: folder)
            try? ReviewRuns.setStatus(error is CancellationError ? .stopped : .failed, message: error.localizedDescription, folder: folder)
            throw error
        }
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

    /// Gaps of Gather and of every pass, numbered again: `gaps.json`.
    static func mergeGaps(folder: URL) throws {
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
                // The same gap from two passes is one gap.
                if !gaps.contains(where: { $0.needed.lowercased() == gap.needed.lowercased() }) { gaps.append(gap) }
            }
        }
        for index in gaps.indices { gaps[index].id = "g\(index + 1)" }
        try ReviewJSON.write(gaps, to: folder.appending(path: "gaps.json"))
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
                      stream: URL) async -> PassOutput {
        try? FileManager.default.createDirectory(at: stream.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: stream.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: stream)
        let collector = Collector()
        let exit = await ChildProcess.run(pi, arguments: arguments, directory: directory, environment: environment, timeout: timeout) { line in
            collector.add(line)
            handle?.write(Data((ReviewMask.jsonLine(line) + "\n").utf8))
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
