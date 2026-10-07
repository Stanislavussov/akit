import AKitFoundation
import AKitModel
import Darwin
import Foundation

/// One run as read from its folder. Everything, the status too, is read once when loaded,
/// so two loads compare equal only when nothing changed (and views read no files).
public struct LabRun: Identifiable, Sendable, Hashable {
    public var id: String { spec.id }
    public let folder: URL
    public let spec: RunSpec
    public let state: RunState?
    public let launch: LaunchInfo?
    public let result: RunResult?
    /// The status to show: `running` only while its worker lives.
    public let status: RunState.Status
    /// The review agent's improvements (at most `Review.limit`); secrets masked.
    public let review: Review?
    /// The review agent's summary; secrets masked.
    public let summary: String?

    public init(folder: URL, spec: RunSpec, state: RunState?, launch: LaunchInfo?, result: RunResult?,
                review: Review? = nil, summary: String? = nil) {
        self.folder = folder
        self.spec = spec
        self.state = state
        self.launch = launch
        self.result = result
        self.review = review
        self.summary = summary
        if let state {
            status = state.status == .running && !LabStore.isAlive(state) ? .error : state.status
        } else {
            status = .queued
        }
    }

    /// Error text, including a worker that died without saying so.
    public var message: String? {
        if state?.status == .running, status == .error { return "The run stopped: its tab was closed or it crashed." }
        return state?.message
    }

    /// Running, or started in a tab within the last two minutes (a launch that never ran
    /// stops blocking the queue after that; the next start marks it as an error).
    public var isActive: Bool {
        status == .running
            || (status == .queued && launch.map { Date.now.timeIntervalSince($0.launchedAt) < LabQueue.startGrace } == true)
    }
}

/// Reads and writes run folders in `~/.akit/lab`.
public enum LabStore {
    /// Dates with milliseconds: runs queued together keep their order.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = JSONLines.date(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
            }
            return date
        }
        return decoder
    }()

    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// Creates the run folder with `run.json`; the run is queued.
    public static func create(_ spec: RunSpec, env: HarnessEnvironment) throws -> LabRun {
        let folder = LabPaths(env: env).run(spec.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(spec, to: folder.appending(path: "run.json"))
        return LabRun(folder: folder, spec: spec, state: nil, launch: nil, result: nil)
    }

    public static func load(_ id: String, env: HarnessEnvironment) -> LabRun? {
        load(folder: LabPaths(env: env).run(id))
    }

    static func load(folder: URL) -> LabRun? {
        guard let spec = read(RunSpec.self, from: folder.appending(path: "run.json")) else { return nil }
        let review = read(Review.self, from: folder.appending(path: "review.json")).map { review in
            Review(findings: review.findings.prefix(Review.limit).map(\.masked))
        }
        let summary = (try? String(contentsOf: folder.appending(path: "summary.md"), encoding: .utf8)).map(SecretFilter.masked)
        return LabRun(folder: folder, spec: spec,
                      state: read(RunState.self, from: folder.appending(path: "state.json")),
                      launch: read(LaunchInfo.self, from: folder.appending(path: "launch.json")),
                      result: read(RunResult.self, from: folder.appending(path: "result.json")),
                      review: review, summary: summary)
    }

    /// A review's numbers for the session it reviewed (`analysis.json`, Claude Code sessions).
    public static func reviewedMetrics(of run: LabRun) -> SessionMetrics? {
        read(SessionMetrics.self, from: run.folder.appending(path: "analysis.json"))
    }

    /// Every run, newest first.
    public static func list(env: HarnessEnvironment) -> [LabRun] {
        FileWalk.children(of: LabPaths(env: env).folder)
            .filter { $0.lastPathComponent != "tasks" }
            .compactMap { load(folder: $0) }
            .sorted { $0.spec.createdAt > $1.spec.createdAt }
    }

    /// Session ids of every run's own agent: Lab's sessions (replays, control cells, agent
    /// reviews) are evals, never production sessions.
    public static func sessionIDs(env: HarnessEnvironment) -> Set<String> {
        Set(list(env: env).map(\.spec.sessionID))
    }

    static func save(_ state: RunState, of id: String, env: HarnessEnvironment) throws {
        try write(state, to: LabPaths(env: env).run(id).appending(path: "state.json"))
    }

    static func save(_ launch: LaunchInfo, of id: String, env: HarnessEnvironment) throws {
        try write(launch, to: LabPaths(env: env).run(id).appending(path: "launch.json"))
    }

    static func save(_ result: RunResult, of id: String, env: HarnessEnvironment) throws {
        try write(result, to: LabPaths(env: env).run(id).appending(path: "result.json"))
    }

    /// The worker that wrote `state` still runs: its pid exists and started when the worker
    /// did (a pid reused by another process has another start time).
    static func isAlive(_ state: RunState) -> Bool {
        guard let pid = state.pid, pid > 0, let started = processStart(pid) else { return false }
        guard let recorded = state.pidStart else { return true }
        return abs(started - recorded) < 0.01
    }

    /// When a process of this user started, in seconds since 1970; nil when there is none.
    static func processStart(_ pid: Int32) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// A running run gets SIGTERM (its worker stops the agent and writes `cancelled`);
    /// a queued one is marked cancelled and never starts.
    /// Decided on the files as they are now, under the queue lock, so a worker that is just
    /// starting can't be missed.
    public static func cancel(_ run: LabRun, env: HarnessEnvironment) async throws {
        try await LabQueue.locked(env: env) {
            guard let current = load(run.id, env: env) else { throw Failure(message: "The run is gone.") }
            switch current.status {
            case .running:
                guard let state = current.state, let pid = state.pid, isAlive(state) else { return }
                kill(pid, SIGTERM)
            case .queued:
                try save(RunState(status: .cancelled, message: "Cancelled before it started."), of: run.id, env: env)
            default:
                throw Failure(message: "The run isn't running.")
            }
        }
    }

    /// Moves the run folder (and a kept clone in it) to the Trash.
    public static func remove(_ run: LabRun, trash: (URL) throws -> URL? = Trash.move) throws {
        guard run.status != .running else { throw Failure(message: "Cancel the run first.") }
        _ = try trash(run.folder)
    }
}

/// Queuing new runs.
public enum LabRuns {
    /// A review of a recorded session, opened where the session ran (or in the home folder
    /// when that is gone). `harness` recorded the session; nil = `LabPaths.harness(ofTranscript:)`.
    /// `environment` nil = suggested for that folder.
    /// The harnesses whose sessions a review can read: AKit's numbers (`analysis.json`) only
    /// for Claude Code, so a Pi session's review has the transcript alone.
    public static let reviewable: Set<HarnessID> = [.claudeCode, .pi]

    /// `agent` nil = Claude Code with your settings; `language` nil = the one in Lab settings.
    public static func newReview(transcript: URL, harness: HarnessID? = nil, title: String?, agent: LabAgent? = nil,
                                 language: LabLanguage? = nil, environment: LabEnvironment?, akit: URL,
                                 env: HarnessEnvironment) async throws -> LabRun {
        let ran = LabPaths.folder(ofTranscript: transcript)
        let folder = ran.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? env.homeDirectory
        let chosen: LabEnvironment
        if let environment {
            chosen = environment
        } else {
            chosen = await Launcher.suggested(for: folder, env: env)
        }
        let title = title ?? LabPaths.title(ofTranscript: transcript)
        let name = title.map { JSONLines.titleLine($0, limit: 60) } ?? transcript.deletingPathExtension().lastPathComponent
        var spec = RunSpec(id: RunSpec.newID(), kind: .review, title: "Review: \(name)", folder: folder.path,
                           environment: chosen, akit: akit.path, reviewedTranscript: transcript.path, reviewedTitle: title,
                           agent: agent, language: language ?? LabSettings.load(env: env).reportLanguage)
        spec.reviewedHarness = harness ?? LabPaths.harness(ofTranscript: transcript)
        return try LabStore.create(spec, env: env)
    }
}

extension LabRuns {
    /// Model and effort from `~/.claude/settings.json` (`model`, `effortLevel`), else opus and high.
    public static func defaultModelAndEffort(env: HarnessEnvironment) -> (model: String, effort: String) {
        let file = LabPaths.claudeRoot(env: env).appending(path: "settings.json")
        let settings = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let model = (settings["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "opus"
        let effort = (settings["effortLevel"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "high"
        return (model, effort)
    }

    public static let efforts = LabHarness.claudeCode.efforts

    /// The model and effort a harness uses by default: Claude Code's from
    /// `~/.claude/settings.json`; Pi's from `~/.pi/agent/settings.json` (`defaultProvider`,
    /// `defaultModel`, `defaultThinkingLevel`), else an empty model (Pi picks) and medium.
    public static func defaultAgent(_ harness: LabHarness, env: HarnessEnvironment) -> LabAgent {
        switch harness {
        case .claudeCode:
            let defaults = defaultModelAndEffort(env: env)
            return LabAgent(harness: .claudeCode, model: defaults.model, effort: defaults.effort)
        case .pi:
            let settings = (try? Data(contentsOf: piRoot(env: env).appending(path: "settings.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let provider = (settings["defaultProvider"] as? String) ?? ""
            let model = (settings["defaultModel"] as? String) ?? ""
            let effort = (settings["defaultThinkingLevel"] as? String).flatMap { LabHarness.pi.efforts.contains($0) ? $0 : nil }
            return LabAgent(harness: .pi, model: provider.isEmpty || model.isEmpty ? model : "\(provider)/\(model)",
                            effort: effort ?? "medium")
        }
    }

    /// Models to offer for a harness. Claude Code: its aliases. Pi: `pi --list-models`
    /// (the models it has credentials for) as `provider/model`.
    public static func models(for harness: LabHarness, env: HarnessEnvironment) async -> [String] {
        switch harness {
        case .claudeCode:
            return ["opus", "sonnet", "haiku"]
        case .pi:
            guard let pi = env.findExecutable("pi") else { return [] }
            guard let result = await ProcessRunner.run(pi, arguments: ["--list-models", "--offline"],
                                                       environment: env.variables.merging(["PATH": env.pathForChildProcesses, "NO_COLOR": "1"]) { $1 },
                                                       timeout: 30),
                  result.succeeded else { return [] }
            return piModels(result.output.split(whereSeparator: \.isNewline).map(String.init))
        }
    }

    /// The `provider model …` table of `pi --list-models`, as `provider/model`. Pi prints the
    /// table to stdout and stderr, which arrive together: header rows and repeats are skipped.
    static func piModels(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.compactMap { line in
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 2, columns[0] != "provider" else { return nil }
            let name = "\(columns[0])/\(columns[1])"
            return seen.insert(name).inserted ? name : nil
        }
    }

    /// Pi's config folder: `PI_CODING_AGENT_DIR`, else `~/.pi/agent`.
    public static func piRoot(env: HarnessEnvironment) -> URL {
        env.variables["PI_CODING_AGENT_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? env.homeDirectory.appending(path: ".pi/agent", directoryHint: .isDirectory)
    }

    /// Queues `repeats` runs of each setup, interleaved (1 of each, then 2 of each…) so a
    /// partly done comparison is still fair. The tab opens in `repo` (a worktree or the root);
    /// the work happens in an isolated clone inside the run folder.
    public static func newReplays(commit: String, repo: URL, setups: [LabSetup], repeats: Int, environment: LabEnvironment?,
                                  keep: Bool, akit: URL, env: HarnessEnvironment) async throws -> [LabRun] {
        guard !setups.isEmpty, repeats > 0 else { throw LabStore.Failure(message: "Pick at least one setup and one repeat.") }
        guard let root = await LabGit.output(["rev-parse", "--show-toplevel"], in: repo, env: env),
              let full = await LabGit.output(["rev-parse", "--verify", "--quiet", "\(commit)^{commit}"], in: repo, env: env) else {
            throw LabStore.Failure(message: "No commit \(commit) in \(repo.path).")
        }
        let folder = URL(filePath: root, directoryHint: .isDirectory)
        let chosen: LabEnvironment
        if let environment { chosen = environment } else { chosen = await Launcher.suggested(for: folder, env: env) }
        var runs: [LabRun] = []
        let start = Date.now
        for index in 1...repeats {
            for setup in setups {
                // Creation times one millisecond apart keep the queue in this order.
                let created = start.addingTimeInterval(Double(runs.count) / 1000)
                let spec = RunSpec(id: RunSpec.newID(at: created), kind: .replay,
                                   title: "Replay \(full.prefix(7)) · \(setup.label) · \(index)/\(repeats)",
                                   createdAt: created, folder: folder.path, environment: chosen, akit: akit.path,
                                   repo: folder.path, commit: full, setup: setup, repeatIndex: index, repeats: repeats, keep: keep)
                runs.append(try LabStore.create(spec, env: env))
            }
        }
        return runs
    }
}
