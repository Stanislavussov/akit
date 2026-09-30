import AKitFoundation
import Darwin
import Foundation

/// One run as read from its folder.
public struct LabRun: Identifiable, Sendable, Hashable {
    public var id: String { spec.id }
    public let folder: URL
    public let spec: RunSpec
    public let state: RunState?
    public let launch: LaunchInfo?
    public let result: RunResult?

    /// The status to show: `running` only while its worker lives.
    public var status: RunState.Status {
        guard let state else { return .queued }
        if state.status == .running, let pid = state.pid, !LabStore.isAlive(pid) { return .error }
        return state.status
    }

    /// Error text, including a worker that died without saying so.
    public var message: String? {
        if state?.status == .running, status == .error { return "The run stopped: its tab was closed or it crashed." }
        return state?.message
    }

    public var isActive: Bool { status == .running || (status == .queued && launch != nil) }

    /// The review agent's findings; secrets masked.
    public var review: Review? {
        guard let data = try? Data(contentsOf: folder.appending(path: "review.json")),
              var review = try? LabStore.decoder.decode(Review.self, from: data) else { return nil }
        review.findings = review.findings.map { .init(title: SecretFilter.masked($0.title), detail: SecretFilter.masked($0.detail)) }
        return review
    }

    /// The review agent's summary; secrets masked.
    public var summary: String? {
        (try? String(contentsOf: folder.appending(path: "summary.md"), encoding: .utf8)).map(SecretFilter.masked)
    }
}

/// Reads and writes run folders in `~/.akit/lab`.
public enum LabStore {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
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
        return LabRun(folder: folder, spec: spec,
                      state: read(RunState.self, from: folder.appending(path: "state.json")),
                      launch: read(LaunchInfo.self, from: folder.appending(path: "launch.json")),
                      result: read(RunResult.self, from: folder.appending(path: "result.json")))
    }

    /// Every run, newest first.
    public static func list(env: HarnessEnvironment) -> [LabRun] {
        FileWalk.children(of: LabPaths(env: env).folder)
            .filter { $0.lastPathComponent != "tasks" }
            .compactMap { load(folder: $0) }
            .sorted { $0.spec.createdAt > $1.spec.createdAt }
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

    public static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// A running run gets SIGTERM (its worker stops the agent and writes `cancelled`);
    /// a queued one is marked cancelled and never starts.
    public static func cancel(_ run: LabRun, env: HarnessEnvironment) throws {
        switch run.status {
        case .running:
            guard let pid = run.state?.pid else { return }
            kill(pid, SIGTERM)
        case .queued:
            try save(RunState(status: .cancelled, message: "Cancelled before it started."), of: run.id, env: env)
        default:
            throw Failure(message: "The run isn't running.")
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
    /// A review of a recorded Claude Code session, opened where the session ran (or in
    /// the home folder when that is gone). `environment` nil = suggested for that folder.
    public static func newReview(transcript: URL, title: String?, environment: LabEnvironment?, akit: URL,
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
        let spec = RunSpec(id: RunSpec.newID(), kind: .review, title: "Review: \(name)", folder: folder.path,
                           environment: chosen, akit: akit.path, reviewedTranscript: transcript.path, reviewedTitle: title)
        return try LabStore.create(spec, env: env)
    }
}
