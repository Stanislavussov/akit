import AKitFoundation
import AKitSessions
import Foundation

/// What `pi -p --mode json` prints, read back: the session, the last answer, an error, the
/// recorded usage and what the tools read. Shared by AKit Review's passes and Knowledge's Ask Pi
/// (moved down from `ReviewPasses` on 2026-10-31).
public enum PiJSONStream {
    public struct Output: Sendable {
        public var session: String?
        public var usage = SendUsage()
        public var answer: String?
        public var error: String?
        /// The paths the read tools read, and `mcp:<tool>` for an MCP call (never its arguments).
        public var paths: [String] = []

        public init() {}
    }

    /// Reads the events of one run.
    public static func parse(_ lines: [String]) -> Output {
        var output = Output()
        for line in lines where line.hasPrefix("{") {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "session":
                output.session = output.session ?? event["id"] as? String
            case "tool_execution_start":
                let name = event["toolName"] as? String ?? ""
                if ["read", "grep", "find", "ls"].contains(name), let args = event["args"] as? [String: Any] {
                    output.paths.append(args["path"] as? String ?? ".")
                } else if name.hasPrefix("mcp__") {
                    // What a pass read through MCP, by tool (never the arguments).
                    output.paths.append("mcp:" + name)
                }
            case "message_end":
                guard let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" else { continue }
                if let usage = message["usage"] as? [String: Any] {
                    let tokens = PiLogFormat.tokens(fromPiUsage: usage)
                    output.usage = output.usage + SendUsage(input: tokens.input + tokens.cacheWrite, cached: tokens.cacheRead,
                                                            output: tokens.output, cost: PiLogFormat.cost(fromPiUsage: usage))
                }
                if message["stopReason"] as? String == "error" {
                    output.error = SecretFilter.masked(String((message["errorMessage"] as? String ?? "The model call failed.").prefix(300)))
                } else {
                    output.error = nil
                    let text = (message["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
                        .compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !text.isEmpty { output.answer = text }
                }
            default:
                break
            }
        }
        // Read twice is read once.
        var seen = Set<String>()
        output.paths = output.paths.filter { seen.insert($0).inserted }
        return output
    }

    /// A session Pi saved in `folder`: `<time>_<id>.jsonl`.
    public static func sessionFile(id: String, in folder: URL) -> URL? {
        FileWalk.children(of: folder).first { $0.lastPathComponent.hasSuffix("_\(id).jsonl") }
    }

    /// AKit's child environment with the login shell's variables over it; the shell's PATH
    /// comes first, AKit's usual places after it. So Pi's MCP servers find the variables their
    /// `mcp.json` entries name and the programs they start, also when AKit.app was started from the Dock.
    public static func shellEnvironment(_ shell: LoginShell.Variables, env: HarnessEnvironment) -> [String: String] {
        var variables = ChildProcess.harnessEnvironment(env).merging(shell.values) { $1 }
        let paths = (shell.values["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) }
        var lookup = env
        lookup.executableSearchPaths = paths + env.executableSearchPaths
        variables["PATH"] = lookup.pathForChildProcesses
        variables["HOME"] = env.homeDirectory.path
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { variables[key] = nil }
        return variables
    }
}
