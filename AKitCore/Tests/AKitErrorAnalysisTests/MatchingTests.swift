import Foundation
import Testing
import AKitFoundation
@testable import AKitErrorAnalysis
@testable import AKitLab

/// Matching, clustering, labels and the review queue, with a fake `claude` that answers by
/// the call's system prompt.
@Suite(.serialized)
struct MatchingTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-matching-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
        try write("bin/claude", """
            #!/bin/sh
            if [ "$1 $2" = "auth status" ]; then
              echo '{"loggedIn":true,"apiProvider":"firstParty","email":"me@example.com","orgName":"Me"}'; exit 0
            fi
            cat > /dev/null
            case "$*" in
              *"You sort notes"*) f=matching ;;
              *"You group notes"*) f=clustering ;;
              *"belong to one"*) f=retro ;;
              *"more cases of one"*) f=similar ;;
              *) f=unknown ;;
            esac
            echo $f >> "$HOME/calls.txt"
            cat "$HOME/answer-$f.json"

            """, executable: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func write(_ path: String, _ text: String, executable: Bool = false) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    func answer(_ name: String, _ object: [String: Any]) throws {
        let line: [String: Any] = ["type": "result", "is_error": false, "result": "", "structured_output": object,
                                   "usage": ["input_tokens": 10, "output_tokens": 5]]
        try write("answer-\(name).json", String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self) + "\n")
    }

    var calls: [String] { ((try? String(contentsOf: home.appending(path: "calls.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

    let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "low", mode: .call)

    func pool(_ key: String, notes: [(String, String)]) throws -> SessionNotes {
        let session = SessionNotes(sessionKey: key, transcript: "/t/\(key).jsonl", title: nil, project: nil, requirements: [], outcome: .no,
                                   notes: notes.enumerated().map { index, note in
                                       Note(id: note.0, source: .model, description: note.1, step: index, quote: "q\(index)",
                                            verdict: Verdict(accepted: true, reason: "", by: .model))
                                   },
                                   deviation: Deviation(), paragraph: "", advice: [],
                                   notesConfig: StepConfig(step: "notes", harness: "claude-code", model: "opus", promptVersion: 1),
                                   verifierConfig: nil, doneKeys: [:], runID: nil)
        try NotesStore(env: env).save(session)
        return session
    }

    @Test func routesAreSavedReviewedAndCounted() async throws {
        let store = ModeStore(env: env)
        let modes = try await store.list()
        #expect(modes.count == 9)
        let notes = try pool("claude:a", notes: [("n1", "Read a 40 KB file whole"), ("n2", "Odd thing"), ("n3", "Claimed done")])
        try answer("matching", ["routes": [
            ["note": "n1", "mode": "large-file-read-whole", "confidence": 0.95, "reason": "whole read"],
            ["note": "n2", "mode": "none", "confidence": 0.9],
            ["note": "n3", "mode": "not-a-mode", "confidence": 0.9],
        ]])
        let gate = try await SendGate.open(agent: agent, env: env)
        let routed = try await Matching.route(notes, modes: modes, exemplars: [:], agent: agent, gate: gate, origin: .claudeSession,
                                              runID: nil, workFolder: home.appending(path: "w"), env: env)
        let routes = Matching.currentRoutes(routed)
        #expect(routes["n1"]?.modeID == "large-file-read-whole")
        #expect(routes["n2"]?.modeID == nil && routes["n2"]?.confidence == 0.9)
        // An unknown mode becomes "none fits" at confidence 0: the user sees it.
        #expect(routes["n3"]?.modeID == nil && routes["n3"]?.confidence == 0)
        #expect(Matching.waitingRoutes([routed]).map(\.ref.noteID) == ["n3"])
        // Same notes, modes and model: no second call.
        _ = try await Matching.route(routed, modes: modes, exemplars: [:], agent: agent, gate: gate, origin: .claudeSession, runID: nil,
                                     workFolder: home.appending(path: "w"), env: env)
        #expect(calls == ["matching"])

        try Matching.review(NoteRef(sessionKey: "claude:a", noteID: "n1"), accept: true, env: env)
        try Matching.review(NoteRef(sessionKey: "claude:a", noteID: "n3"), accept: false, moveTo: .some("overclaiming-completion"), env: env)
        let reviewed = try #require(NotesStore(env: env).load("claude:a"))
        #expect(Matching.currentRoutes(reviewed)["n3"]?.modeID == "overclaiming-completion")
        #expect(Matching.acceptance([reviewed]) == (1, 2))
        let seen = Matching.seen([reviewed], modes: modes)
        #expect(seen.byMode["large-file-read-whole"]?.count == 1 && seen.unmatched.map(\.noteID) == ["n2"])

        // Merging a mode recounts its notes under the target.
        _ = try await store.merge(["overclaiming-completion"], into: "false-premise")
        #expect(Matching.seen([reviewed], modes: try await store.list()).byMode["false-premise"]?.count == 1)
    }

    @Test func clusteringMakesCandidatesAndPromotesThem() async throws {
        let store = ModeStore(env: env)
        _ = try await store.list()
        _ = try pool("claude:a", notes: [("n1", "Ignored the lint warning"), ("n2", "Other")])
        _ = try pool("claude:b", notes: [("n1", "Ignored lint output")])
        _ = try pool("claude:c", notes: [("n1", "Asked the user three times the same thing")])
        let items = Clustering.items(NotesStore(env: env).all())
        try answer("clustering", ["modes": [
            ["name": "Lint warnings ignored", "kind": "failure", "definition": "Lint output with warnings is not acted on.",
             "include": ["a warning shown, then done"], "exclude": ["the user said to ignore it"], "notes": ["claude:a#n1", "claude:b#n1", "claude:x#n9"]],
            ["name": "Repeated questions", "kind": "failure", "definition": "The agent asks the same thing again.",
             "include": [], "exclude": [], "notes": ["claude:c#n1", "claude:a#n1"]],
        ]])
        let gate = try await SendGate.open(agent: agent, env: env)
        let candidates = try await Clustering.cluster(items, existing: try await store.list(), rejected: [], agent: agent, gate: gate,
                                                      runID: nil, workFolder: home.appending(path: "w"), env: env)
        // Unknown refs dropped; a note in at most one candidate.
        #expect(candidates.map(\.notes.count) == [2, 1])
        let created = try await Clustering.apply(candidates, store: store, env: env)
        // Candidates, both: clustering never confirms a mode on its own.
        #expect(created.map(\.status) == [.candidate, .candidate])
        #expect(created[0].id == "lint-warnings-ignored")
        let seen = Matching.seen(NotesStore(env: env).all(), modes: try await store.list()).byMode
        #expect(seen["lint-warnings-ignored"]?.count == 2 && seen["repeated-questions"]?.count == 1)

        // A second independent case promotes the candidate.
        var b = try #require(NotesStore(env: env).load("claude:b"))
        b.notes.append(Note(id: "n2", source: .model, description: "Asked again", step: 5, quote: "q",
                            verdict: Verdict(accepted: true, reason: "", by: .model)))
        b.routes = (b.routes ?? []) + [Route(noteID: "n2", modeID: "repeated-questions", confidence: 0.9, by: .matching)]
        try NotesStore(env: env).save(b)
        let promoted = try await Clustering.promoteCandidates(store: store, env: env)
        #expect(promoted.map(\.id) == ["repeated-questions"])
        #expect(Clustering.slug("Lint warnings ignored", taken: ["lint-warnings-ignored"]) == "lint-warnings-ignored-2")
    }

    @Test func retroMatchingFillsUnmatchedNotesAndAsksAboutOthers() async throws {
        let store = ModeStore(env: env)
        let modes = try await store.list()
        var a = try pool("claude:a", notes: [("n1", "cat of a 50 KB file"), ("n2", "Something else")])
        a.routes = [Route(noteID: "n1", modeID: nil, confidence: 0.9, by: .matching),
                    Route(noteID: "n2", modeID: "false-premise", confidence: 0.9, by: .matching)]
        try NotesStore(env: env).save(a)
        try answer("retro", ["fits": [["note": "claude:a#n1", "fits": true, "confidence": 0.9],
                                      ["note": "claude:a#n2", "fits": true, "confidence": 0.8]]])
        let gate = try await SendGate.open(agent: agent, env: env)
        let mode = try #require(modes.first { $0.id == "large-file-read-whole" })
        let fits = try await Matching.retroMatch(mode: mode, pool: [a], origins: ["claude:a": .claudeSession], agent: agent, gate: gate,
                                                 workFolder: home.appending(path: "w"), env: env)
        #expect(fits.count == 2)
        let saved = try #require(NotesStore(env: env).load("claude:a"))
        let routes = Matching.currentRoutes(saved)
        #expect(routes["n1"]?.modeID == "large-file-read-whole")
        // Routed elsewhere already: stays, and the user is asked.
        #expect(routes["n2"]?.modeID == "false-premise")
        #expect(Matching.waitingRoutes([saved]).map(\.route.modeID) == ["large-file-read-whole"])
    }

    @Test func labelsComeFromMappingFindsAndToughCalls() async throws {
        let modes = try await ModeStore(env: env).list()
        var h1 = Note(id: "h1", source: .human, description: "big read", step: 2, quote: "q")
        h1.id = "h1"
        let labeled = Bootstrap.Label(sessionKey: "claude:a", transcript: "/t", notes: [h1], outcome: .no, labeledAt: .now)
        let clean = Bootstrap.Label(sessionKey: "claude:b", transcript: "/t", notes: [], outcome: .achieved, labeledAt: .now)
        let draft = Bootstrap.Label(sessionKey: "claude:c", transcript: "/t", notes: [h1], outcome: nil, labeledAt: nil)
        var book = LabelBook(mapping: ["claude:a#h1": "large-file-read-whole", "claude:c#h1": "large-file-read-whole"])
        book.finds = [LabelBook.Find(ref: NoteRef(sessionKey: "claude:d", noteID: "n1"), modeID: "large-file-read-whole",
                                     from: NoteRef(sessionKey: "claude:a", noteID: "h1"), accepted: true),
                      LabelBook.Find(ref: NoteRef(sessionKey: "claude:e", noteID: "n4"), modeID: "large-file-read-whole",
                                     from: NoteRef(sessionKey: "claude:a", noteID: "h1"), accepted: false),
                      LabelBook.Find(ref: NoteRef(sessionKey: "claude:f", noteID: "n4"), modeID: "large-file-read-whole",
                                     from: NoteRef(sessionKey: "claude:a", noteID: "h1"))]
        book.toughCalls = ["large-file-read-whole|claude:g": true, "other|claude:h": false]
        _ = try LabelBookStore(env: env).update { $0 = book }
        let loaded = LabelBookStore(env: env).load()
        let labels = ModeLabels.labels(for: "large-file-read-whole", modes: modes, bootstrap: [labeled, clean, draft], book: loaded,
                                       toughCalls: loaded.toughCalls(of: "large-file-read-whole"))
        let byKey = Dictionary(uniqueKeysWithValues: labels.map { ($0.sessionKey, $0) })
        #expect(byKey["claude:a"]?.positive == true && byKey["claude:a"]?.source == .bootstrap)
        #expect(byKey["claude:b"]?.positive == false)
        #expect(byKey["claude:c"] == nil)
        #expect(byKey["claude:d"]?.positive == true && byKey["claude:e"]?.positive == false && byKey["claude:f"] == nil)
        #expect(byKey["claude:g"]?.source == .toughCall && byKey["claude:h"] == nil)
        #expect(Bootstrap.sessionsSinceLastModeChange([labeled, clean, draft], lastChange: Date.distantPast) == 2)
        #expect(Bootstrap.sessionsSinceLastModeChange([labeled, clean], lastChange: Date.distantFuture) == 0)
    }

    @Test func bootstrapLabelsNeedEveryNoteMappedAndOneAcceptedFindWins() async throws {
        let modes = try await ModeStore(env: env).list()
        func note(_ id: String) -> Note {
            var note = Note(id: id, source: .human, description: id, step: 1, quote: "q")
            note.id = id
            return note
        }
        let half = Bootstrap.Label(sessionKey: "claude:half", transcript: "/t", notes: [note("h1"), note("h2")], outcome: .no, labeledAt: .now)
        let unclear = Bootstrap.Label(sessionKey: "claude:unclear", transcript: "/t", notes: [note("h1"), note("h2")], outcome: .no, labeledAt: .now)
        let shown = Bootstrap.Label(sessionKey: "claude:shown", transcript: "/t", notes: [note("h1"), note("h2")], outcome: .no, labeledAt: .now)
        var book = LabelBook(mapping: ["claude:half#h1": "false-premise",
                                       "claude:unclear#h1": "false-premise", "claude:unclear#h2": LabelBook.unclear,
                                       "claude:shown#h1": "large-file-read-whole"])
        let from = NoteRef(sessionKey: "claude:half", noteID: "h1")
        // Accepted then rejected, and rejected then accepted: one accepted find is enough.
        book.finds = [LabelBook.Find(ref: NoteRef(sessionKey: "claude:d", noteID: "n1"), modeID: "large-file-read-whole", from: from, accepted: true),
                      LabelBook.Find(ref: NoteRef(sessionKey: "claude:d", noteID: "n2"), modeID: "large-file-read-whole", from: from, accepted: false),
                      LabelBook.Find(ref: NoteRef(sessionKey: "claude:e", noteID: "n1"), modeID: "large-file-read-whole", from: from, accepted: false),
                      LabelBook.Find(ref: NoteRef(sessionKey: "claude:e", noteID: "n2"), modeID: "large-file-read-whole", from: from, accepted: true),
                      LabelBook.Find(ref: NoteRef(sessionKey: "claude:half", noteID: "n1"), modeID: "large-file-read-whole", from: from, accepted: true)]
        let labels = ModeLabels.labels(for: "large-file-read-whole", modes: modes, bootstrap: [half, unclear, shown], book: book)
        let byKey = Dictionary(uniqueKeysWithValues: labels.map { ($0.sessionKey, $0) })
        // A note not mapped yet: no bootstrap negative, so the cheaper label stays.
        #expect(byKey["claude:half"]?.source == .similarCase && byKey["claude:half"]?.positive == true)
        #expect(byKey["claude:unclear"]?.source == .bootstrap && byKey["claude:unclear"]?.positive == false)
        // One mapped note shows the mode even while another waits.
        #expect(byKey["claude:shown"]?.source == .bootstrap && byKey["claude:shown"]?.positive == true)
        #expect(byKey["claude:d"]?.positive == true && byKey["claude:e"]?.positive == true)
        let other = ModeLabels.labels(for: "false-premise", modes: modes, bootstrap: [half, unclear, shown], book: book)
        #expect(other.map(\.sessionKey) == ["claude:half", "claude:unclear"] && other.allSatisfy(\.positive))
    }

    @Test func aJudgesToughCallsReachTheQueue() async throws {
        let store = ModeStore(env: env)
        _ = try await store.create(Mode(id: "kept", name: "Kept", definition: "d"))
        _ = try await store.create(Mode(id: "gone", name: "Gone", definition: "d"))
        _ = try await store.create(Mode(id: "dropped", name: "Dropped", definition: "d"))
        try await store.merge(["gone"], into: "kept")
        try await store.reject("dropped", reason: "not a pattern")
        let tough = CheckVerdict(positive: true, toughCall: true, by: .judge, version: 1)
        try CheckStore(env: env).update(Judges.resultsID("false-premise")) { $0.verdicts["claude:a"] = tough }
        try CheckStore(env: env).update("gone") { $0.verdicts["claude:b"] = tough }
        func queue(_ book: LabelBook = LabelBook()) async throws -> ReviewQueue {
            let modes = try await store.list()
            return ReviewQueue.build(modes: modes, pool: [], checks: ReviewQueue.checks(modes: modes, env: env), book: book)
        }
        // Merged and rejected candidates aren't asked, nor tough calls of a merged mode.
        #expect(try await queue().candidates.map(\.id) == ["kept"])
        // No judge enabled: the judge's file doesn't count yet.
        #expect(try await queue().toughCalls.isEmpty)
        try ValidationStore(env: env).setJudge(agent, for: "false-premise")
        let calls = try await queue().toughCalls
        #expect(calls.map { "\($0.modeID)|\($0.sessionKey)" } == ["false-premise|claude:a"])
        #expect(try await queue(LabelBook(toughCalls: ["false-premise|claude:a": false])).toughCalls.isEmpty)
    }

    @Test func theQueueHoldsWhatWaitsForTheUser() async throws {
        let store = ModeStore(env: env)
        _ = try await store.create(Mode(id: "new-thing", name: "New thing", definition: "d"))
        var a = try pool("claude:a", notes: (1...12).map { ("n\($0)", "read whole \($0)") })
        a.routes = (1...12).map { Route(noteID: "n\($0)", modeID: "large-file-read-whole", confidence: $0 == 1 ? 0.3 : 0.9, by: .matching) }
        try NotesStore(env: env).save(a)
        let tough = CheckResults(modeID: "large-file-read-whole", verdicts: ["claude:a": CheckVerdict(positive: true, toughCall: true, version: 1)])
        var generator = SeededGenerator(seed: 1)
        let spot = ReviewQueue.pickSpotCheck([a], count: 3, using: &generator)
        #expect(spot.count == 3)
        let queue = ReviewQueue.build(modes: try await store.list(), pool: [a], checks: [tough], book: LabelBook(spotChecks: [spot[0].description: true]),
                                      spotCheck: spot)
        #expect(queue.candidates.map(\.id) == ["new-thing"])
        #expect(queue.routes.count == 1)
        #expect(queue.toughCalls.map(\.sessionKey) == ["claude:a"])
        #expect(queue.spotChecks.count == 2)
        // One seed takes all 12 routed notes: maybe an umbrella.
        #expect(queue.umbrellas.map(\.modeID) == ["large-file-read-whole"])
    }

    @Test func umbrellaSeedsFromARebuild() async throws {
        let modes = try await ModeStore(env: env).list()
        var a = try pool("claude:a", notes: [("n1", "x"), ("n2", "y")])
        a.routes = [Route(noteID: "n1", modeID: "false-premise", confidence: 0.9, by: .matching),
                    Route(noteID: "n2", modeID: "false-premise", confidence: 0.9, by: .matching)]
        let candidates = [Clustering.Candidate(name: "A", kind: .failure, definition: "d", include: [], exclude: [],
                                               notes: [NoteRef(sessionKey: "claude:a", noteID: "n1")]),
                          Clustering.Candidate(name: "B", kind: .failure, definition: "d", include: [], exclude: [],
                                               notes: [NoteRef(sessionKey: "claude:a", noteID: "n2")])]
        #expect(Clustering.umbrellas(candidates, pool: [a], modes: modes) == ["false-premise"])
        #expect(Clustering.umbrellas(Array(candidates.prefix(1)), pool: [a], modes: modes).isEmpty)
    }

    @Test func aLaterRouteReplacesAnAcceptedNoneFits() async throws {
        var a = try pool("claude:a", notes: [("n1", "x")])
        a.routes = [Route(noteID: "n1", modeID: nil, confidence: 0.9, by: .matching, review: .accepted)]
        try NotesStore(env: env).save(a)
        try NotesStore(env: env).update("claude:a") { notes in
            notes.routes?.append(Route(noteID: "n1", modeID: "new-mode", confidence: 1, by: .clustering))
        }
        #expect(Matching.currentRoutes(try #require(NotesStore(env: env).load("claude:a")))["n1"]?.modeID == "new-mode")
    }

    @Test func lockedUpdatesFromManyWritersLoseNothing() async throws {
        _ = try pool("claude:a", notes: [("n1", "x")])
        let env = env
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = try? NotesStore(env: env).update("claude:a") { notes in
                        notes.routes = (notes.routes ?? []) + [Route(noteID: "n\(index)", modeID: nil, confidence: 1, by: .human)]
                    }
                }
            }
        }
        #expect(NotesStore(env: env).load("claude:a")?.routes?.count == 20)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask { _ = try? CheckStore(env: env).update("m") { $0.verdicts["s\(index)"] = CheckVerdict(positive: true, version: 1) } }
            }
        }
        #expect(CheckStore(env: env).load("m")?.verdicts.count == 20)
    }

    @Test func promotionNeedsANewAcceptedCase() async throws {
        let store = ModeStore(env: env)
        _ = try await store.create(Mode(id: "cand", name: "Cand", definition: "d"))
        var a = try pool("claude:a", notes: [("n1", "x"), ("n2", "y")])
        a.routes = [Route(noteID: "n1", modeID: "cand", confidence: 1, by: .clustering),
                    // Matching again in a session it was made from: not a new case.
                    Route(noteID: "n2", modeID: "cand", confidence: 0.9, by: .matching)]
        try NotesStore(env: env).save(a)
        var b = try pool("claude:b", notes: [("n1", "z")])
        // A new session, but at low confidence and not accepted yet.
        b.routes = [Route(noteID: "n1", modeID: "cand", confidence: 0.4, by: .matching)]
        try NotesStore(env: env).save(b)
        #expect(try await Clustering.promoteCandidates(store: store, env: env).isEmpty)
        try Matching.review(NoteRef(sessionKey: "claude:b", noteID: "n1"), accept: true, env: env)
        #expect(try await Clustering.promoteCandidates(store: store, env: env).map(\.id) == ["cand"])
    }

    @Test func anUnreadableFileIsNeverReplaced() throws {
        let book = home.appending(path: ".akit/lab/analysis/labels/book.json")
        try fm.createDirectory(at: book.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: book)
        #expect(throws: (any Error).self) { _ = try LabelBookStore(env: env).update { $0.spotChecks["x"] = true } }
        #expect(try String(contentsOf: book, encoding: .utf8) == "{ broken")
    }
}
