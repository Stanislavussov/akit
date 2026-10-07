import Foundation
import Testing
import AKitFoundation
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
        #expect(await rate("--harness", "pi", "--rating", "meh", stdin: session).err.contains("--rating good or --rating bad"))
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

    /// The extension's contract: a widget after the run, the three Option keys, `akit rate` waited
    /// for, and nothing that reaches the model (no messages, tools or prompt changes).
    @Test func piExtensionRatesWithoutTouchingTheModelContext() {
        let text = CaptureInstaller.piExtensionText
        for needle in ["agent_settled", "\"alt+g\"", "\"alt+x\"", "\"alt+r\"", "\"rate\", \"--harness\", \"pi\", \"--rating\"",
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
