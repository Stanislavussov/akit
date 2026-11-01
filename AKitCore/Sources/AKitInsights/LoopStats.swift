import AKitFoundation
import AKitModel
import AKitSessions
import Foundation

/// `akit stats loops`: the stuck loops of a window (`docs/design/repeat-loops.md`): sessions where
/// the user asked the same thing 3 or more times in a row and the agent answered almost the same.
/// Grouped by the model and thinking level they ran on, with advice on when to raise thinking or
/// switch the model. Uses the scope rules of `akit stats` (sessions started in the window; for a
/// project, bound to it). Loops come from the signals scan (it runs after each import), so a session
/// not scanned yet has none. The JSON (`version` 1) is the contract for `/akit` and the Insights screen.
public struct LoopsReport: Encodable, Equatable, Sendable {
    public struct Loop: Encodable, Equatable, Sendable, Identifiable {
        public var id: String { "\(sessionKey)#\(firstStep)" }
        /// The index's key: `pi:<id>`.
        public let sessionKey: String
        /// The session's log file, while the index knows it (local only).
        public let file: String?
        /// The folder the session ran in.
        public let cwd: String?
        public let firstStep: Int
        public let lastStep: Int
        /// How many times the user asked (3 or more).
        public let asks: Int
        public let model: String?
        /// Pi's thinking level; nil: not recorded.
        public let thinking: String?
        /// When the first ask was sent (ISO 8601).
        public let started: String?
    }

    /// The loops on one model at one thinking level.
    public struct Group: Encodable, Equatable, Sendable, Identifiable {
        public var id: String { "\(model ?? "")|\(thinking ?? "")" }
        public let model: String?
        public let thinking: String?
        public let loops: Int
        public let sessions: Int
        /// The most asks in one loop.
        public let maxAsks: Int
        /// What to do next time, in one sentence.
        public let advice: String
    }

    public let version: Int
    public let days: Int
    public let project: String?
    /// Sessions in scope whose signals were scanned (the base of the rate).
    public let sessionsScanned: Int
    /// Of those, sessions with at least one loop.
    public let sessionsWithLoops: Int
    /// Newest first.
    public let loops: [Loop]
    /// Most loops first.
    public let groups: [Group]

    /// No index yet: nothing scanned.
    public static func empty(days: Int, project: String?) -> LoopsReport {
        LoopsReport(version: 1, days: days, project: project, sessionsScanned: 0, sessionsWithLoops: 0, loops: [], groups: [])
    }

    /// Thinking levels from which "raise thinking" is no longer the advice.
    static let highThinking: Set<String> = ["high", "xhigh", "max"]

    /// One sentence per thinking level: Pi's own keys and AKit's extension key (⌥T raises thinking).
    public static func advice(thinking: String?) -> String {
        if let thinking, highThinking.contains(thinking) {
            return "Thinking was already \(thinking): at the 2nd repeat switch to another model (Ctrl+P), "
                + "or start a new session with a short summary of what was tried."
        }
        return "At the 2nd repeat raise thinking (⌥T or Shift+Tab) or switch to a stronger model (Ctrl+P)."
    }

    public static func report(_ database: IndexDatabase, days: Int = InsightsStats.defaultDays, range: DayRange? = nil,
                              project: String? = nil, bindings: BindingSet = .default, now: Date = Date()) throws -> LoopsReport {
        let (from, to) = range?.bounds(now: now) ?? (now.addingTimeInterval(-Double(days) * 86_400), now)
        let days = range?.days() ?? days
        // Only Pi sessions are checked for loops; the rate counts only them.
        let scope = InsightsStats.Scope(project: project, bindings: bindings, from: from, to: to, harness: RepeatLoops.harness)
        let (scoped, values) = scope.cte
        let counts = try database.rows("""
            WITH \(scoped) SELECT COUNT(*), SUM(CASE WHEN g.repeat_loops > 0 THEN 1 ELSE 0 END)
            FROM signals g JOIN scoped s ON s.key = g.session_key
            """, values).first
        var loops: [Loop] = []
        for row in try database.rows("""
            WITH \(scoped) SELECT l.session_key, src.path, x.cwd, l.first_step, l.last_step, l.asks, l.model, l.thinking, l.ts
            FROM repeat_loops l JOIN scoped s ON s.key = l.session_key JOIN sessions x ON x.key = l.session_key
            LEFT JOIN sources src ON src.id = x.source_id
            ORDER BY l.ts DESC, l.session_key, l.first_step
            """, values) {
            guard let key = row[0].text else { continue }
            loops.append(Loop(sessionKey: key, file: row[1].text, cwd: row[2].text, firstStep: row[3].int ?? 0,
                              lastStep: row[4].int ?? 0, asks: row[5].int ?? 0, model: row[6].text, thinking: row[7].text,
                              started: row[8].double.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) }))
        }
        var groups: [Group] = []
        for (_, members) in Dictionary(grouping: loops, by: { "\($0.model ?? "")|\($0.thinking ?? "")" }) {
            let first = members[0]
            groups.append(Group(model: first.model, thinking: first.thinking, loops: members.count,
                                sessions: Set(members.map(\.sessionKey)).count, maxAsks: members.map(\.asks).max() ?? 0,
                                advice: advice(thinking: first.thinking)))
        }
        groups.sort { ($0.loops, $1.model ?? "", $1.thinking ?? "") > ($1.loops, $0.model ?? "", $0.thinking ?? "") }
        return LoopsReport(version: 1, days: days, project: project, sessionsScanned: counts?[0].int ?? 0,
                           sessionsWithLoops: counts?[1].int ?? 0, loops: loops, groups: groups)
    }

    /// Lines for the terminal.
    public var text: String {
        var lines = ["Stuck loops in Pi sessions, last \(days) days\(project.map { " in \($0)" } ?? ""): "
                     + "\(sessionsWithLoops) of \(sessionsScanned) scanned sessions."]
        if loops.isEmpty {
            lines.append("No session where the same ask got almost the same answer 3 times in a row.")
            return lines.joined(separator: "\n")
        }
        lines.append("")
        for group in groups {
            lines.append("\(group.model ?? "model not recorded") · thinking \(group.thinking ?? "not recorded"): "
                         + "\(group.loops) loop\(group.loops == 1 ? "" : "s") in \(group.sessions) session\(group.sessions == 1 ? "" : "s"), "
                         + "up to \(group.maxAsks) asks")
            lines.append("  \(group.advice)")
        }
        lines.append("")
        for loop in loops {
            lines.append("\(loop.started.map { String($0.prefix(10)) } ?? "?")  \(loop.sessionKey)  steps \(loop.firstStep)–\(loop.lastStep), "
                         + "\(loop.asks) asks\(loop.cwd.map { "  \(($0 as NSString).lastPathComponent)" } ?? "")")
        }
        return lines.joined(separator: "\n")
    }
}

/// `akit loop-check --harness pi`: whether a session ends in a stuck loop right now, for the Pi
/// extension's live warning after each run. Reads `transcript_path` from stdin (the extension's JSON,
/// as for `akit rate`) and only that log; nothing is written. The JSON (`version` 1) is the contract
/// with the extension: `loop` is null when there is none.
public struct LoopCheck: Encodable, Equatable, Sendable {
    public struct Loop: Encodable, Equatable, Sendable {
        public let firstStep: Int
        public let lastStep: Int
        public let asks: Int
        public let model: String?
        public let thinking: String?
        public let advice: String
    }

    public let version: Int
    public let loop: Loop?

    public init(loop: RepeatLoop?) {
        version = 1
        self.loop = loop.map {
            Loop(firstStep: $0.firstStep, lastStep: $0.lastStep, asks: $0.asks, model: $0.model, thinking: $0.thinking,
                 advice: LoopsReport.advice(thinking: $0.thinking))
        }
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Only Pi sessions are checked (`docs/design/repeat-loops.md`, R4, R7).
    public static func run(harness: String?, stdin: Data) throws(Failure) -> LoopCheck {
        guard harness == "pi" else { throw Failure(message: "use --harness pi (only Pi sessions are checked).") }
        guard let object = (try? JSONSerialization.jsonObject(with: stdin)) as? [String: Any],
              let path = object["transcript_path"] as? String, !path.isEmpty else {
            throw Failure(message: "expected JSON with transcript_path on stdin.")
        }
        let file = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure(message: "no session log at \(path).") }
        let summary = SessionSummary(harness: .pi, file: file, title: "", project: nil, started: nil, modified: Date(), size: 0)
        let transcript: SessionTranscript
        do {
            transcript = try SessionReader.transcript(of: summary)
        } catch {
            throw Failure(message: "can't read \(path): \(error.localizedDescription)")
        }
        return LoopCheck(loop: RepeatLoops.ongoing(transcript.items, fallbackModel: transcript.models.last))
    }
}

extension LoopCheck {
    /// The `akit` binary's entry for `loop-check`: the JSON on stdout and 0, or 1 with the reason on stderr.
    public static func main(arguments: [String]) -> Int32 {
        let input = isatty(0) != 0 ? Data() : RecordSession.readStandardInput()
        do {
            print(try run(arguments: arguments, stdin: input).json)
            return 0
        } catch {
            FileHandle.standardError.write(Data("akit loop-check: \(error.message)\n".utf8))
            return 1
        }
    }

    /// `--harness pi` is the only argument.
    public static func run(arguments: [String], stdin: Data) throws(Failure) -> LoopCheck {
        guard arguments.count == 2, arguments[0] == "--harness" else { throw Failure(message: "use: akit loop-check --harness pi < JSON") }
        return try run(harness: arguments[1], stdin: stdin)
    }

    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
