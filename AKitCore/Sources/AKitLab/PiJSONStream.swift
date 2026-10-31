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
        /// Pi's process started (`run`): the prompt went out, whatever happened after.
        public var started = false

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

    /// Runs one `pi -p --mode json`: every line goes to `onLine` and, masked (`JSONMask`), to
    /// `stream`; the events are read back with `parse`. An error says why the run ended badly:
    /// it couldn't start, was stopped (the caller's `Cancellation` scope), timed out
    /// (`timeoutMessage`), or exited with a status (with the last lines that aren't JSON).
    /// Returns every line too, unmasked, for the caller to look into (never saved).
    public static func run(_ pi: URL, arguments: [String], directory: URL, environment: [String: String], timeout: TimeInterval,
                           stream: URL, timeoutMessage: String,
                           onLine: (@Sendable (String) -> Void)? = nil) async -> (output: Output, lines: [String]) {
        try? FileManager.default.createDirectory(at: stream.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: stream.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: stream)
        let collector = Collector()
        let exit = await ChildProcess.run(pi, arguments: arguments, directory: directory, environment: environment, timeout: timeout,
                                          onStart: { collector.start() }) { line in
            collector.add(line)
            handle?.write(Data((JSONMask.jsonLine(line) + "\n").utf8))
            onLine?(line)
        }
        try? handle?.close()
        var output = parse(collector.lines)
        output.started = collector.started
        if exit == nil { output.error = "Pi couldn't start." }
        else if exit?.cancelled == true { output.error = "Stopped." }
        else if exit?.timedOut == true { output.error = timeoutMessage }
        else if exit?.succeeded != true, output.error == nil {
            let tail = collector.lines.filter { !$0.hasPrefix("{") }.suffix(5).joined(separator: " ")
            output.error = "Pi exited with status \(exit?.status ?? -1)" + (tail.isEmpty ? "." : ": \(SecretFilter.masked(String(tail.suffix(300))))")
        }
        return (output, collector.lines)
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        private var didStart = false
        func add(_ line: String) { lock.withLock { stored.append(line) } }
        func start() { lock.withLock { didStart = true } }
        var lines: [String] { lock.withLock { stored } }
        var started: Bool { lock.withLock { didStart } }
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
