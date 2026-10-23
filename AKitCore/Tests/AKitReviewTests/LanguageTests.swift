import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

/// The comments' language: Czech by default, and only Czech goes to GitLab (`ReviewLanguage`).
struct ReviewLanguageTests {
    @Test func onlyCzechTextCounts() {
        #expect(ReviewLanguage.isCzech("**Neošetřená chyba při ukládání**\n\nKdyž `save()` selže, uživatel nevidí chybu a data se ztratí.", marker: "🤖"))
        #expect(ReviewLanguage.isCzech("Tady chybí kontrola.", marker: "🤖"))
        #expect(ReviewLanguage.isCzech("Chybí kontrola, hodnota může být nil.", marker: "🤖"))
        #expect(ReviewLanguage.isCzech("Race condition: dva thready zapisují do cache bez locku.", marker: "🤖"), "jargon stays Czech")
        #expect(ReviewLanguage.isCzech("🤖 Zdá se, že je to opraveno v commitu abc1234567.", marker: "🤖"))
        #expect(!ReviewLanguage.isCzech("**Unhandled error on save**\n\nWhen `save()` fails, the user sees no error and the data is lost.", marker: "🤖"))
        #expect(!ReviewLanguage.isCzech("Здесь нет проверки ошибки.", marker: "🤖"))
        #expect(!ReviewLanguage.isCzech("Toto je chyba v kóde, používateľ uvidí chybu.", marker: "🤖"), "Slovak isn't Czech")
        // AKit's Czech header line doesn't carry an English body through.
        #expect(!ReviewLanguage.isCzech("🤖 · `bug-hunter` · **vysoká** · jistota 0.90\n\n**Unhandled error on save**\n\nWhen `save()` fails, "
                                        + "the user sees no error and the data is lost.", marker: "🤖"))
        // Only AKit's first line is its header: an English line made to look like one still counts.
        #expect(!ReviewLanguage.isCzech("Tady je problém.\n🤖 · When save fails, the user sees no error and the data is lost for good.",
                                        marker: "🤖"))
        // Code alone has no language.
        #expect(ReviewLanguage.isCzech("```suggestion\nlet x = 1\n```", marker: "🤖"))
    }

    @Test func czechIsTheDefaultAndALevelMayChangeIt() throws {
        let spec = try PlanTests.spec()
        #expect(spec.posting.language == Sourced("cs", .builtIn) && spec.posting.languageCode == "cs")
        #expect(try ReviewSettingsPatch.parse(["posting": ["language": "en"]], where: "t").language == "en")
        #expect(throws: (any Error).self) { try ReviewSettingsPatch.parse(["posting": ["language": "Czech"]], where: "t") }
        let system = ReviewPrompts.system(spec: spec, hasWorktree: true)
        #expect(system.contains("in Czech (`cs`)"))
        #expect(ReviewPrompts.verifier(candidates: "", brief: nil, spec: spec).contains("Write every note in Czech"))
    }

    @Test func akitsOwnWordsInADraftAreCzech() throws {
        let plan = try PlanTests.plan([PlanTests.finding("f1", title: "Chybí kontrola vstupu")], spec: try PlanTests.spec())
        let create = try #require(plan.requests.first { $0.kind == .create })
        #expect(create.proposed.hasPrefix("🤖 · `bug-hunter` · **vysoká** · jistota 0,90"))
        let summary = try #require(plan.requests.first { $0.kind == .summary }).proposed
        #expect(summary.contains("souhrn · scénář **bugfix**") && summary.contains("1 komentář k řádkům diffu."))
        #expect(summary.contains("Zkontrolovaný commit h123456789"))
    }
}

extension ReviewProcessTests {
    struct LanguageSendTests {
        /// Send refuses a draft that isn't Czech, an edit too; nothing reaches the send pass.
        @Test func sendRefusesTextThatIsntCzech() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            let create = try #require(ReviewWorkflow.load(run.folder).plan?.requests.first { $0.kind == .create })
            try ReviewWorkflow.decide(run.folder, request: create.id, decision: .approved,
                                      edited: "The token reaches the log: anyone who reads the log store can sign in as the user.")
            let report = try await ReviewWorkflow.send(run.folder, env: run.home.env)
            #expect(report.sent.isEmpty && report.failed.first?.message.hasPrefix("Not in Czech") == true)
            #expect(run.args("send-1").isEmpty, "no send pass for it")
        }
    }
}
