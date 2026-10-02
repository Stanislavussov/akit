import AKitFoundation
import AKitModel
import Foundation

/// Where Lab keeps its files on this Mac. Nothing here is ever part of the brain.
public struct LabPaths: Sendable {
    public let home: URL

    public init(env: HarnessEnvironment) { home = env.homeDirectory }

    public var folder: URL { home.appending(path: ".akit/lab", directoryHint: .isDirectory) }
    public func run(_ id: String) -> URL { folder.appending(path: id, directoryHint: .isDirectory) }
    /// Validated replay tasks, one file per commit.
    public var tasks: URL { folder.appending(path: "tasks", directoryHint: .isDirectory) }

    /// Claude Code's folder: `$CLAUDE_CONFIG_DIR`, else `~/.claude`.
    public static func claudeRoot(env: HarnessEnvironment) -> URL {
        env.variables["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : env.expand($0) }
            ?? env.homeDirectory.appending(path: ".claude", directoryHint: .isDirectory)
    }

    /// `<claude>/projects/*/<id>.jsonl`; nil until Claude Code has written it.
    public static func transcript(sessionID: String, env: HarnessEnvironment) -> URL? {
        let projects = claudeRoot(env: env).appending(path: "projects")
        return FileWalk.children(of: projects)
            .map { $0.appending(path: "\(sessionID).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The session's name: set by the user, else Claude Code's title (the last one written).
    public static func title(ofTranscript file: URL) -> String? {
        var custom: String?
        var ai: String?
        for entry in JSONLines.tail(of: file) {
            switch entry["type"] as? String {
            case "custom-title": custom = entry["customTitle"] as? String ?? custom
            case "ai-title": ai = entry["aiTitle"] as? String ?? ai
            default: break
            }
        }
        return [custom, ai].compactMap { $0 }.first { !$0.isEmpty }.map(SecretFilter.masked)
    }

    /// The harness that wrote a transcript: Pi for a file under `.pi/agent/sessions`, else Claude Code.
    public static func harness(ofTranscript file: URL) -> HarnessID {
        file.path.contains("/.pi/agent/sessions/") ? .pi : .claudeCode
    }

    /// The folder a Claude Code session ran in (`cwd` of its first lines).
    public static func folder(ofTranscript file: URL) -> URL? {
        var cwd: String?
        JSONLines.scanHead(of: file) { entry in
            cwd = cwd ?? entry["cwd"] as? String
            return cwd != nil
        }
        return cwd.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }
}
