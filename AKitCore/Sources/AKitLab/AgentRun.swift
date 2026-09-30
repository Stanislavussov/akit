import AKitFoundation
import Foundation

/// One headless agent run: `claude -p` with stream-json output, or `pi -p --mode json` for a
/// review in Pi. The raw stream goes to `agent.jsonl`, a readable version to the terminal.
enum AgentRun {
    /// The harness of a run: a review's chosen agent, else Claude Code.
    static func harness(of spec: RunSpec) -> LabHarness { spec.agent?.harness ?? .claudeCode }

    /// Every Claude Code run gets these: nobody can answer a permission prompt, so anything
    /// that would ask is denied (counted as rejected), and nothing is pushed. Pi never asks.
    static func arguments(prompt: String, spec: RunSpec, extra: [String] = []) -> [String] {
        switch harness(of: spec) {
        case .claudeCode:
            ["-p", prompt, "--verbose", "--output-format", "stream-json",
             "--session-id", spec.sessionID, "--name", "Lab: \(spec.title)",
             "--permission-mode", "auto", "--permission-prompts", "none",
             "--disallowedTools", "Bash(git push:*)"]
                + (spec.setup?.flags ?? spec.agent?.flags ?? []) + extra
        case .pi:
            ["-p", prompt, "--mode", "json", "--session-id", spec.sessionID, "--name", "Lab: \(spec.title)", "--offline"]
                + (spec.agent?.flags ?? []) + extra
        }
    }

    /// The environment of the agent: AKit's, with `AKIT_LAB_DIR` set and the markers of an
    /// outer Claude Code session removed (akit lab run may be started from inside one).
    /// `runFolder` nil (replays): the agent gets no pointer to the run folder, whose run.json
    /// names the commit being replayed.
    static func environment(_ env: HarnessEnvironment, runFolder: URL?) -> [String: String] {
        var variables = env.variables.merging(["PATH": env.pathForChildProcesses]) { $1 }
        variables["AKIT_LAB_DIR"] = runFolder?.path
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { variables[key] = nil }
        return variables
    }

    struct Outcome {
        let exit: ChildProcess.Exit
        /// The harness's last error, when the agent ended with one (a refused model call).
        let error: String?
    }

    /// Runs the agent to the end (or the time limit). Throws when the harness can't start.
    /// The raw stream goes to `runFolder/agent.jsonl`; `exposeRunFolder` sets `AKIT_LAB_DIR`.
    static func run(prompt: String, spec: RunSpec, in directory: URL, runFolder: URL, exposeRunFolder: Bool, extra: [String] = [],
                    env: HarnessEnvironment, timeout: TimeInterval = 2 * 3600,
                    out: @escaping @Sendable (String) -> Void) async throws -> Outcome {
        let harness = harness(of: spec)
        guard let command = env.findExecutable(harness.command) else {
            throw LabWorker.Failure(message: "\(harness.title) (\(harness.command)) is not installed.")
        }
        let log = runFolder.appending(path: "agent.jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let writer = try FileHandle(forWritingTo: log)
        defer { try? writer.close() }
        let printer = StreamPrinter(harness: harness, out: out)
        let exit = await ChildProcess.run(command, arguments: arguments(prompt: prompt, spec: spec, extra: extra),
                                          directory: directory, environment: environment(env, runFolder: exposeRunFolder ? runFolder : nil),
                                          timeout: timeout) { line in
            try? writer.write(contentsOf: Data((line + "\n").utf8))
            printer.print(line)
        }
        guard let exit else { throw LabWorker.Failure(message: "Couldn't start \(command.path).") }
        if exit.timedOut { out("The agent was stopped after \(MetricsText.duration(Int(timeout))).") }
        return Outcome(exit: exit, error: printer.error)
    }
}

/// Stream lines as short readable lines: the agent's text, one line per tool call, failed
/// tool results, and the end. Secrets are masked.
final class StreamPrinter: @unchecked Sendable {
    private let harness: LabHarness
    private let out: @Sendable (String) -> Void
    private let lock = NSLock()
    /// Pi: whether the last model call failed, for the end line.
    private var failed = false
    private var lastError: String?

    /// The agent's error when it ended with one: Claude Code's failed result, or Pi's last
    /// model call when it failed. Masked.
    var error: String? { lock.withLock { lastError } }

    init(harness: LabHarness = .claudeCode, out: @escaping @Sendable (String) -> Void) {
        self.harness = harness
        self.out = out
    }

    func print(_ line: String) {
        lock.withLock {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                // Not JSON: an error message of the harness itself. Pi says it creates the
                // session named by --session-id; that is expected.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, !trimmed.hasPrefix("Warning: No project session found with id") { out(SecretFilter.masked(line)) }
                return
            }
            let lines = harness == .pi ? Self.readablePi(object, failed: &failed) : Self.readable(object)
            switch harness {
            case .pi where object["type"] as? String == "message_end":
                let message = object["message"] as? [String: Any] ?? [:]
                if message["role"] as? String == "assistant" {
                    lastError = failed ? (message["errorMessage"] as? String).map { SecretFilter.masked(String($0.prefix(300))) } : nil
                }
            case .claudeCode where object["type"] as? String == "result":
                lastError = object["is_error"] as? Bool == true
                    ? SecretFilter.masked(String((object["result"] as? String ?? "Claude Code stopped with an error.").prefix(300))) : nil
            default:
                break
            }
            for text in lines { out(SecretFilter.masked(text)) }
        }
    }

    static func readable(_ object: [String: Any]) -> [String] {
        let message = object["message"] as? [String: Any]
        let blocks = message?["content"] as? [[String: Any]] ?? []
        switch object["type"] as? String {
        case "system" where object["subtype"] as? String == "init":
            let model = object["model"] as? String ?? "?"
            let version = object["claude_code_version"] as? String
            return ["Claude Code\(version.map { " \($0)" } ?? "") · \(model) · session \(object["session_id"] as? String ?? "?")"]
        case "assistant":
            return blocks.compactMap { block in
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : text
                case "tool_use":
                    return "▸ \(block["name"] as? String ?? "tool") \(toolSummary(block["input"] as? [String: Any] ?? [:]))"
                default: return nil
                }
            }
        case "user":
            return blocks.compactMap { block in
                guard block["type"] as? String == "tool_result", block["is_error"] as? Bool == true else { return nil }
                let text = JSONLines.text(of: block["content"])
                return "  ✗ " + (text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "failed").prefix(160)
            }
        case "result":
            let turns = (object["num_turns"] as? NSNumber)?.intValue
            let seconds = (object["duration_ms"] as? NSNumber).map { $0.intValue / 1000 }
            var parts = [(object["is_error"] as? Bool == true) ? "Agent stopped with an error" : "Agent finished"]
            if let turns { parts.append("\(turns) turns") }
            if let seconds { parts.append(MetricsText.duration(seconds)) }
            return [parts.joined(separator: " · ")]
        default:
            return []
        }
    }

    /// Pi's `--mode json` events: finished messages (`message_end`), retries and the end.
    /// `failed` carries whether the last model call failed from one event to the next.
    static func readablePi(_ object: [String: Any], failed: inout Bool) -> [String] {
        switch object["type"] as? String {
        case "message_end":
            let message = object["message"] as? [String: Any] ?? [:]
            let blocks = message["content"] as? [[String: Any]] ?? []
            switch message["role"] as? String {
            case "assistant":
                var lines: [String] = blocks.compactMap { block in
                    switch block["type"] as? String {
                    case "text":
                        let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        return text.isEmpty ? nil : text
                    case "toolCall":
                        return "▸ \(block["name"] as? String ?? "tool") \(toolSummary(block["arguments"] as? [String: Any] ?? [:]))"
                    default: return nil
                    }
                }
                failed = message["stopReason"] as? String == "error"
                if failed {
                    lines.append("  ✗ " + String((message["errorMessage"] as? String ?? "The model call failed").prefix(300)))
                }
                return lines
            case "toolResult":
                guard message["isError"] as? Bool == true else { return [] }
                let text = JSONLines.text(of: message["content"])
                return ["  ✗ " + (text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "failed").prefix(160)]
            default:
                return []
            }
        case "auto_retry_start":
            let attempt = (object["attempt"] as? NSNumber)?.intValue ?? 0
            let most = (object["maxAttempts"] as? NSNumber)?.intValue ?? 0
            return ["Retrying (\(attempt) of \(most))"]
        case "agent_settled":
            return [failed ? "Agent stopped with an error" : "Agent finished"]
        default:
            return []
        }
    }

    /// The part of a tool input worth one line: a command, a path, a pattern.
    static func toolSummary(_ input: [String: Any]) -> String {
        for key in ["command", "file_path", "pattern", "path", "url", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty {
                let first = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
                return String(first.prefix(140))
            }
        }
        return ""
    }
}
