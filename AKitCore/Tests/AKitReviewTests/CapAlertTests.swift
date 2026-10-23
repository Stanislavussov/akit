@testable import AKitReview
import Foundation
import Testing

extension ReviewProcessTests {
    struct CapAlertTests {
        /// A pass that takes the run's credits over the cap alerts once; later passes don't again.
        @Test func passingTheCapAlertsOnce() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            let spent = ReviewJSON.read(ReviewPassLog.self, from: run.folder.appending(path: "passes.json"))?.credits ?? 0
            var spec = try #require(ReviewJSON.read(ReviewRunSpec.self, from: run.folder.appending(path: "run.json")))
            // Above what the fetch spent and the estimate, below what the passes spend.
            spec.capCredits = .init(Int(spent) + 1, .run)
            try ReviewJSON.write(spec, to: run.folder.appending(path: "run.json"))
            let alerts = LockedBox<[String]>([])
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env,
                                           options: .init(alert: { message in alerts.update { $0.append(message) } }))
            let total = ReviewJSON.read(ReviewPassLog.self, from: run.folder.appending(path: "passes.json"))?.credits ?? 0
            #expect(total > Double(spec.capCredits.value), "the passes went over the cap")
            #expect(alerts.value.filter { $0.contains("credits spent, over the cap of \(spec.capCredits.value)") }.count == 1)
        }
    }
}
