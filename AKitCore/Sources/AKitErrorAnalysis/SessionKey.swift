import AKitFoundation
import AKitSessions
import Foundation

/// The session index's key, `sessions.key` (`<harness>:<native id>`, written by
/// `ClaudeFacts` and `PiFacts` in AKitInsights): notes, checks and labels of one session
/// meet under it. Stored as that one string.
public struct SessionKey: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The index's harness name: `claude` or `pi` (not `HarnessID`'s `claude-code`).
    public let harness: String
    /// Claude Code: the session file's name without `.jsonl`. Pi: the header's `id`.
    public let nativeID: String

    public init(harness: String, nativeID: String) {
        self.harness = harness
        self.nativeID = nativeID
    }

    public var description: String { "\(harness):\(nativeID)" }

    /// `claude:<id>` or `pi:<id>`; the id may hold further `:`.
    public init?(parsing text: String) {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let harness = String(text[..<colon])
        let nativeID = String(text[text.index(after: colon)...])
        guard !harness.isEmpty, !nativeID.isEmpty else { return nil }
        self.init(harness: harness, nativeID: nativeID)
    }

    /// The key the index gives this session; nil for a harness the index doesn't read.
    /// Pi's key comes from the file's `session` header, so it reads the file's first line.
    public static func of(_ summary: SessionSummary) -> SessionKey? {
        let file = summary.file
        switch summary.harness {
        case .claudeCode:
            // A subagent run lives in `<session id>/subagents/<run>.jsonl`. The index counts it
            // with its parent; reviewed on its own it gets a key of its own, so its notes never
            // replace the parent's.
            if file.deletingLastPathComponent().lastPathComponent == "subagents" {
                let parent = file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                return SessionKey(harness: "claude", nativeID: "\(parent)/\(file.deletingPathExtension().lastPathComponent)")
            }
            return SessionKey(harness: "claude", nativeID: file.deletingPathExtension().lastPathComponent)
        case .pi:
            var id: String?
            JSONLines.scanHead(of: file) { entry in
                guard entry["type"] as? String == "session" else { return false }
                id = entry["id"] as? String
                return true
            }
            return SessionKey(harness: "pi", nativeID: id ?? file.deletingPathExtension().lastPathComponent)
        default:
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let key = SessionKey(parsing: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a session key: \(text)")
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
