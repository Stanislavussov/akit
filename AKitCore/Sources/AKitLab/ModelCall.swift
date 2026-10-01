import AKitFoundation
import AKitSessions
import Foundation

/// One model call with no tools and none of the user's customizations, through a harness
/// and its own sign-in (AKit never reads a harness's keys). Every call that sends session
/// data goes through here: the sending policy, the scrub, the monthly limit and the send log
/// (`docs/design/error-analysis.md`, "Sending policy").
public enum ModelCall {
    public struct Request: Sendable {
        public var agent: LabAgent
        /// review, notes, verifier, matching, clustering, judge, pairing…: for the send log.
        public var purpose: String
        public var system: String
        /// The data, before scrubbing.
        public var input: String
        /// A JSON schema the answer must match. Claude Code checks it; Pi gets it in the prompt.
        public var schema: String?
        public var origin: SendOrigin
        /// The session key or transcript path the input came from.
        public var session: String?
        public var runID: String?

        public init(agent: LabAgent, purpose: String, system: String, input: String, schema: String? = nil, origin: SendOrigin,
                    session: String? = nil, runID: String? = nil) {
            self.agent = agent
            self.purpose = purpose
            self.system = system
            self.input = input
            self.schema = schema
            self.origin = origin
            self.session = session
            self.runID = runID
        }
    }

    public struct Answer: Sendable {
        /// Claude Code's structured output (as JSON text) or result text; Pi's last answer.
        public let text: String
        public let usage: SendUsage
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        /// The provider said "too many requests": worth retrying after a pause.
        public let rateLimited: Bool
        public var errorDescription: String? { message }
    }

    /// Checks, scrubs, sends, logs. Retries a rate-limited call with exponential backoff.
    /// `folder` holds the input file (Pi reads it as `@file`) for the length of the call.
    public static func run(_ request: Request, gate: SendGate, folder: URL, env: HarnessEnvironment,
                           timeout: TimeInterval = 20 * 60, retries: Int = 4,
                           sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws -> Answer {
        try gate.check(request.origin)
        let scrubbed = gate.scrub(request.input)
        let records = SendLog.records(env: env)
        try SendLog.checkLimit(estimate: SendLog.estimate(characters: scrubbed.text.count, harness: request.agent.harness,
                                                          model: request.agent.model, records: records),
                               settings: gate.settings, env: env)
        var attempt = 0
        while true {
            do {
                let answer = try await once(request, input: scrubbed.text, folder: folder, env: env, timeout: timeout)
                try? SendLog.append(SendRecord(purpose: request.purpose, session: request.session, runID: request.runID,
                                               destination: gate.destination, model: request.agent.model,
                                               inputCharacters: scrubbed.text.count, usage: answer.usage,
                                               scrubbed: scrubbed.counts.isEmpty ? nil : scrubbed.counts), env: env)
                return answer
            } catch let failure as Failure where failure.rateLimited && attempt < retries {
                attempt += 1
                try await sleep(.seconds(5 * (1 << attempt)))
            }
        }
    }

    static func once(_ request: Request, input: String, folder: URL, env: HarnessEnvironment, timeout: TimeInterval) async throws -> Answer {
        let harness = request.agent.harness
        guard let command = env.findExecutable(harness.command) else {
            throw Failure(message: "\(harness.title) (\(harness.command)) is not installed.", rateLimited: false)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "call-\(UUID().uuidString.lowercased()).md")
        try Data(input.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let collector = Collector()
        let exit = await ChildProcess.run(command, arguments: arguments(request, input: file), directory: folder,
                                          environment: AgentRun.environment(env, runFolder: nil),
                                          input: harness == .claudeCode ? file : nil, timeout: timeout) { collector.add($0) }
        guard let exit else { throw Failure(message: "Couldn't start \(command.path).", rateLimited: false) }
        if exit.cancelled { throw CancellationError() }
        if exit.timedOut { throw Failure(message: "The model call timed out.", rateLimited: false) }
        return try harness == .claudeCode ? claudeAnswer(collector.lines) : piAnswer(collector.lines)
    }

    /// Claude Code: one JSON result, no session saved (the analysis's own calls never show up
    /// as sessions). Pi: JSON events, no session saved, nothing loaded but the model.
    static func arguments(_ request: Request, input: URL) -> [String] {
        switch request.agent.harness {
        case .claudeCode:
            return ["-p", "Answer for the input on stdin.", "--output-format", "json", "--no-session-persistence",
                    "--tools", "", "--safe-mode", "--strict-mcp-config", "--permission-prompts", "none",
                    "--system-prompt", request.system]
                + (request.schema.map { ["--json-schema", $0] } ?? []) + request.agent.flags
        case .pi:
            let schema = request.schema.map { "\nThe answer is one JSON object matching this JSON schema:\n\($0)" } ?? ""
            return ["-p", "Answer for the attached input.", "--mode", "json", "--no-session", "--offline",
                    "--no-tools", "--no-skills", "--no-context-files", "--no-prompt-templates",
                    "--system-prompt", request.system + schema + "\nAnswer with the JSON object only, no other text."]
                + request.agent.flags + ["@\(input.path)"]
        }
    }

    /// `{"type":"result","is_error":…,"result":…,"structured_output":…,"usage":…,"total_cost_usd":…}`.
    static func claudeAnswer(_ lines: [String]) throws -> Answer {
        let result = lines.reversed().lazy.compactMap { line -> [String: Any]? in
            guard line.hasPrefix("{") else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }.first { $0["type"] as? String == "result" }
        guard let result else {
            let text = lines.joined(separator: "\n")
            throw Failure(message: "Claude Code gave no result: \(SecretFilter.masked(String(text.suffix(300))))",
                          rateLimited: isRateLimit(text))
        }
        let sent = claudeUsage(result)
        if result["is_error"] as? Bool == true {
            let text = result["result"] as? String ?? "Claude Code stopped with an error."
            throw Failure(message: SecretFilter.masked(String(text.prefix(300))), rateLimited: isRateLimit(text))
        }
        if let structured = result["structured_output"], JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            return Answer(text: String(decoding: data, as: UTF8.self), usage: sent)
        }
        return Answer(text: result["result"] as? String ?? "", usage: sent)
    }

    /// Tokens and the recorded cost of Claude Code's result event.
    static func claudeUsage(_ result: [String: Any]) -> SendUsage {
        let usage = result["usage"] as? [String: Any] ?? [:]
        func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        return SendUsage(input: count("input_tokens") + count("cache_creation_input_tokens"), cached: count("cache_read_input_tokens"),
                         output: count("output_tokens"), cost: (result["total_cost_usd"] as? NSNumber)?.doubleValue)
    }

    /// Pi's `message_end` events: usage of every answer, the text of the last one.
    static func piAnswer(_ lines: [String]) throws -> Answer {
        var usage = SendUsage()
        var text: String?
        var error: String?
        for line in lines where line.hasPrefix("{") {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  event["type"] as? String == "message_end", let message = event["message"] as? [String: Any],
                  message["role"] as? String == "assistant" else { continue }
            if let recorded = message["usage"] as? [String: Any] {
                let tokens = PiLogFormat.tokens(fromPiUsage: recorded)
                usage = usage + SendUsage(input: tokens.input + tokens.cacheWrite, cached: tokens.cacheRead, output: tokens.output,
                                          cost: PiLogFormat.cost(fromPiUsage: recorded))
            }
            if message["stopReason"] as? String == "error" {
                error = message["errorMessage"] as? String ?? "The model call failed."
            } else {
                error = nil
                let answer = (message["content"] as? [[String: Any]] ?? [])
                    .filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !answer.isEmpty { text = answer }
            }
        }
        if let error { throw Failure(message: SecretFilter.masked(String(error.prefix(300))), rateLimited: isRateLimit(error)) }
        guard let text else {
            let output = lines.joined(separator: "\n")
            throw Failure(message: "Pi gave no answer: \(SecretFilter.masked(String(output.suffix(300))))", rateLimited: isRateLimit(output))
        }
        return Answer(text: text, usage: usage)
    }

    static func isRateLimit(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("429") || lower.contains("rate limit") || lower.contains("rate_limit") || lower.contains("too many requests")
            || lower.contains("overloaded")
    }

    /// The first `{` to the last `}` of an answer: models sometimes wrap JSON in prose or fences.
    public static func jsonObject(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return Data(text[start...end].utf8)
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.withLock { stored.append(line) } }
        var lines: [String] { lock.withLock { stored } }
    }
}
