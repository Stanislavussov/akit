import AKitFoundation
import AKitLab
@testable import AKitReview
import Foundation
import Testing

extension ReviewProcessTests {
    /// Why Missed? (R62): AKit traces a missed item through the run, Pi reads the run and says
    /// why; follow-up questions fork the item's last answer.
    struct WhyMissedTests {
        func playedRun() async throws -> ReviewRunFixture {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            return run
        }

        @Test func theTraceSaysWhatTheRolesSubmittedInTheFileAndWhatBecameOfIt() async throws {
            let run = try await playedRun()
            let item = try ReviewWorkflow.addMissed(run.folder, file: "src/Auth.swift", line: 4, text: "The token is compared in non-constant time")
            #expect(item.id == "m1")
            let trace = try ReviewWhyMissed.trace(run.folder, missed: item)
            let text = trace.joined(separator: "\n")
            #expect(text.contains("roles: bug-hunter"), "\(text)")
            #expect(text.contains("src/Auth.swift is in the change") || text.contains("src/Auth.swift:4 is in the change"), "\(text)")
            #expect(text.contains("Passes that opened src/Auth.swift with read: none"), "\(text)")
            #expect(text.contains("role-tests at line 3 (near): “hlavička se CELÁ zapisuje do logu!”") && text.contains("folded into f1"), "\(text)")
            #expect(text.contains("role-bug-hunter at line 9 (near)") && text.contains("became f1, verifier: confirmed"), "\(text)")

            // Lines within 10 of the missed one come first.
            let lower = try ReviewWorkflow.addMissed(run.folder, file: "src/Auth.swift", line: 14, text: "y")
            let ordered = try ReviewWhyMissed.trace(run.folder, missed: lower).filter { $0.hasPrefix("  - ") }
            #expect(ordered.first?.contains("role-bug-hunter at line 9 (near)") == true && ordered.last?.contains("role-tests at line 3:") == true, "\(ordered)")

            let elsewhere = try ReviewWorkflow.addMissed(run.folder, file: "src/Other.swift", line: nil, text: "No test for the retry")
            let other = try ReviewWhyMissed.trace(run.folder, missed: elsewhere).joined(separator: "\n")
            #expect(other.contains("src/Other.swift is not in the change") && other.contains("No role submitted anything in src/Other.swift"), "\(other)")
            let whole = try ReviewWorkflow.addMissed(run.folder, file: nil, line: nil, text: "No migration")
            #expect(try ReviewWhyMissed.trace(run.folder, missed: whole).joined(separator: "\n").contains("named no file"))
        }

        @Test func piReadsTheRunAndFollowUpsGoOnInTheSameThread() async throws {
            let run = try await playedRun()
            let item = try ReviewWorkflow.addMissed(run.folder, file: "src/Auth.swift", line: 4, text: "Token compared in non-constant time")
            let first = try await ReviewWhyMissed.ask(run.folder, missed: item.id, env: run.home.env)
            #expect(first.id == "w1" && first.missed == "m1" && first.question.isEmpty)
            #expect(first.answer == "Intent: log less." && first.error == nil && first.model == "fake/strong" && first.credits > 0)
            let args = run.args("debug-why-1")
            for flag in ["--no-mcp", "--no-skills", "--no-extensions", "fake/strong", "read,grep,find,ls", "--session-id"] {
                #expect(args.contains(flag), "\(flag)")
            }
            #expect(!args.contains("--fork"))
            let message = args.joined(separator: "\n")
            #expect(message.contains("Token compared in non-constant time") && message.contains("AKit's trace of it"))
            #expect(message.contains("What the roles submitted in src/Auth.swift"))
            let env = try String(contentsOf: run.home.url.appending(path: "fake/env-debug-why-1.txt"), encoding: .utf8)
            let roots = try #require(env.split(separator: "\n").first { $0.hasPrefix("AKIT_REVIEW_ROOTS=") })
            #expect(roots.contains("/debug") && roots.contains("/context") && !roots.contains("/gitlab") && !roots.contains("/tracker"))
            #expect(env.contains(#""inPasses":false"#))
            #expect(FileManager.default.fileExists(atPath: run.folder.appending(path: "debug/full-log.md").path))
            #expect(try String(contentsOf: run.folder.appending(path: "debug/full-log.md"), encoding: .utf8).contains("- m1 src/Auth.swift:4: Token"))
            #expect(SendLog.records(env: run.home.env).contains { $0.purpose == "review-why-missed" && $0.runID == run.folder.lastPathComponent })

            // A follow-up needs a question and forks the item's last answer.
            await #expect(throws: ReviewWhyMissed.Failure.self) { try await ReviewWhyMissed.ask(run.folder, missed: item.id, env: run.home.env) }
            let second = try await ReviewWhyMissed.ask(run.folder, missed: item.id, question: "  Which role should own this? ", env: run.home.env)
            #expect(second.id == "w2" && second.question == "Which role should own this?")
            let follow = run.args("debug-why-2")
            let fork = try #require(follow.firstIndex(of: "--fork"))
            #expect(follow[fork + 1].contains("why-missed/sessions/") && !follow.contains("--session-id"))
            #expect(follow.last == "Which role should own this?", "a follow-up sends only the question")
            #expect(ReviewWhyMissed.entries(run.folder).map(\.id) == ["w1", "w2"])

            // The run's findings and numbers stay those of the review.
            let log = try #require(ReviewJSON.read(ReviewPassLog.self, from: run.folder.appending(path: "passes.json")))
            #expect(!log.passes.contains { $0.name.hasPrefix("debug") })
            #expect(try #require(ReviewJSON.read(ReviewFindingsFile.self, from: run.folder.appending(path: "findings.json"))).version == 1)
            #expect(!(try ReviewDebug.checks(run.folder)).contains { $0.title.contains("debug-why") })

            await #expect(throws: ReviewWhyMissed.Failure.self) { try await ReviewWhyMissed.ask(run.folder, missed: "m9", env: run.home.env) }
        }

        @Test func pathsMatchOnWholeNamesAndNeverAcrossALinkedMergeRequest() {
            #expect(ReviewWhyMissed.same("src/Auth.swift", "src/Auth.swift") && ReviewWhyMissed.same("./src/Auth.swift", "src/Auth.swift"))
            #expect(ReviewWhyMissed.same("/tmp/wt/src/Auth.swift", "src/Auth.swift"))
            #expect(!ReviewWhyMissed.same("src/OAuth.swift", "Auth.swift") && !ReviewWhyMissed.same("@web/src/Auth.swift", "src/Auth.swift"))
            #expect(ReviewWhyMissed.inPatch("--- a/src/Auth.swift\n+++ b/src/Auth.swift\n@@ -1 +1 @@", file: "src/Auth.swift"))
            #expect(!ReviewWhyMissed.inPatch("+++ b/src/OAuth.swift\n", file: "Auth.swift"))
        }

        /// The fates name AKit's own reasons: the role's floor, invalid fields.
        @Test func droppedCandidatesSayWhy() async throws {
            let run = try await playedRun()
            // bug-hunter's floor is above nit; a candidate without confidence is invalid.
            try Data(#"{"findings":[{"file":"src/Auth.swift","line":5,"title":"Tiny","evidence":"x","why":"y","severity":"nit","confidence":0.9},{"file":"src/Auth.swift","line":6,"title":"No confidence","evidence":"x","why":"y","severity":"high"}]}"#.utf8)
                .write(to: run.folder.appending(path: "passes/role-bug-hunter.json"))
            let item = try ReviewWorkflow.addMissed(run.folder, file: "src/Auth.swift", line: 5, text: "x")
            let text = try ReviewWhyMissed.trace(run.folder, missed: item).joined(separator: "\n")
            #expect(text.contains("“Tiny” · nit · 0.90 → dropped by AKit: nit is below the role's floor"), "\(text)")
            #expect(text.contains("“No confidence” · high → dropped by AKit: a required field was missing or wrong"), "\(text)")
        }

        /// A failed answer is no thread to go on from: the next "why" starts afresh.
        @Test func aFailedAnswerIsNotForked() async throws {
            let run = try await playedRun()
            let item = try ReviewWorkflow.addMissed(run.folder, file: "src/Auth.swift", line: 4, text: "x")
            run.home.write("fake/fail-debug-why-1", "")
            let failed = try await ReviewWhyMissed.ask(run.folder, missed: item.id, env: run.home.env)
            #expect(failed.answer == nil && failed.error == "quota exceeded")
            let again = try await ReviewWhyMissed.ask(run.folder, missed: item.id, env: run.home.env)
            #expect(again.id == "w2" && again.answer != nil && !run.args("debug-why-2").contains("--fork"))
        }
    }
}
