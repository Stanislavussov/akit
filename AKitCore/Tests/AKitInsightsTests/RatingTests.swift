import Foundation
import Testing
import AKitFoundation
import AKitSessions
@testable import AKitCommandLine
@testable import AKitInsights

/// Ratings of a run (`akit rate`, from the Pi extension): the spool line, its import into the
/// index, what the Sessions screen reads, and the extension's contract. Temporary fake home.
struct RatingTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-rating-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var transcript: String { home.appending(path: ".pi/agent/sessions/--work--/2026-10-07T07-00-00-000Z_s1.jsonl").path }

    func input(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields)
    }

    func rate(_ arguments: String..., stdin: Data) async -> (code: Int32, err: String) {
        var err: [String] = []
        let code = await AKitCLI.run(["rate"] + arguments, env: env, cwd: home, out: { _ in }, err: { err.append($0) },
                                     input: { stdin })
        return (code, err.joined(separator: "\n"))
    }

    @Test func rateWritesOneSpoolLineAndTheImportKeepsIt() async throws {
        let good = await rate("--harness", "pi", "--rating", "good",
                              stdin: try input(["session_id": "s1", "cwd": "/work", "transcript_path": transcript, "anchor": "a1"]))
        #expect(good.code == 0 && good.err.isEmpty, "\(good)")
        // A rating's key is its session and millisecond; a person never rates twice in one.
        try await Task.sleep(for: .milliseconds(5))
        let bad = await rate("--harness", "pi", "--rating", "bad",
                             stdin: try input(["transcript_path": transcript, "anchor": "a2", "text": "  read the whole file again \n"]))
        #expect(bad.code == 0, "\(bad)")

        let lines = Ratings.spooled(home: home)
        #expect(lines.map(\.rating) == ["good", "bad"])
        // The id comes from Pi's file name when the session id is missing; the comment is trimmed.
        #expect(lines.map(\.sessionID) == ["s1", "s1"] && lines.map(\.anchor) == ["a1", "a2"])
        #expect(lines.map(\.text) == [nil, "read the whole file again"])

        // On the Sessions screen before and after the import, once each.
        #expect(Ratings.byTranscript(env: env)[transcript]?.count == 2)
        let database = try IndexSchema.open(InsightsPaths(home: home).database)
        _ = try SessionImporter(env: env).run(database: database, now: Date())
        #expect(try Ratings.all(database).map(\.rating) == ["good", "bad"])
        #expect(Ratings.byTranscript(env: env)[transcript]?.map(\.text) == [nil, "read the whole file again"])
    }

    @Test func rateRefusesWhatItCantRecord() async throws {
        let session = try input(["session_id": "s1"])
        #expect(await rate("--harness", "pi", "--rating", "meh", stdin: session).err.contains("--rating good, --rating bad or --rating none"))
        #expect(await rate("--harness", "pi", stdin: session).code == 1)
        #expect(await rate("--harness", "pi", "--rating", "good", stdin: Data("garbage".utf8)).err.contains("no session on stdin"))
        #expect(await rate("--harness", "pi", "--rating", "good", stdin: try input(["cwd": "/work"])).err.contains("no session id"))
        #expect(!fm.fileExists(atPath: InsightsPaths(home: home).spool.path), "nothing was written")
        // A very long comment is cut, not refused.
        let long = await rate("--harness", "pi", "--rating", "bad",
                              stdin: try input(["session_id": "s1", "text": String(repeating: "x", count: 5000)]))
        #expect(long.code == 0 && Ratings.spooled(home: home).first?.text?.count == RateRun.maxText)
        // Cut by bytes: a long Cyrillic comment keeps the log path, so the rating still shows.
        let cyrillic = await rate("--harness", "pi", "--rating", "bad",
                                  stdin: try input(["session_id": "s2", "transcript_path": transcript, "text": String(repeating: "ж", count: 3000)]))
        let saved = try #require(Ratings.spooled(home: home).first { $0.sessionID == "s2" })
        #expect(cyrillic.code == 0 && saved.transcript == transcript && (saved.text?.utf8.count ?? 0) <= RateRun.maxText)
    }

    /// A run rated again or taken back: every press is a line, the latest one per anchor counts,
    /// before and after the import (the index takes `none` since v8).
    @Test func aRunsLatestLineIsItsRating() async throws {
        func press(_ rating: String, _ anchor: String, _ text: String? = nil) async throws {
            var fields: [String: Any] = ["session_id": "s1", "transcript_path": transcript, "anchor": anchor]
            fields["text"] = text
            let result = await rate("--harness", "pi", "--rating", rating, stdin: try input(fields))
            #expect(result.code == 0, "\(result)")
            try await Task.sleep(for: .milliseconds(5))
        }
        try await press("good", "a1")
        try await press("bad", "a1")
        try await press("bad", "a1", "reads the file twice")
        try await press("bad", "a2")
        try await press("none", "a2")
        try await press("good", "a3")

        func check(_ ratings: [Ratings.Rating]?) throws {
            let ratings = try #require(ratings)
            #expect(ratings.map(\.anchor) == ["a1", "a3"])
            #expect(ratings.map(\.rating) == ["bad", "good"] && ratings.map(\.text) == ["reads the file twice", nil])
            #expect(ratings.map(\.changed) == [true, false])
            // Placed in time by the first press, not the last change.
            #expect(ratings[0].firstDate < ratings[0].date)
        }
        try check(Ratings.byTranscript(env: env)[transcript])
        let database = try IndexSchema.open(InsightsPaths(home: home).database)
        _ = try SessionImporter(env: env).run(database: database, now: Date())
        #expect(try Ratings.all(database).count == 6)
        try check(Ratings.byTranscript(env: env)[transcript])
    }

    /// v8 copies the v7 table and lets `none` in.
    @Test func migrationV8KeepsRatingsAndTakesNone() throws {
        let url = InsightsPaths(home: home).database
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = try IndexDatabase(url: url)
        for (index, script) in IndexSchema.migrations.prefix(7).enumerated() {
            try old.execute(script)
            try old.execute("PRAGMA user_version = \(index + 1)")
        }
        _ = try old.run("INSERT INTO ratings(harness, session_id, ts, rating, text, anchor, source_id, parser_version) VALUES('pi', 's1', 1, 'bad', 'slow', 'a1', 1, 4)")
        #expect(throws: (any Error).self) { _ = try old.run("INSERT INTO ratings(harness, session_id, ts, rating, source_id, parser_version) VALUES('pi', 's1', 2, 'none', 1, 4)") }

        let database = try IndexSchema.open(url)
        #expect(try database.userVersion == IndexSchema.migrations.count)
        _ = try database.run("INSERT INTO ratings(harness, session_id, ts, rating, anchor, source_id, parser_version) VALUES('pi', 's1', 2, 'none', 'a1', 1, 4)")
        #expect(try Ratings.all(database).map(\.rating) == ["bad", "none"])
        #expect(Ratings.current(try Ratings.all(database)).isEmpty)
        #expect(try database.rows("SELECT name FROM sqlite_master WHERE name = 'ratings_source'").count == 1)
    }

    /// Where a rating shows: where its anchor ends in the transcript (nowhere when off the branch),
    /// in time without entry ids; with the run's prompt.
    @Test func ratingIsPlacedAfterItsRun() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let items = [
            TranscriptItem(id: 0, kind: .user, text: "Fix the build\nand more", timestamp: start),
            TranscriptItem(id: 1, kind: .assistant, text: "Done", timestamp: start + 10),
            TranscriptItem(id: 2, kind: .user, text: "Now the tests", timestamp: start + 60),
            TranscriptItem(id: 3, kind: .assistant, text: "Done too", timestamp: start + 70),
        ]
        let transcript = SessionTranscript(items: items, endItems: ["x0": 1, "x1": 3])
        func rating(_ anchor: String?, at seconds: TimeInterval) -> Ratings.Rating {
            Ratings.Rating(harness: "pi", sessionID: "s1", date: start + seconds, rating: "bad", text: nil, transcript: nil, anchor: anchor)
        }
        // By anchor, even when the clock would say otherwise.
        #expect(Ratings.place(of: rating("x1", at: 20), in: transcript) == 3)
        // A run off the active branch (after /tree) has no place, not a wrong one.
        #expect(Ratings.place(of: rating("y1", at: 20), in: transcript) == nil)
        // Without entry ids: by the time of the first press.
        let plain = SessionTranscript(items: items)
        let place = try #require(Ratings.place(of: rating("y1", at: 20), in: plain))
        #expect(place == 1 && Ratings.prompt(endingAt: place, in: plain) == "Fix the build")
        #expect(Ratings.prompt(endingAt: 3, in: transcript) == "Now the tests")
    }

    /// The extension's contract: a widget after the run, the three Option keys, `akit rate` waited
    /// for, and nothing that reaches the model (no messages, tools or prompt changes).
    @Test func piExtensionRatesWithoutTouchingTheModelContext() {
        let text = CaptureInstaller.piExtensionText
        for needle in ["agent_settled", "\"alt+g\"", "\"alt+x\"", "\"alt+r\"", "\"alt+u\"", "save(ctx, \"none\")",
                       "\"rate\", \"--harness\", \"pi\", \"--rating\"",
                       "appendEntry(RATING", "registerEntryRenderer", "✅ Saved", "⚠️ Not saved", "record-session"] {
            #expect(text.contains(needle), "\(needle)")
        }
        // No Pi package import either: the file loads on any Pi, and session capture with it.
        for banned in ["sendMessage", "sendUserMessage", "registerTool", "before_agent_start", "setActiveTools", "\"context\"",
                       "@earendil-works", "@mariozechner"] {
            #expect(!text.contains(banned), "\(banned)")
        }
        // Option keys Pi itself uses (word left, delete word, …) are left alone, and so are its reserved Ctrl keys.
        for taken in ["\"alt+b\"", "\"alt+f\"", "\"alt+d\"", "\"ctrl+g\"", "\"ctrl+b\"", "\"ctrl+r\""] {
            #expect(!text.contains(taken), "\(taken)")
        }
    }
}
