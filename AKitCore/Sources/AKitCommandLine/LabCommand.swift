import AKitFoundation
import AKitLab
import Foundation

/// `akit lab …`: measuring agent sessions (docs/design/lab.md).
extension AKitCLI {
    public static let labUsage = """
        akit lab — measure agent sessions (Claude Code); files in ~/.akit/lab

          akit lab analyze SESSION [--json]
                                          Calls, fresh tokens, context rent, tool errors, re-reads,
                                          rejected calls, interrupts, commits (and whether they reached
                                          the main branch) of one session. SESSION: a transcript path
                                          or a Claude Code session id
        """

    static func lab(_ arguments: [String], env: HarnessEnvironment, cwd: URL,
                    out: (String) -> Void, err: (String) -> Void) async throws -> Int32 {
        var args = Arguments(arguments)
        if args.flag("--help") || args.flag("-h") || args.isEmpty {
            out(labUsage)
            return 0
        }
        let json = args.flag("--json")
        let command = args.positional()
        switch command {
        case "analyze":
            guard let session = args.positional() else { throw Failure(message: "Which session? akit lab analyze SESSION.") }
            try args.finish()
            let file = try transcript(session, cwd: cwd, env: env)
            let metrics: SessionMetrics
            do {
                metrics = try await LabAnalysis.analyze(file: file, env: env)
            } catch {
                throw Failure(message: "Couldn't read \(file.path): \(error.localizedDescription)")
            }
            out(json ? try labJSON(metrics) : ([file.path] + MetricsText.lines(metrics)).joined(separator: "\n"))
            return 0
        default:
            throw Failure(message: "Unknown “akit lab \(command ?? "")”. Run akit lab --help.")
        }
    }

    /// A transcript path, or a Claude Code session id.
    private static func transcript(_ argument: String, cwd: URL, env: HarnessEnvironment) throws -> URL {
        if argument.hasSuffix(".jsonl") || argument.contains("/") {
            let file = resolve(argument, cwd: cwd, env: env)
            guard FileManager.default.fileExists(atPath: file.path) else { throw Failure(message: "No file at \(file.path).") }
            return file
        }
        guard let file = LabPaths.transcript(sessionID: argument, env: env) else {
            throw Failure(message: "No Claude Code session \(argument) in \(LabPaths.claudeRoot(env: env).path)/projects.")
        }
        return file
    }

    static func labJSON<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
