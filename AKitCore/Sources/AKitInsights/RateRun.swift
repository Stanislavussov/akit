import AKitFoundation
import AKitSessions
import Darwin
import Foundation

/// `akit rate --harness H --rating good|bad|none`, run by the Pi extension when the person rates the
/// last run (⌥G, ⌥X, ⌥R) or takes the rating back (⌥U, `none`). Reads `session_id`, `cwd`,
/// `transcript_path`, `anchor` (the last entry of the run) and an optional `text` from stdin and
/// appends one `rating` line to the spool. A run's lines are never rewritten: the latest line with
/// its anchor is its rating (see `Ratings.current`).
/// Unlike `record-session` it reports back: the extension says "Saved" only after exit 0, and
/// shows the one stderr line otherwise. Nothing goes to the model either way.
public enum RateRun {
    public static let ratings: Set<String> = ["good", "bad"]
    /// What a line may carry: a rating, or `none` for one taken back.
    public static let values: Set<String> = ratings.union(["none"])
    /// A comment is one line in the harness; a longer one is cut here, to this many UTF-8 bytes,
    /// so the spool line stays under `Spool.maxLine` and keeps its log path.
    public static let maxText = 2000

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The `akit` binary's entry for `rate`: 0 when the line was written, else 1 with the reason on stderr.
    public static func main(arguments: [String]) -> Int32 {
        let input = isatty(0) != 0 ? Data() : RecordSession.readStandardInput()
        do {
            try run(arguments: arguments, stdin: input, env: .current)
            return 0
        } catch {
            FileHandle.standardError.write(Data("akit rate: \(error.message)\n".utf8))
            return 1
        }
    }

    public static func run(arguments: [String], stdin: Data, env: HarnessEnvironment, now: Date = Date()) throws(Failure) {
        let line = try line(arguments: arguments, stdin: stdin, now: now)
        guard Spool.append(line, home: env.homeDirectory, now: now) else {
            throw Failure(message: "couldn't write into \(InsightsPaths(env: env).spool.path)")
        }
    }

    static func line(arguments: [String], stdin: Data, now: Date) throws(Failure) -> [String: Any] {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let rating = value("--rating"), values.contains(rating) else {
            throw Failure(message: "use --rating good, --rating bad or --rating none")
        }
        let harness = String((value("--harness") ?? "pi").lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(32))
        guard let input = (try? JSONSerialization.jsonObject(with: stdin)) as? [String: Any] else {
            throw Failure(message: "no session on stdin")
        }
        func text(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let transcript = text("transcript_path")
        // Pi names its logs `<time>_<session id>.jsonl`; used when the id itself is missing.
        let fromFile = transcript.map { URL(filePath: $0).deletingPathExtension().lastPathComponent }
            .flatMap { $0.split(separator: "_").last.map(String.init) }
        guard !harness.isEmpty, let session = text("session_id") ?? fromFile, session.count <= 256 else {
            throw Failure(message: "no session id on stdin")
        }
        var line: [String: Any] = ["v": Spool.lineVersion, "kind": "rating", "harness": harness, "session_id": session,
                                   "rating": rating, "ts": Spool.milliseconds(now)]
        line["transcript"] = transcript
        line["cwd"] = text("cwd")
        line["anchor"] = text("anchor").map { String($0.prefix(256)) }
        if let comment = text("text")?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
            var cut = Substring(comment)
            while cut.utf8.count > maxText { cut = cut.dropLast() }
            line["text"] = String(cut)
        }
        return line
    }
}

/// Ratings in the index, for the Sessions screen.
public enum Ratings {
    public struct Rating: Sendable, Hashable {
        public let harness: String
        public let sessionID: String
        public let date: Date
        /// `good`, `bad`, or `none` for a rating taken back.
        public let rating: String
        public let text: String?
        /// The log the session was in when rated.
        public let transcript: String?
        /// The run's last entry (Pi: its entry id).
        public let anchor: String?

        /// When the run was first rated: before its next prompt, so it places the run in time.
        public var firstDate: Date
        /// The run was rated before with something else.
        public var changed = false

        init(harness: String, sessionID: String, date: Date, rating: String, text: String?, transcript: String?, anchor: String?) {
            self.harness = harness
            self.sessionID = sessionID
            self.date = date
            self.rating = rating
            self.text = text
            self.transcript = transcript
            self.anchor = anchor
            firstDate = date
        }

        public var isGood: Bool { rating == "good" }
    }

    /// Each run's rating now: its latest line, by the run's anchor (a line without one is a run
    /// of its own). Runs whose latest line is `none` are left out. Oldest run first.
    public static func current(_ ratings: [Rating]) -> [Rating] {
        let runs = Dictionary(grouping: ratings) { rating in
            "\(rating.harness)|\(rating.sessionID)|\(rating.anchor ?? "@\(rating.date.timeIntervalSince1970)")"
        }
        return runs.values.compactMap { lines -> Rating? in
            let sorted = lines.sorted { $0.date < $1.date }
            guard var last = sorted.last, last.rating != "none" else { return nil }
            last.firstDate = sorted[0].date
            last.changed = sorted.dropLast().contains { $0.rating != last.rating || $0.text != last.text }
            return last
        }
        .sorted { $0.firstDate < $1.firstDate }
    }

    /// Every rating, oldest first.
    public static func all(_ database: IndexDatabase) throws -> [Rating] {
        try database.rows("SELECT harness, session_id, ts, rating, text, transcript, anchor FROM ratings ORDER BY ts").compactMap { row in
            guard let harness = row[0].text, let session = row[1].text, let ms = row[2].double, let rating = row[3].text else { return nil }
            return Rating(harness: harness, sessionID: session, date: Date(timeIntervalSince1970: ms / 1000), rating: rating,
                          text: row[4].text, transcript: row[5].text, anchor: row[6].text)
        }
    }

    /// Each run's current rating by session log path, for the app's Sessions list: from the
    /// index, and from the spool lines the hourly import hasn't read yet, so a rating shows on the
    /// next rescan. Never imports or writes.
    public static func byTranscript(env: HarnessEnvironment) -> [String: [Rating]] {
        var ratings: [Rating] = []
        let url = InsightsPaths(env: env).database
        if FileManager.default.fileExists(atPath: url.path), let database = try? IndexDatabase(url: url),
           (try? database.userVersion) ?? 0 >= 7 {
            ratings = (try? all(database)) ?? []
        }
        ratings += spooled(home: env.homeDirectory)
        var seen = Set<String>()
        let unique = ratings.filter { seen.insert("\($0.harness)|\($0.sessionID)|\($0.date.timeIntervalSince1970)").inserted }
        return Dictionary(grouping: unique.filter { $0.transcript != nil }, by: { $0.transcript! })
            .mapValues(current).filter { !$0.value.isEmpty }
    }

    /// The id of the item that ends the rated run, the place to show the rating: where its anchor
    /// (the run's last log entry) is in the transcript; nil when the run is off the active branch.
    /// Without an anchor or entry ids, the last item before the run was first rated.
    public static func place(of rating: Rating, in transcript: SessionTranscript) -> Int? {
        if let anchor = rating.anchor, !transcript.endItems.isEmpty {
            return transcript.endItems[anchor]
        }
        return transcript.items.last { ($0.timestamp ?? .distantFuture) <= rating.firstDate }?.id
    }

    /// The first line of the prompt that started the run ending at `item`.
    public static func prompt(endingAt item: Int, in transcript: SessionTranscript) -> String? {
        guard let prompt = transcript.items.last(where: { $0.id <= item && $0.kind == .user }) else { return nil }
        return prompt.text.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    /// `rating` lines still in the spool files.
    static func spooled(home: URL) -> [Rating] {
        FileWalk.children(of: InsightsPaths(home: home).spool).filter { $0.pathExtension == "jsonl" }.flatMap { file in
            ((try? Data(contentsOf: file)).flatMap { try? JSONLines.objects(in: $0) } ?? []).compactMap { entry -> Rating? in
                guard entry["kind"] as? String == "rating", let harness = entry["harness"] as? String,
                      let session = entry["session_id"] as? String, let rating = entry["rating"] as? String,
                      RateRun.values.contains(rating), let ms = (entry["ts"] as? NSNumber)?.doubleValue else { return nil }
                return Rating(harness: harness, sessionID: session, date: Date(timeIntervalSince1970: ms / 1000), rating: rating,
                              text: entry["text"] as? String, transcript: entry["transcript"] as? String,
                              anchor: entry["anchor"] as? String)
            }
        }
    }
}
