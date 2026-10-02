import AKitFoundation
import AKitLab
import Foundation

/// `batches/<run-id>.json`: one error analysis batch run — its sample, the state of every
/// session in the pipeline, and what clustering made at the end.
public struct Batch: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending, running, done, error
        /// Its user turns and failed tool results alone pass the notes model's digest budget:
        /// never sent, and not retried, since no retry makes it fit.
        case tooLong = "too-long"
    }

    /// One session's way through notes → verifier → matching → checks.
    public struct Session: Codable, Hashable, Sendable {
        public var pick: Sampling.Pick
        public var status: Status
        /// Why it failed: invalid output is an error, never a skip.
        public var message: String?
        /// Steps done, in order: notes, verifier, matching, checks.
        public var steps: [String]

        public init(pick: Sampling.Pick, status: Status = .pending, message: String? = nil, steps: [String] = []) {
            self.pick = pick
            self.status = status
            self.message = message
            self.steps = steps
        }
    }

    public var schema = 1
    public var runID: String
    public var createdAt: Date
    public var filter: Sampling.Filter
    /// How many sessions were asked for, and the seed of the sample.
    public var size: Int
    public var seed: UInt64
    /// Bootstrap: the user's labeled sessions, not a sample (inclusion 1).
    public var fixed: Bool
    public var notesAgent: LabAgent
    public var matchingAgent: LabAgent
    public var language: LabLanguage
    public var sessions: [Session]
    /// Accepted model notes picked for the precision spot check.
    public var spotCheck: [NoteRef]
    /// Candidate modes clustering made at the end.
    public var candidates: [String]
    /// Clustering ran (once, at the end, over everything done).
    public var clustered: Bool
    /// Asked to pause: the worker stops after the current calls.
    public var paused: Bool
    /// Sessions the end-of-batch work (checks, clustering, seed matches) has covered; a retry
    /// of failed sessions runs it again for the new ones.
    public var finishedSessions: [String]?
    /// "≈" cost when it was queued, from earlier batches' recorded cost per session.
    public var estimate: Double?
    /// Why the worker paused it on its own (an account that changed under it).
    public var pauseReason: String?
    /// Sessions of the filter left out of the population before sampling, because the
    /// automatic reviewer may not get them under the sending policy; nil when none were.
    public var leftOut: Int?
    /// The policy's reason for them.
    public var leftOutReason: String?

    public init(runID: String, createdAt: Date = .now, filter: Sampling.Filter, size: Int, seed: UInt64, fixed: Bool = false,
                notesAgent: LabAgent, matchingAgent: LabAgent, language: LabLanguage, sessions: [Session]) {
        self.runID = runID
        self.createdAt = createdAt
        self.filter = filter
        self.size = size
        self.seed = seed
        self.fixed = fixed
        self.notesAgent = notesAgent
        self.matchingAgent = matchingAgent
        self.language = language
        self.sessions = sessions
        spotCheck = []
        candidates = []
        clustered = false
        paused = false
    }

    /// Sessions done out of all: the report shows coverage k/N when some failed.
    public var coverage: (done: Int, total: Int) { (sessions.filter { $0.status == .done }.count, sessions.count) }

    /// Sessions too long for a digest: left out of the frequencies for good, apart from failures.
    public var tooLong: Int { sessions.filter { $0.status == .tooLong }.count }

    /// Sessions a Resume would still work on: pending, running or failed.
    public var hasOpenSessions: Bool { sessions.contains { $0.status != .done && $0.status != .tooLong } }

    /// Done sessions the end-of-batch work hasn't covered yet.
    public var unfinished: Bool {
        let finished = Set(finishedSessions ?? [])
        return sessions.contains { $0.status == .done && !finished.contains($0.pick.sessionKey) }
    }

    /// k/N per step, for the Lab screen.
    public func progress(of step: String) -> Int { sessions.filter { $0.steps.contains(step) }.count }
}

public struct BatchStore: Sendable {
    let paths: AnalysisPaths

    public init(env: HarnessEnvironment) { paths = AnalysisPaths(env: env) }

    public func load(_ runID: String) -> Batch? {
        (try? Data(contentsOf: paths.batch(runID))).flatMap { try? AnalysisJSON.decoder.decode(Batch.self, from: $0) }
    }

    public func save(_ batch: Batch) throws {
        try JSONFile.write(batch, to: paths.batch(batch.runID))
    }

    /// Changes a batch as it is on disk now, under its lock.
    @discardableResult
    public func update(_ runID: String, _ change: (inout Batch) throws -> Void) throws -> Batch {
        let url = paths.batch(runID)
        return try JSONFile.locked(url) {
            guard var batch = JSONFile.read(Batch.self, from: url) else { throw JSONFile.Failure(message: "No batch \(runID).") }
            try change(&batch)
            try AnalysisJSON.encoder.encode(batch).write(to: url, options: .atomic)
            return batch
        }
    }

    /// Every batch, newest first.
    public func all() -> [Batch] {
        FileWalk.children(of: paths.batches).filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? AnalysisJSON.decoder.decode(Batch.self, from: $0) } }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func latest() -> Batch? { all().first }
}
