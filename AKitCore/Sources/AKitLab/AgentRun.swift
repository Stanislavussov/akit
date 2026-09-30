import AKitFoundation
import Foundation

/// One headless Claude Code run: `claude -p` with stream-json output. The raw stream goes
/// to `agent.jsonl`, a readable version to the terminal.
enum AgentRun {
    /// Every agent run gets these: nobody can answer a permission prompt, so anything that
    /// would ask is denied (counted as rejected), and nothing is pushed.
    static func arguments(prompt: String, spec: RunSpec, extra: [String] = []) -> [String] {
        ["-p", prompt, "--verbose", "--output-format", "stream-json",
         "--session-id", spec.sessionID, "--name", "Lab: \(spec.title)",
         "--permission-mode", "auto", "--permission-prompts", "none",
         "--disallowedTools", "Bash(git push:*)"]
            + (spec.setup?.flags ?? []) + extra
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

    /// Runs the agent to the end (or the time limit). Throws when Claude Code can't start.
    /// The raw stream goes to `runFolder/agent.jsonl`; `exposeRunFolder` sets `AKIT_LAB_DIR`.
    static func run(prompt: String, spec: RunSpec, in directory: URL, runFolder: URL, exposeRunFolder: Bool, extra: [String] = [],
                    env: HarnessEnvironment, timeout: TimeInterval = 2 * 3600,
                    out: @escaping @Sendable (String) -> Void) async throws -> ChildProcess.Exit {
        guard let claude = env.findExecutable("claude") else { throw LabWorker.Failure(message: "Claude Code (claude) is not installed.") }
        let log = runFolder.appending(path: "agent.jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let writer = try FileHandle(forWritingTo: log)
        defer { try? writer.close() }
        let printer = StreamPrinter(out: out)
        let exit = await ChildProcess.run(claude, arguments: arguments(prompt: prompt, spec: spec, extra: extra),
                                          directory: directory, environment: environment(env, runFolder: exposeRunFolder ? runFolder : nil),
                                          timeout: timeout) { line in
            try? writer.write(contentsOf: Data((line + "\n").utf8))
            printer.print(line)
        }
        guard let exit else { throw LabWorker.Failure(message: "Couldn't start \(claude.path).") }
        if exit.timedOut { out("The agent was stopped after \(MetricsText.duration(Int(timeout))).") }
        return exit
    }
}

/// stream-json lines as short readable lines: the agent's text, one line per tool call,
/// failed tool results, and the end. Secrets are masked.
final class StreamPrinter: @unchecked Sendable {
    private let out: @Sendable (String) -> Void
    private let lock = NSLock()

    init(out: @escaping @Sendable (String) -> Void) { self.out = out }

    func print(_ line: String) {
        lock.withLock {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                // Not JSON: an error message of claude itself.
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { out(SecretFilter.masked(line)) }
                return
            }
            for text in Self.readable(object) { out(SecretFilter.masked(text)) }
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
