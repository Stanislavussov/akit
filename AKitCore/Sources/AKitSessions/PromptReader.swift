import AKitFoundation
import AKitModel
import Foundation

public enum SystemPromptAccess: Sendable {
    case unavailable
    /// Saved inside session files: `PromptReader.recorded(in:)`.
    case recorded
    /// Asked from the harness on demand: `PromptReader.capture(harness:in:env:)`.
    case captured
}

/// The system prompt a harness sends, from its session files or asked from the harness.
public enum PromptReader {
    /// How AKit can show this harness's system prompt.
    public static func access(for harness: HarnessID) -> SystemPromptAccess {
        switch harness {
        case .claudeCode: .recorded
        case .pi: .captured
        default: .unavailable
        }
    }

    /// The system prompt the harness saved inside this session, if it saves one.
    public static func recorded(in session: SessionSummary) throws -> PromptSnapshot? {
        switch session.harness {
        case .claudeCode: try ClaudeSessions.recordedPrompt(in: session.file)
        default: nil
        }
    }

    /// Starts the harness in `project` to read the system prompt it would send now.
    /// Doesn't contact the model or save a session. nil when the harness can't be asked
    /// or its command isn't found (Pi: see PiPromptProbe).
    public static func capture(harness: HarnessID, in project: URL, env: HarnessEnvironment) async throws -> PromptSnapshot? {
        switch harness {
        case .pi:
            guard let executable = env.findExecutable("pi") else { return nil }
            return try await PiPromptProbe.capture(executable: executable, project: project, env: env)
        default:
            return nil
        }
    }
}
