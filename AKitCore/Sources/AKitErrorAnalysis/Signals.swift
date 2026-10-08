import AKitFoundation
import AKitInsights
import AKitLab
import AKitModel
import AKitSessions
import Foundation

/// Cheap signals per session, computed by code from the transcript and kept in the session
/// index. They stratify the batch sample; no model is called.
public enum SignalScanner {
    /// Bumped when the computation changes: every session is recomputed.
    /// 2 (2026-10-08): interrupts, rejections, tool errors and repeated calls by `FailureSignals`.
    public static let version = 2

    /// Interrupts, rejections, tool errors and repeated calls are `FailureSignals`, as in Lab.
    public static func signals(of items: [TranscriptItem]) -> SessionSignals {
        let facts = TranscriptFacts(items)
        let users = facts.userTurns
        let shared = FailureSignals(items)
        let pushbacks = users.filter { !FailureSignals.isInterrupt($0.text) && isPushback($0.text) }.count
        return SessionSignals(interrupts: shared.interrupts, pushbacks: pushbacks, rejected: shared.rejected, toolErrors: shared.toolErrors,
                              repeatedCalls: shared.repeatedCalls, unverifiedDone: unverifiedDone(facts), userTurns: users.count,
                              steps: items.count)
    }

    /// The final report claims the work is done, and nothing ran a test, build or check after
    /// the last edit.
    static func unverifiedDone(_ facts: TranscriptFacts) -> Bool {
        guard let report = facts.finalReport, TranscriptFacts.claimsDone(report.text) else { return false }
        guard let lastEdit = facts.calls.last(where: { facts.phases[$0.step] == .edit }) else { return false }
        return !facts.calls.contains { $0.step > lastEdit.step && facts.phases[$0.step] == .verify }
    }

    /// "no", "not that", "I asked for", a revert; the Russian forms the user writes too.
    static func isPushback(_ text: String) -> Bool {
        let start = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
        let patterns = [
            #"(?i)^(no|nope|wrong|stop|wait)\b"#,
            #"(?i)\b(not that|that'?s not|that is not what|not what i|i asked (for|you)|i said|i told you|don'?t do that|why did you|revert|undo (that|it|this)|roll ?back)\b"#,
            #"(?i)^нет\b|не то|я (же )?просил|я же сказал|откати|верни как было|зачем ты"#,
        ]
        return patterns.contains { start.range(of: $0, options: .regularExpression) != nil }
    }

    /// Recomputes the signals of every indexed session whose file changed since (or that has
    /// none yet, or whose signals an older version computed). Signals of an older version whose
    /// file is gone or can't be read are deleted: they would stratify by the old rules.
    /// Returns how many were computed and how many sessions the index has.
    @discardableResult
    public static func refresh(env: HarnessEnvironment, progress: (Int, Int) -> Void = { _, _ in }) throws -> (computed: Int, total: Int) {
        guard let database = try AnalysisIndex.open(env: env) else { return (0, 0) }
        let sessions = try AnalysisIndex.sessions(database)
        let stored = try AnalysisIndex.signals(database)
        var fresh: [String: StoredSignals] = [:]
        var stale = Set<String>()
        var computed = 0
        for (index, session) in sessions.enumerated() {
            progress(index, sessions.count)
            let outdated = stored[session.key].map { $0.version != version } ?? false
            guard let summary = IndexedSessions.summary(session) else {
                if outdated { stale.insert(session.key) }
                continue
            }
            let file = summary.file
            let info = JSONLines.fileInfo(file)
            let modified = info.modified.timeIntervalSince1970
            if let old = stored[session.key], old.version == version, old.fileSize == info.size, old.fileModified == modified { continue }
            guard let transcript = try? SessionReader.transcript(of: summary) else {
                if outdated { stale.insert(session.key) }
                continue
            }
            computed += 1
            fresh[session.key] = StoredSignals(signals: signals(of: transcript.items), fileSize: info.size, fileModified: modified,
                                               version: version)
            // Written in chunks so a long first run keeps what it has done.
            if fresh.count >= 50 {
                try AnalysisIndex.store(fresh, in: database)
                fresh = [:]
            }
        }
        try AnalysisIndex.store(fresh, in: database)
        if !stale.isEmpty { try AnalysisIndex.deleteSignals(stale, in: database) }
        return (computed, sessions.count)
    }
}

/// Indexed sessions as session summaries the readers understand.
public enum IndexedSessions {
    /// Index keys of the sessions Lab's own runs made: left out of samples, bootstrap picks and
    /// check rates, so evals never enter production frequencies.
    public static func labKeys(env: HarnessEnvironment) -> Set<String> {
        Set(LabStore.sessionIDs(env: env).flatMap { ["claude:\($0)", "pi:\($0)"] })
    }

    public static func summary(_ session: IndexedSession) -> SessionSummary? {
        guard let path = session.file else { return nil }
        let file = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let info = JSONLines.fileInfo(file)
        return SessionSummary(harness: SessionKey.harness(of: session.key), file: file, title: file.deletingPathExtension().lastPathComponent,
                              project: session.cwd.map { URL(filePath: $0, directoryHint: .isDirectory) }, started: session.started,
                              modified: info.modified, size: info.size)
    }
}
