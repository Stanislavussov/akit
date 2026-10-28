import Foundation
import Testing
import AKitFoundation
@testable import AKitCommandLine
@testable import AKitInsights

/// A date range for `akit stats` and `akit stats tools` (Insights → Date Range…): whole local days that can end
/// in the past, where calls after the last day don't count (see `InsightsStatsTests` for the fake index).
extension InsightsStatsTests {
    /// From 20 to 10 days before today, both days included.
    var pastRange: DayRange {
        DayRange(first: Date(timeIntervalSince1970: at(20)), last: Date(timeIntervalSince1970: at(10)))
    }

    @Test func dayRangeBoundsAndParse() throws {
        let range = pastRange
        #expect(range.days() == 11)
        let (from, to) = range.bounds(now: now)
        #expect(from.timeIntervalSince1970 == at(20, 0))
        #expect(to.timeIntervalSince1970 < at(9, 0) && to.timeIntervalSince1970 > at(10, 23.99))
        // A range that ends today ends now.
        let today = DayRange(first: Date(timeIntervalSince1970: at(3)), last: now)
        #expect(today.bounds(now: now).to == now)
        // Swapped days are put in order.
        #expect(DayRange(first: range.last, last: range.first) == range)

        let parsed = try DayRange.parse(from: "2026-09-01", to: "2026-09-10")
        #expect(parsed.days() == 10 && parsed.label() == .init(first: "2026-09-01", last: "2026-09-10"))
        #expect(throws: DayRange.ParseError.self) { try DayRange.parse(from: "2026-9-1x", to: nil) }
        #expect(throws: DayRange.ParseError.self) { try DayRange.parse(from: "2026-09-10", to: "2026-09-01") }
        #expect(throws: DayRange.ParseError.self) { try DayRange.parse(from: "2026-02-30", to: nil) }
    }

    @Test func skillCallsAfterTheRangeDontCount() throws {
        let db = try database()
        try session("old", started: at(25), in: db)
        try listing("old", "gamma", at: at(25), hash: "g", in: db)
        try call("old", "gamma", at: at(25, 13), in: db)
        try session("in", started: at(15), in: db)
        for skill in ["alpha", "beta", "gamma"] { try listing("in", skill, at: at(15), hash: skill, in: db) }
        try call("in", "alpha", at: at(15, 13), in: db)
        // The same session, resumed after the range: beta's call is outside it.
        try call("in", "beta", at: at(5, 13), in: db)
        // A session started after the range is out of scope.
        try session("late", started: at(5), in: db)
        try listing("late", "delta", at: at(5), hash: "d", in: db)

        let report = try report(db, .init(top: nil, range: pastRange))
        #expect(report.window.days == 11 && report.window.range == pastRange.label())
        #expect(report.window.title == "\(pastRange.label().first) – \(pastRange.label().last)")
        #expect(report.summary.sessions == 1)
        #expect(!report.skills.contains { $0.name == "delta" })
        let alpha = try skill("alpha", in: report)
        #expect(!alpha.unused && alpha.modelCalls == 1 && alpha.lastCall == iso(at(15, 13)))
        let beta = try skill("beta", in: report)
        #expect(beta.unused && beta.modelCalls == 0 && beta.lastCall == nil, "a call after the range is no use in it")
        let gamma = try skill("gamma", in: report)
        #expect(gamma.unused && gamma.lastCall == iso(at(25, 13)), "the last call still looks before the range")

        let unusedOnly = try self.report(db, .init(top: nil, unusedOnly: true, range: pastRange))
        #expect(unusedOnly.skills.map(\.name).sorted() == ["beta", "gamma"])

        // Without a range the last 30 days count beta's later call, and the JSON has no range.
        let month = try self.report(db)
        #expect(try !skill("beta", in: month).unused && month.window.range == nil && month.window.title == "Last 30 days")
        #expect(!encode(month).contains("\"range\""))
    }

    @Test func toolCallsAfterTheRangeDontCount() throws {
        let db = try database()
        try session("in", started: at(15), in: db)
        try toolListing("in", ["Read", "Bash", "mcp__docs__search"], at: at(15), in: db)
        try toolCall("in", "Read", at: at(15, 13), in: db)
        try toolCall("in", "Bash", at: at(5, 13), in: db)
        try toolCall("in", "mcp__docs__search", at: at(2, 13), in: db)

        let report = try ToolStats.report(db, range: pastRange, now: now)
        #expect(report.window.days == 11 && report.window.range == pastRange.label())
        #expect(try !tool("Read", in: report).unused)
        let bash = try tool("Bash", in: report)
        #expect(bash.unused && bash.calls == 0 && bash.lastCall == nil)
        #expect(report.servers.first { $0.name == "docs" }?.unused == true)
        #expect(report.summary.calls == 1)

        let month = try tools(db)
        #expect(try !tool("Bash", in: month).unused && month.servers.first { $0.name == "docs" }?.unused == false)
    }

    @Test func statsCommandTakesFromAndTo() async throws {
        let db = try database()
        try session("in", started: at(15), in: db)
        try listing("in", "alpha", at: at(15), hash: "a", in: db)
        try toolListing("in", ["Read"], at: at(15), in: db)
        let label = pastRange.label()

        let skills = await rangeCLI("stats", "--from", label.first, "--to", label.last, "--json")
        #expect(skills.code == 0, "\(skills.err)")
        #expect(skills.out.contains("\"first\" : \"\(label.first)\""))
        let tools = await rangeCLI("stats", "tools", "--from", label.first, "--to", label.last)
        #expect(tools.code == 0 && tools.out.hasPrefix("\(label.first) – \(label.last), "), "\(tools.out) \(tools.err)")

        #expect(await rangeCLI("stats", "--to", label.last).err.contains("--to needs --from"))
        #expect(await rangeCLI("stats", "--days", "3", "--from", label.first).err.contains("don't go together"))
        #expect(await rangeCLI("stats", "skill", "alpha", "--from", label.first).err.contains("go with akit stats, akit stats tools and akit stats listing"))
        #expect(await rangeCLI("stats", "--from", "yesterday").err.contains("--from is a day"))
    }

    func encode(_ report: StatsReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(report)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func rangeCLI(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: home, projectsRoot: home.appending(path: "Projects"), hostName: "TestMac.local",
                                     installedTargets: ["claude"], out: { out.append($0) }, err: { err.append($0) },
                                     trash: { _ in nil }, hardwareHash: { "test-hardware" })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }
}
