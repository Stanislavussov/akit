import AKitFoundation
import AKitModel
import Foundation

/// What a session log line says, reduced to facts: counts, sizes, ids, hashes. Never message
/// text, except `manualCallExample`, which the writer drops unless the user opted in.
enum Fact {
    struct Session {
        var nativeID: String
        var cwd: String?
        var gitBranch: String?
        var harnessVersion: String?
        var started: Date?
        var lastActivity: Date?
    }

    /// One model response. `key`: Claude `message.id`, Pi `<entry id>@<timestamp>`.
    struct Request {
        let key: String
        let ts: Date?
        let model: String
        let tokens: TokenCounts
        let cost: Double?
        let isSubagent: Bool
    }

    struct ToolCall {
        let key: String
        /// The harness's own call id, which its result refers to.
        let callID: String
        let ts: Date?
        let name: String
        let inputBytes: Int
        let isSubagent: Bool
        /// SHA-256 of the path a read tool opened (for re-read lessons later).
        let pathHash: String?
    }

    struct ListedSkill: Equatable {
        let name: String
        /// SHA-256 of the description; nil for a name-only line.
        let descHash: String?
        let descChars: Int
    }

    /// One skill listing the harness put into the context. `key`: the attachment entry's uuid.
    struct Listing {
        let key: String
        let ts: Date?
        let isInitial: Bool
        let isSubagent: Bool
        let skills: [ListedSkill]
    }

    enum By: String { case model, user }

    struct SkillCall {
        let key: String
        let ts: Date?
        let skill: String
        let by: By
        let isSubagent: Bool
        let hasArgs: Bool
    }

    /// What the user wrote around a `/name` skill call: the call's arguments and the prompt
    /// before it (a positive example for the skill's description). Kept, masked, only when
    /// `~/.akit/insights.json` asks for it on a personal Mac (see `SessionImporter`).
    struct ManualCallExample {
        /// The key of the user's skill call.
        let key: String
        let ts: Date?
        let skill: String
        let args: String
        let request: String?
    }

    case session(Session)
    case request(Request)
    case toolCall(ToolCall)
    case toolResult(callID: String, bytes: Int, isError: Bool)
    case skillListing(Listing)
    case skillCall(SkillCall)
    /// A built-in slash command the user typed (`/model`, `/clear`); stored as a user call of
    /// kind `command`. A `/name` skill the user called is a `skillCall` by the user.
    case command(SkillCall)
    case manualCallExample(ManualCallExample)
}

/// Where facts come from: which harness, session, source row and parser.
struct FactContext {
    let harness: String
    var sessionKey: String
    let sourceID: Int64
    let isSubagent: Bool
    let parserVersion: Int
}

extension Fact {
    /// Byte size of a tool input as JSON.
    static func jsonBytes(_ value: Any?) -> Int {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return 0 }
        return data.count
    }

    static func sha256(_ text: String) -> String { Checksum.sha256(Data(text.utf8)) }
}
