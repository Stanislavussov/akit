@testable import AKitReview
import AKitLab
import Foundation
import Testing

/// Dollars only as Pi recorded them (`usage.cost`), never a price AKit made up.
struct ReviewCostTests {
    static func pass(_ name: String, cost: Double?) -> ReviewPassRecord {
        ReviewPassRecord(name: name, role: nil, model: "m", session: nil, started: .now, ended: .now,
                         usage: SendUsage(input: 1000, cached: 0, output: 100, cost: cost), credits: 1.1, paths: [], error: nil)
    }

    @Test func sumsWhatPiRecorded() {
        var log = ReviewPassLog(mainSession: "s")
        #expect(log.cost == nil)
        log.passes = [Self.pass("fetch", cost: nil)]
        #expect(log.cost == nil, "no pass recorded a cost: none, not $0")
        log.passes += [Self.pass("brief", cost: 0.25), Self.pass("verifier", cost: 0.5)]
        #expect(log.cost == 0.75)
    }

    @Test func dollarsText() {
        #expect(ReviewRunLog.dollars(nil) == "—")
        #expect(ReviewRunLog.dollars(0) == "$0.00")
        #expect(ReviewRunLog.dollars(0.004) == "$0.004")
        #expect(ReviewRunLog.dollars(0.42) == "$0.42")
        #expect(ReviewRunLog.dollars(12.3) == "$12.30")
    }
}
