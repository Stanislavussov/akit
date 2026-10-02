import Foundation
import AKitSessions

/// A session cut down to fit one model call without cutting away the evidence
/// (`docs/design/error-analysis.md`, "Digest"): numbered items, thinking left out, user
/// turns verbatim, and long tool output shortened to its start and end plus a stub that
/// keeps the exit code, the error lines and the number of failed tests.
/// The items are already masked by the session readers.
public enum EvidenceDigest {
    public struct Output: Sendable, Hashable {
        public let text: String
        /// The digest is longer than the budget: user turns and failed tools' stubs alone
        /// don't fit, and those are never dropped. Callers don't send such a digest.
        public let overBudget: Bool
        /// Characters each other item was cut to (tool calls get half); the longest item's
        /// length when nothing was cut.
        let cap: Int
    }

    /// About 90K tokens: fits every current model with room for the answer.
    public static let defaultBudget = 360_000
    /// About 250K tokens, under the 272K-token input target for 1M-token windows.
    public static let largeBudget = 1_000_000
    /// No item is cut shorter than this; below it the middle of the session goes instead.
    static let floorCap = 80

    /// Characters a model can read in one call. A small table on purpose: 1M-token Claude
    /// variants (`opus[1m]`, `…-1m`) and the GPT and Gemini families have large windows;
    /// anything else, or no model (the harness's default), gets the safe default.
    /// Pi names models `provider/model`, so only the part after the last `/` counts.
    public static func budget(model: String?) -> Int {
        guard let model = model?.lowercased(), !model.isEmpty else { return defaultBudget }
        let name = model.split(separator: "/").last.map(String.init) ?? model
        let large = name.contains("[1m]") || name.contains("1m") || name.hasPrefix("gpt-") || name.hasPrefix("gemini")
        return large ? largeBudget : defaultBudget
    }

    public static func text(_ transcript: SessionTranscript, budget: Int = defaultBudget) -> Output {
        let entries = transcript.items.compactMap(Entry.init)
        let userChars = size(entries.filter(\.isUser).map { $0.line(cap: .max) })
        let others = entries.filter { !$0.isUser }
        func fits(_ cap: Int) -> Bool { userChars + size(others.map { $0.line(cap: cap) }) <= budget }

        // The largest cap that fits: at `high` nothing is cut. `fits(low)` holds throughout, so
        // the result always fits even where a longer cap makes a line shorter (an uncut item).
        let high = max(floorCap, others.map(\.length).max() ?? 0)
        if fits(high) { return output(entries.map { $0.line(cap: high) }, budget: budget, cap: high) }
        if fits(floorCap) {
            var low = floorCap
            var top = high
            while top - low > 1 {
                let mid = low + (top - low) / 2
                if fits(mid) { low = mid } else { top = mid }
            }
            return output(entries.map { $0.line(cap: low) }, budget: budget, cap: low)
        }
        return output(droppingMiddle(entries, budget: budget), budget: budget, cap: floorCap)
    }

    /// Even the floor doesn't fit: keep the start and the end, where the task and the outcome
    /// are, and from the middle only user turns and the stubs of failed tool results.
    static func droppingMiddle(_ entries: [Entry], budget: Int) -> [String] {
        let lines = entries.map { $0.line(cap: floorCap) }
        let kept = entries.map { $0.isUser || $0.failed }
        let marker = 48 // "[… N items left out …]" and its newline
        let runs = kept.filter { $0 }.count + 1
        var room = budget - size(zip(lines, kept).filter(\.1).map(\.0)) - runs * marker
        let rest = lines.indices.filter { !kept[$0] }
        var front = 0
        var half = room / 2
        while front < rest.count, lines[rest[front]].count + 1 <= half {
            half -= lines[rest[front]].count + 1
            room -= lines[rest[front]].count + 1
            front += 1
        }
        var back = rest.count
        while back > front, lines[rest[back - 1]].count + 1 <= room {
            room -= lines[rest[back - 1]].count + 1
            back -= 1
        }
        let dropped = Set(rest[front..<back])
        var result: [String] = []
        var skipped = 0
        for index in lines.indices {
            if dropped.contains(index) { skipped += 1; continue }
            if skipped > 0 { result.append("[… \(skipped) items left out …]"); skipped = 0 }
            result.append(lines[index])
        }
        if skipped > 0 { result.append("[… \(skipped) items left out …]") }
        return result
    }

    private static func output(_ lines: [String], budget: Int, cap: Int) -> Output {
        let text = lines.joined(separator: "\n")
        return Output(text: text, overBudget: text.count > budget, cap: cap)
    }

    private static func size(_ lines: [String]) -> Int { lines.reduce(0) { $0 + $1.count + 1 } }

    /// One transcript item with what doesn't depend on the cap worked out once.
    struct Entry {
        enum Role { case user, call, output, other }

        let label: String
        let role: Role
        let text: String
        let length: Int
        /// For tool output only, from the whole text; shown when the output is cut.
        let stub: Stub?
        let isError: Bool

        init?(_ item: TranscriptItem) {
            switch item.kind {
            case .thinking: return nil
            case .user: (label, role, isError) = ("#\(item.id) user", .user, false)
            case .assistant: (label, role, isError) = ("#\(item.id) assistant", .other, false)
            case .toolCall(let name): (label, role, isError) = ("#\(item.id) call \(name)", .call, false)
            case .toolResult(let name, let error):
                (label, role, isError) = ("#\(item.id) \(error ? "error" : "result")\(name.map { " \($0)" } ?? "")", .output, error)
            case .event(let title):
                // Shell commands the user ran themselves carry output too.
                let output = ["Shell", "Shell output", "Command output"].contains(title)
                (label, role, isError) = ("#\(item.id) event \(title)", output ? .output : .other, false)
            }
            text = item.text
            length = item.text.count
            stub = role == .output ? Stub(item.text) : nil
        }

        var isUser: Bool { role == .user }
        /// A failed tool result: its stub is evidence and survives every cut.
        var failed: Bool { isError || (stub?.failed ?? false) }

        func line(cap: Int) -> String {
            let body = switch role {
            case .user: text
            case .call: cut(cap / 2)
            case .other: cut(cap)
            case .output: cutOutput(cap)
            }
            return "[\(label)] \(body)"
        }

        private func cut(_ limit: Int) -> String {
            guard length > limit else { return text }
            return "\(text.prefix(limit)) […\(length - limit) chars]"
        }

        /// Start and end (errors come last), with the stub on the same line after the cut.
        private func cutOutput(_ limit: Int) -> String {
            guard length > limit else { return text }
            let stubText = stub.map(\.text).flatMap { $0.isEmpty ? nil : " {\($0)}" } ?? ""
            return "\(text.prefix(limit / 2)) […\(length - limit / 2 * 2) chars…]\(stubText) \(text.suffix(limit / 2))"
        }
    }

    /// What a long tool output must never lose: `exit 1; 3 failed tests; errors: "…" | "…"`.
    struct Stub {
        var exitCode: Int?
        var failedTests: String?
        var errors: [String] = []

        static let errorLineLimit = 200
        static let errorLines = 20

        init(_ output: String) {
            exitCode = Self.firstInt(Self.exitCode, in: output)
            failedTests = Self.failedTests(in: output)
            var seen = Set<String>()
            for line in output.split(whereSeparator: \.isNewline) where errors.count < Self.errorLines {
                guard ["error", "fail", "warn"].contains(where: { line.range(of: $0, options: .caseInsensitive) != nil })
                else { continue }
                var short = line.trimmingCharacters(in: .whitespaces)
                if short.count > Self.errorLineLimit { short = String(short.prefix(Self.errorLineLimit)) + "…" }
                if seen.insert(short).inserted { errors.append(short) }
            }
        }

        var failed: Bool { (exitCode ?? 0) != 0 || failedTests != nil }

        var text: String {
            var parts: [String] = []
            if let exitCode { parts.append("exit \(exitCode)") }
            if let failedTests { parts.append(failedTests) }
            if !errors.isEmpty { parts.append("errors: " + errors.map { "\"\($0)\"" }.joined(separator: " | ")) }
            return parts.joined(separator: "; ")
        }

        /// Claude Code's `Exit code 1`, `exit code: 1`, `exited with code 1`,
        /// `Command failed with exit code 1`, Go's `exit status 1`.
        static let exitCode = regex(#"(?i)\bexit(?:ed with)? (?:code|status):? ?(-?\d+)"#)
        static let swiftTestingTest = regex(#"✘ Test (?!run with).* failed after"#)
        static let swiftTestingRun = regex(#"✘ Test run with \d+ tests?.* failed .*with (\d+) issues?"#)
        static let xcTest = regex(#"Executed \d+ tests?, with (\d+) failures?"#)
        static let pytest = regex(#"=+ .*?\b(\d+) failed"#)
        static let jest = regex(#"Tests:?\s+(\d+) failed"#)
        static let cargo = regex(#"test result: FAILED\. \d+ passed; (\d+) failed"#)
        static let goFail = regex(#"(?m)^\s*--- FAIL:"#)

        /// The first count a known test runner reports, as "N failed tests".
        static func failedTests(in output: String) -> String? {
            let failures = [
                count(swiftTestingTest, in: output),
                lastInt(xcTest, in: output),
                lastInt(pytest, in: output),
                lastInt(jest, in: output),
                sumInts(cargo, in: output),
                count(goFail, in: output),
            ].lazy.compactMap { $0 }.first { $0 > 0 }
            if let failures { return "\(failures) failed test\(failures == 1 ? "" : "s")" }
            // Swift Testing's summary counts issues; a test can have several.
            if let issues = lastInt(swiftTestingRun, in: output), issues > 0 {
                return "\(issues) test issue\(issues == 1 ? "" : "s")"
            }
            return nil
        }

        static func regex(_ pattern: String) -> NSRegularExpression {
            // The patterns are literals above; a typo fails every test that cuts output.
            try! NSRegularExpression(pattern: pattern)
        }

        private static func ints(_ regex: NSRegularExpression, in text: String) -> [Int] {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
            }
        }

        static func firstInt(_ regex: NSRegularExpression, in text: String) -> Int? { ints(regex, in: text).first }
        static func lastInt(_ regex: NSRegularExpression, in text: String) -> Int? { ints(regex, in: text).last }
        static func sumInts(_ regex: NSRegularExpression, in text: String) -> Int? {
            let values = ints(regex, in: text)
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        static func count(_ regex: NSRegularExpression, in text: String) -> Int {
            regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
    }
}
