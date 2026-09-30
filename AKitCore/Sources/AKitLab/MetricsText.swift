import Foundation

/// Metrics as plain text, for `akit lab analyze` and the end of a run in its terminal tab.
public enum MetricsText {
    public static func lines(_ metrics: SessionMetrics) -> [String] {
        var lines: [String] = []
        func add(_ label: String, _ value: String) { lines.append(label.padding(toLength: 14, withPad: " ", startingAt: 0) + value) }
        let subagents = metrics.subagentCalls > 0 ? " (subagents \(metrics.subagentCalls))" : ""
        add("Calls", "\(metrics.calls)\(subagents)")
        var tokens = "fresh \(short(metrics.freshTokens))"
        if metrics.subagentFreshTokens > 0 { tokens += " (subagents \(short(metrics.subagentFreshTokens)))" }
        tokens += " · cache reads \(short(metrics.cacheReadTokens)) · output \(short(metrics.outputTokens))"
        add("Tokens", tokens)
        add("Context", "baseline \(short(metrics.baselineContext)) · peak \(short(metrics.peakContext))")
        let rent = metrics.contextRent
        if rent.total > 0 {
            add("Context rent", [("baseline", rent.baseline), ("reading code", rent.readCode), ("own output", rent.ownOutput),
                                 ("injections", rent.injections), ("other", rent.other)]
                .map { "\($0.0) \(percent(rent.share($0.1)))" }.joined(separator: " · "))
        }
        add("Tools", "\(metrics.toolCalls) calls · \(metrics.toolErrors) failed · \(metrics.rereads) re-reads · "
            + "\(metrics.rejected) rejected · \(metrics.interrupts) interrupts"
            + (metrics.compactions > 0 ? " · \(metrics.compactions) compactions" : ""))
        if !metrics.commits.isEmpty {
            let unmerged = metrics.unmergedCommits
            add("Commits", "\(metrics.commits.count)" + (unmerged > 0 ? " (\(unmerged) not on the main branch)" : ""))
            for commit in metrics.commits {
                let place = switch commit.onMainBranch {
                case true?: "on main"
                case false?: "not on main"
                case nil: "main branch unknown"
                }
                lines.append("  \(commit.sha.prefix(9)) \(commit.subject)  [\(place)]")
            }
        }
        var time: [String] = []
        if let wall = metrics.wallSeconds { time.append("wall \(duration(wall))") }
        if let active = metrics.activeSeconds { time.append("active \(duration(active))") }
        if !time.isEmpty { add("Time", time.joined(separator: " · ")) }
        if !metrics.models.isEmpty { add("Models", metrics.models.joined(separator: ", ")) }
        return lines
    }

    /// 1234 → "1.2K", 24_900_000 → "24.9M".
    public static func short(_ value: Int) -> String { value.formatted(.number.notation(.compactName).locale(Locale(identifier: "en_US"))) }

    public static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }

    public static func duration(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }
}
