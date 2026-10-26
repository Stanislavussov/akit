import AKitFoundation
import AKitLab
import Foundation

/// What a run did, for the user to analyse after it (Review → a run → Log…, `akit review log`):
/// each Pi pass with its model, thinking, time, tokens and credits, the MCP calls and the calls
/// AKit blocked, and what each role found. Read from the run folder; texts masked.
public struct ReviewRunLog: Codable, Sendable {
    public struct Pass: Codable, Sendable, Hashable, Identifiable {
        public var id: String { name + "@" + String(started.timeIntervalSince1970) }
        public var name: String
        public var role: String?
        /// Empty = Pi's default model.
        public var model: String
        public var thinking: String
        public var started: Date
        public var seconds: Double?
        public var usage: SendUsage
        public var credits: Double
        public var filesRead: Int
        public var mcpCalls: Int
        public var mcpErrors: Int
        public var blocked: Int
        public var error: String?
        /// The Pi session file, relative to the run folder; nil when Pi wrote none.
        public var session: String?
    }

    public struct Call: Codable, Sendable, Hashable {
        public var pass: String
        public var server: String
        public var tool: String
        public var isError: Bool
        /// The arguments, masked and cut.
        public var input: String
        /// How long the answer was, in characters.
        public var answer: Int
    }

    public struct Blocked: Codable, Sendable, Hashable {
        public var pass: String
        public var tool: String
        public var reason: String
    }

    /// What one role's findings became.
    public struct Role: Codable, Sendable, Hashable {
        public var role: String
        public var found = 0
        public var confirmed = 0
        public var rejected = 0
        public var questions = 0
        public var merged = 0
        public var preExisting = 0
        public var inline = 0
    }

    public var run: String
    public var target: String
    public var head: String?
    public var scenario: String
    public var passesModel: String
    public var passesThinking: String
    public var verifierModel: String
    public var verifierThinking: String
    public var estimate: Double?
    public var credits: Double
    public var cap: Int
    public var seconds: Double?
    public var passes: [Pass]
    public var calls: [Call]
    public var blocked: [Blocked]
    public var roles: [Role]
    public var gaps: [String]

    public static func load(_ folder: URL) throws -> ReviewRunLog {
        let run = try ReviewWorkflow.load(folder)
        let spec = run.spec
        let calls = ReviewMCPData.calls(in: folder).map { call in
            Call(pass: call.pass, server: call.server ?? Self.server(of: call.tool), tool: call.tool, isError: call.isError,
                 input: String(SecretFilter.masked(call.input).prefix(300)), answer: call.fullText.map(\.count).reduce(0, +))
        }
        let blocked = Self.blocked(in: folder)
        let passes = (run.passes?.passes ?? []).map { record in
            let verifier = record.name == "verifier" || record.name == "discuss"
            return Pass(name: record.name, role: record.role, model: record.model,
                        thinking: (verifier ? spec.verifier : spec.passes).value.thinking, started: record.started,
                        seconds: record.ended.map { $0.timeIntervalSince(record.started) }, usage: record.usage, credits: record.credits,
                        filesRead: record.paths.count, mcpCalls: calls.filter { $0.pass == record.name }.count,
                        mcpErrors: calls.filter { $0.pass == record.name && $0.isError }.count,
                        blocked: blocked.filter { $0.pass == record.name }.count, error: record.error.map { SecretFilter.masked($0) },
                        session: record.session.flatMap { Self.sessionFile($0, folder: folder) })
        }
        let placements = Dictionary((run.plan?.placements ?? []).map { ($0.findingID, $0.place) }, uniquingKeysWith: { a, _ in a })
        var roles: [String: Role] = [:]
        for finding in run.findings?.findings ?? [] {
            var role = roles[finding.role] ?? Role(role: finding.role)
            role.found += 1
            switch finding.verifier?.verdict {
            case .confirmed: role.confirmed += 1
            case .rejected: role.rejected += 1
            case .question: role.questions += 1
            case .merged: role.merged += 1
            case nil: break
            }
            if finding.isPreExisting { role.preExisting += 1 }
            if placements[finding.id] == .inline { role.inline += 1 }
            roles[finding.role] = role
        }
        let started = passes.map(\.started).min()
        let ended = (run.passes?.passes ?? []).compactMap(\.ended).max()
        return ReviewRunLog(
            run: run.id, target: spec.local.map { "\($0.repository) (local)" } ?? spec.mergeRequest.label, head: spec.headSHA,
            scenario: spec.scenario.value, passesModel: spec.passes.value.model, passesThinking: spec.passes.value.thinking,
            verifierModel: spec.verifier.value.model, verifierThinking: spec.verifier.value.thinking, estimate: run.passes?.estimate,
            credits: run.passes?.credits ?? 0, cap: spec.capCredits.value,
            seconds: started.flatMap { start in ended.map { $0.timeIntervalSince(start) } }, passes: passes, calls: calls, blocked: blocked,
            roles: roles.values.sorted { $0.role < $1.role },
            gaps: run.gaps.map { SecretFilter.masked("\($0.needed): \($0.why) (\($0.reportedBy))") })
    }

    /// `mcp__gitlab__get_merge_request` → `gitlab`, for calls saved before the extension named the server.
    static func server(of tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return "" }
        let rest = tool.dropFirst(5)
        return rest.range(of: "__").map { String(rest[..<$0.lowerBound]) } ?? ""
    }

    static func blocked(in folder: URL) -> [Blocked] {
        struct Line: Decodable { var pass: String?; var tool: String; var reason: String }
        guard let data = try? Data(contentsOf: folder.appending(path: "mcp/blocked.jsonl")) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(Line.self, from: Data($0)) }
            .map { Blocked(pass: $0.pass ?? "", tool: $0.tool, reason: SecretFilter.masked($0.reason)) }
    }

    static func sessionFile(_ id: String, folder: URL) -> String? {
        ReviewPasses.sessionFile(id: id, in: folder.appending(path: "sessions")).map { url in
            url.path.hasPrefix(folder.path + "/") ? String(url.path.dropFirst(folder.path.count + 1)) : url.lastPathComponent
        }
    }

    // MARK: - Text

    public static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let whole = Int(seconds.rounded())
        return whole >= 60 ? "\(whole / 60)m \(String(format: "%02d", whole % 60))s" : "\(whole)s"
    }

    /// US dollars as Pi recorded them for the passes (`usage.cost`); nil when none recorded any.
    public var cost: Double? { Self.sum(passes.map(\.usage.cost)) }

    static func sum(_ costs: [Double?]) -> Double? {
        let recorded = costs.compactMap { $0 }
        return recorded.isEmpty ? nil : recorded.reduce(0, +)
    }

    /// `$0.42`, `$0.004`, `$12.30`; "—" when Pi recorded no cost. Never a price AKit made up.
    public static func dollars(_ cost: Double?) -> String {
        guard let cost else { return "—" }
        return String(format: cost > 0 && cost < 0.1 ? "$%.3f" : "$%.2f", cost)
    }

    public static func tokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : String(count)
    }

    static func model(_ model: String, _ thinking: String) -> String {
        (model.isEmpty ? "Pi's default model" : model) + (thinking.isEmpty ? "" : " · thinking \(thinking)")
    }

    /// The servers the calls went to, most calls first: `gitlab 14, context7 3`.
    public var callsByServer: String {
        var counts: [String: Int] = [:]
        for call in calls { counts[call.server.isEmpty ? "?" : call.server, default: 0] += 1 }
        return counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    /// Markdown for analysis (Copy for Analysis, `akit review log`): no secrets, no MCP
    /// arguments (they name projects, work items, queries: work data) and no answers, only their
    /// size. `--json` and the Log window keep the masked arguments.
    public var markdown: String {
        var lines = ["# AKit review run \(run)", "",
                     "- Target: \(target)" + (head.map { " at \($0.prefix(10))" } ?? ""),
                     "- Scenario: \(scenario)",
                     "- Passes model: " + Self.model(passesModel, passesThinking),
                     "- Verifier model: " + Self.model(verifierModel, verifierThinking),
                     String(format: "- Credits: %.1f of %d", credits, cap) + (estimate.map { String(format: " (estimated %.0f)", $0) } ?? ""),
                     "- Cost: " + (cost.map { Self.dollars($0) + " (as Pi recorded it)" } ?? "Pi recorded none"),
                     "- Time: " + Self.duration(seconds), "",
                     "## Passes", "",
                     "| Pass | Model | Thinking | Time | Input | Cached | Output | Credits | Cost | Files | MCP calls | Blocked | Error |",
                     "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for pass in passes {
            let cells = [pass.name, pass.model.isEmpty ? "Pi's default" : pass.model, pass.thinking.isEmpty ? "—" : pass.thinking,
                         Self.duration(pass.seconds), Self.tokens(pass.usage.input), Self.tokens(pass.usage.cached), Self.tokens(pass.usage.output),
                         String(format: "%.1f", pass.credits), Self.dollars(pass.usage.cost), String(pass.filesRead),
                         "\(pass.mcpCalls)" + (pass.mcpErrors > 0 ? " (\(pass.mcpErrors) failed)" : ""), String(pass.blocked),
                         pass.error ?? ""]
            lines.append("| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: " | ") + " |")
        }
        if !roles.isEmpty {
            lines += ["", "## Findings by role", "", "| Role | Found | Confirmed | Rejected | Questions | Merged | Before the MR | Inline |",
                      "|---|---|---|---|---|---|---|---|"]
            lines += roles.map { "| \($0.role) | \($0.found) | \($0.confirmed) | \($0.rejected) | \($0.questions) | \($0.merged) | \($0.preExisting) | \($0.inline) |" }
        }
        lines += ["", calls.isEmpty ? "## MCP calls: none" : "## MCP calls (\(calls.count): \(callsByServer))", ""]
        lines += calls.map { "- \($0.pass) · \($0.tool)\($0.isError ? " · failed" : "") · answer \($0.answer) chars" }
        if !blocked.isEmpty {
            if !calls.isEmpty { lines.append("") }
            lines += ["## Blocked by AKit (\(blocked.count))", ""]
            lines += blocked.map { "- \($0.pass) · \($0.tool): \($0.reason)" }
        }
        if !gaps.isEmpty {
            lines += ["", "## Context gaps (\(gaps.count))", ""]
            lines += gaps.map { "- \($0)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
