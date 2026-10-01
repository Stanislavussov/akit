import AKitFoundation
import AKitInsights
import AKitSessions
import Foundation

/// A pass/fail verdict per session for one mode (`docs/design/error-analysis.md`, "Checks").
public struct CheckVerdict: Codable, Hashable, Sendable {
    /// Code, or an LLM judge.
    public enum Checker: String, Codable, Sendable {
        case code, judge
    }

    /// The mode is present: the failure for a failure or efficiency mode, the strategy for a
    /// success mode.
    public var positive: Bool
    /// Where it shows.
    public var steps: [Int]
    public var detail: String?
    /// Borderline: left out of TPR/TNR until a human reviews it.
    public var toughCall: Bool
    public var severe: Bool
    public var by: Checker
    /// The check's version (code) or prompt version (judge) that decided it.
    public var version: Int
    /// The file state it was decided on: an unchanged file isn't checked again.
    public var fileSize: Int?
    public var fileModified: Double?

    public init(positive: Bool, steps: [Int] = [], detail: String? = nil, toughCall: Bool = false, severe: Bool = false,
                by: Checker = .code, version: Int, fileSize: Int? = nil, fileModified: Double? = nil) {
        self.positive = positive
        self.steps = steps
        self.detail = detail
        self.toughCall = toughCall
        self.severe = severe
        self.by = by
        self.version = version
        self.fileSize = fileSize
        self.fileModified = fileModified
    }
}

/// A check written in code.
public struct CodeCheck: Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The mode's definition is itself mechanical: the check is the definition, exact by
        /// construction (TPR = TNR = 1 against it), so no correction applies.
        case mechanical
        /// Approximates a mode that isn't mechanical: validated like a judge; until then the
        /// mode stays "seen in k notes".
        case heuristic
    }

    public let modeID: String
    public let kind: Kind
    public let version: Int
    /// What it looks for, in one sentence, for the mode's page.
    public let summary: String
    let evaluate: @Sendable (SessionTranscript) -> (positive: Bool, steps: [Int], detail: String?)

    public func check(_ transcript: SessionTranscript) -> CheckVerdict {
        let result = evaluate(transcript)
        return CheckVerdict(positive: result.positive, steps: result.steps, detail: result.detail, by: .code, version: version)
    }
}

/// The code checks AKit has, by mode id (the seeds' ids).
public enum CodeChecks {
    public static let all: [CodeCheck] = [largeFileReadWhole, repeatedSteps, overclaimingCompletion, weakeningTests, longSessionNotReset]

    public static func check(for modeID: String) -> CodeCheck? { all.first { $0.modeID == modeID } }

    /// Seed 9: a file over 20 KB read in full: Read without a range, or `cat` of the whole
    /// file. The size is the output's: what entered the context. Excluded when the same path
    /// is then written whole.
    static let largeFileReadWhole = CodeCheck(
        modeID: "large-file-read-whole", kind: .mechanical, version: 1,
        summary: "A Read without offset or limit, or a plain cat of one file, that returned more than 20 KB; not when the file is then written whole.") { transcript in
        let facts = TranscriptFacts(transcript.items)
        let limit = 20 * 1024
        var steps: [Int] = []
        var paths: [String] = []
        for call in facts.calls {
            guard let result = call.result, result.text.utf8.count > limit else { continue }
            if call.name == "Read" || call.name == "read" {
                guard call.input["offset"] == nil, call.input["limit"] == nil, let path = TranscriptFacts.path(call) else { continue }
                if !writtenWhole(path, after: call.step, facts) {
                    steps.append(call.step)
                    paths.append(path)
                }
            } else if let command = TranscriptFacts.command(call), let path = catFile(command), !writtenWhole(path, after: call.step, facts) {
                steps.append(call.step)
                paths.append(path)
            }
        }
        return (!steps.isEmpty, steps, steps.isEmpty ? nil : "\(steps.count) whole reads over 20 KB: \(paths.prefix(3).joined(separator: ", "))")
    }

    /// `cat path` alone (maybe `2>/dev/null`): a whole file into the context.
    static func catFile(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " 2>/dev/null", with: "")
        guard trimmed.hasPrefix("cat "), !trimmed.contains("|"), !trimmed.contains(">"), !trimmed.contains("<"),
              !trimmed.contains("&&"), !trimmed.contains(";") else { return nil }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, !parts[1].hasPrefix("-") else { return nil }
        return String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    static func writtenWhole(_ path: String, after step: Int, _ facts: TranscriptFacts) -> Bool {
        let name = (path as NSString).lastPathComponent
        return facts.calls.contains { call in
            guard call.step > step else { return false }
            if call.name == "Write" || call.name == "write" { return TranscriptFacts.path(call) == path }
            if let command = TranscriptFacts.command(call) {
                return command.contains("> \(path)") || command.contains(">\(path)") || command.contains("> \(name)")
            }
            return false
        }
    }

    /// Seed 7 (heuristic): the same call three or more times with the same result, so no new
    /// information came in between. Polling (sleep, watch, CI status) is left out.
    static let repeatedSteps = CodeCheck(
        modeID: "repeated-steps", kind: .heuristic, version: 1,
        summary: "The same tool call with the same result three or more times, except polling.") { transcript in
        let facts = TranscriptFacts(transcript.items)
        var counts: [String: Int] = [:]
        var steps: [Int] = []
        for call in facts.calls {
            if let command = TranscriptFacts.command(call),
               command.range(of: #"\b(sleep|watch|gh run|gh pr checks|status|poll|wait)\b"#, options: .regularExpression) != nil { continue }
            let key = call.name + "\u{1}" + call.text + "\u{1}" + (call.result?.text ?? "")
            counts[key, default: 0] += 1
            if counts[key] == 3 { steps.append(call.step) }
        }
        return (!steps.isEmpty, steps, steps.isEmpty ? nil : "\(steps.count) calls repeated 3+ times with the same result")
    }

    /// Seed 1 (heuristic): "done" with no check after the last edit, or after a tool error
    /// that the report doesn't mention.
    static let overclaimingCompletion = CodeCheck(
        modeID: "overclaiming-completion", kind: .heuristic, version: 1,
        summary: "The final report claims the work is done with no test or check after the last edit, or right after a tool error.") { transcript in
        let facts = TranscriptFacts(transcript.items)
        guard let report = facts.finalReport, TranscriptFacts.claimsDone(report.text) else { return (false, [], nil) }
        if SignalScanner.unverifiedDone(facts) { return (true, [report.id], "done with no check after the last edit") }
        let lastResult = transcript.items.last { item in
            guard item.id < report.id, case .toolResult = item.kind else { return false }
            return true
        }
        if let lastResult, case .toolResult(_, true) = lastResult.kind {
            return (true, [lastResult.id, report.id], "done right after a tool error")
        }
        return (false, [], nil)
    }

    /// Seed 5 (heuristic): test files edited so tests disappear or get skipped.
    static let weakeningTests = CodeCheck(
        modeID: "weakening-tests", kind: .heuristic, version: 1,
        summary: "An edit of a test file that removes tests or assertions or marks them skipped.") { transcript in
        let facts = TranscriptFacts(transcript.items)
        let markers = #"@Test|func test|\bit\(|\btest\(|assert|#expect|XCTAssert|expect\("#
        let skips = #"\.skip\(|@Disabled|XCTSkip|\.disabled\(|\bxit\(|pytest\.mark\.skip|\.only\("#
        func count(_ pattern: String, _ text: String) -> Int {
            (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
        }
        var steps: [Int] = []
        for call in facts.calls {
            guard let path = TranscriptFacts.path(call), isTestFile(path) else { continue }
            let old = (call.input["old_string"] as? String) ?? (call.input["oldText"] as? String) ?? ""
            let new = (call.input["new_string"] as? String) ?? (call.input["newText"] as? String) ?? (call.input["content"] as? String) ?? ""
            if (!old.isEmpty && count(markers, new) < count(markers, old)) || count(skips, new) > count(skips, old) {
                steps.append(call.step)
            }
        }
        return (!steps.isEmpty, steps, steps.isEmpty ? nil : "\(steps.count) edits of test files remove or skip tests")
    }

    static func isTestFile(_ path: String) -> Bool {
        path.range(of: #"(/Tests?/|/__tests__/|_test\.|\.test\.|\.spec\.|/test_[^/]*$|Tests\.swift$)"#, options: .regularExpression) != nil
    }

    /// Seed 8 (heuristic): committed work followed by a new request in the same context while
    /// the context is past half of a 200K window.
    static let longSessionNotReset = CodeCheck(
        modeID: "long-session-not-reset", kind: .heuristic, version: 1,
        summary: "A commit, then a new user request with 5+ more tool calls, in a session whose context passed 100K tokens.") { transcript in
        guard transcript.usage.peakContext >= 100_000 else { return (false, [], nil) }
        let facts = TranscriptFacts(transcript.items)
        guard let commit = facts.calls.first(where: { TranscriptFacts.command($0)?.contains("git commit") == true }) else {
            return (false, [], nil)
        }
        guard let request = facts.userTurns.first(where: { $0.id > commit.step }) else { return (false, [], nil) }
        let after = facts.calls.filter { $0.step > request.id }.count
        return after >= 5 ? (true, [request.id], "a new request after a commit at a peak context of \(transcript.usage.peakContext / 1000)K") : (false, [], nil)
    }
}

/// `checks/<mode-id>.json`: one mode's verdicts per session.
public struct CheckResults: Codable, Hashable, Sendable {
    public var modeID: String
    /// The mode version the verdicts were made for; a newer version needs a new run.
    public var modeVersion: Int?
    public var kind: CodeCheck.Kind?
    /// A judge's harness, model and prompt version; another one starts over.
    public var judge: String?
    public var verdicts: [String: CheckVerdict]

    public init(modeID: String, modeVersion: Int? = nil, kind: CodeCheck.Kind? = nil, verdicts: [String: CheckVerdict] = [:]) {
        self.modeID = modeID
        self.modeVersion = modeVersion
        self.kind = kind
        self.verdicts = verdicts
    }

    /// Positives of the given sessions (all when nil), with the 95% Wilson interval of the share.
    public func rate(over sessions: Set<String>? = nil) -> (positive: Int, total: Int, interval: Stats.Interval) {
        let counted = verdicts.filter { sessions?.contains($0.key) ?? true }
        let positive = counted.values.filter(\.positive).count
        return (positive, counted.count, Stats.wilson(positive, counted.count))
    }
}

public struct CheckStore: Sendable {
    let paths: AnalysisPaths

    public init(env: HarnessEnvironment) { paths = AnalysisPaths(env: env) }

    public func load(_ modeID: String) -> CheckResults? {
        (try? Data(contentsOf: paths.check(of: modeID))).flatMap { try? AnalysisJSON.decoder.decode(CheckResults.self, from: $0) }
    }

    public func save(_ results: CheckResults) throws {
        try FileManager.default.createDirectory(at: paths.checks, withIntermediateDirectories: true)
        try AnalysisJSON.encoder.encode(results).write(to: paths.check(of: results.modeID), options: .atomic)
    }
}

/// Runs code checks over every indexed session, locally; nothing is sent anywhere. A
/// session whose file and check version are unchanged keeps its verdict.
public enum CheckRunner {
    @discardableResult
    public static func run(_ checks: [CodeCheck], modeVersions: [String: Int] = [:], env: HarnessEnvironment,
                           progress: (Int, Int) -> Void = { _, _ in }) throws -> [CheckResults] {
        let store = CheckStore(env: env)
        var results = checks.map { check -> CheckResults in
            var loaded = store.load(check.modeID) ?? CheckResults(modeID: check.modeID)
            // Another mode version or check kind starts over.
            if loaded.modeVersion != modeVersions[check.modeID] || loaded.kind != check.kind {
                loaded = CheckResults(modeID: check.modeID, modeVersion: modeVersions[check.modeID], kind: check.kind)
            }
            return loaded
        }
        guard let database = try AnalysisIndex.open(env: env) else { return results }
        let lab = IndexedSessions.labKeys(env: env)
        let sessions = try AnalysisIndex.sessions(database).filter { !lab.contains($0.key) }
        for (index, session) in sessions.enumerated() {
            progress(index, sessions.count)
            guard let summary = IndexedSessions.summary(session) else { continue }
            let modified = summary.modified.timeIntervalSince1970
            let stale = checks.indices.filter { i in
                guard let old = results[i].verdicts[session.key] else { return true }
                return old.version != checks[i].version || old.fileSize != summary.size || old.fileModified != modified
            }
            guard !stale.isEmpty, let transcript = try? SessionReader.transcript(of: summary) else { continue }
            for i in stale {
                var verdict = checks[i].check(transcript)
                verdict.fileSize = summary.size
                verdict.fileModified = modified
                results[i].verdicts[session.key] = verdict
            }
        }
        for result in results { try store.save(result) }
        return results
    }
}
