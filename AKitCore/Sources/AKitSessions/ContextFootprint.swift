import AKitFoundation
import AKitModel
import Foundation

/// Where the context of a session's calls came from: each part the harness loaded on its own
/// (system prompt, tools, MCP servers, skills, subagents, rules files, hooks), its size and
/// whether the session used it. A part loaded at the start is sent again with every call, so
/// one that is never used costs its size once per call.
///
/// Call contexts are recorded. Part sizes are estimates from characters (see `TokenEstimate`),
/// fitted to the first call's recorded context: when they add up to more, they are scaled down;
/// what they leave over is the `conversation` part (the first prompt and what the characters
/// don't explain).
public struct ContextFootprint: Codable, Sendable, Hashable {
    public enum Group: String, Codable, CaseIterable, Sendable {
        case systemPrompt, tools, mcp, skills, subagents, rules, hooks, other, conversation

        public var title: String {
            switch self {
            case .systemPrompt: "System prompt"
            case .tools: "Tools"
            case .mcp: "MCP servers"
            case .skills: "Skills"
            case .subagents: "Subagents"
            case .rules: "Rules files"
            case .hooks: "Hooks"
            case .other: "Other"
            case .conversation: "Conversation"
            }
        }
    }

    public enum Use: String, Codable, Sendable {
        /// The session called it (a tool, a server's tool, a skill, a subagent type).
        case used
        /// Something the session could call and never did.
        case unused
        /// Sent with every call and never called: the system prompt, rules files, hook context.
        /// Whether the model followed it isn't in the transcript.
        case always
        /// Not setup: the first prompt and the rest of the first call.
        case conversation
    }

    public struct Part: Codable, Sendable, Hashable, Identifiable {
        public var group: Group
        public var name: String
        /// Where it comes from: a file path, an MCP server or a plugin.
        public var source: String?
        /// ≈ tokens in one call.
        public var tokens: Int
        public var use: Use
        /// Times the session called it.
        public var calls: Int
        /// What it holds, e.g. the tools of an MCP server and which of them were called.
        public var detail: String?
        /// The text the model gets, secrets masked. Shown on screen, never written to a file.
        public var text: String?

        public var id: String { "\(group.rawValue)|\(name)" }

        enum CodingKeys: String, CodingKey {
            case group, name, source, tokens, use, calls, detail
        }

        public init(group: Group, name: String, source: String? = nil, tokens: Int, use: Use, calls: Int = 0, detail: String? = nil,
                    text: String? = nil) {
            self.group = group
            self.name = name
            self.source = source
            self.tokens = tokens
            self.use = use
            self.calls = calls
            self.detail = detail
            self.text = text.map(SecretFilter.masked)
        }
    }

    public var harness: HarnessID
    /// Biggest first.
    public var parts: [Part]
    /// Recorded context of every call of the main conversation, in order.
    public var callContexts: [Int]
    /// The setup was read now, not from the session (Pi keeps no copy): it may differ from
    /// what the session had.
    public var capturedNow: Bool

    /// `restNote`: what else the rest of the first call holds for this harness.
    public init(harness: HarnessID, parts: [Part], callContexts: [Int], capturedNow: Bool = false, restNote: String? = nil) {
        self.harness = harness
        self.callContexts = callContexts
        self.capturedNow = capturedNow
        self.parts = Self.fitted(parts, firstCall: callContexts.first, restNote: restNote)
    }

    /// The first call's context: recorded, or the parts' sum when there is no call.
    public var firstCall: Int { callContexts.first ?? parts.reduce(0) { $0 + $1.tokens } }
    /// Context sent over the whole session: every call's context added up.
    public var sent: Int { callContexts.reduce(0, +) }

    public func tokens(_ use: Use) -> Int { parts.filter { $0.use == use }.reduce(0) { $0 + $1.tokens } }
    public var setupTokens: Int { parts.filter { $0.use != .conversation }.reduce(0) { $0 + $1.tokens } }

    /// A key that matches an MCP server's display name (`claude.ai Claude Docs`), its tool
    /// prefix (`claude_ai_Claude_Docs`) and its name in a config file.
    public static func serverKey(_ name: String) -> String { MCPServers.key(name) }

    /// Part of the first call, 0…1.
    public func shareOfFirstCall(_ tokens: Int) -> Double {
        firstCall > 0 ? min(1, Double(tokens) / Double(firstCall)) : 0
    }

    /// Part of all context sent in the session, 0…1: the tokens went with every call.
    public func shareOfSession(_ tokens: Int) -> Double {
        sent > 0 ? min(1, Double(tokens * callContexts.count) / Double(sent)) : 0
    }

    /// One call: its recorded context split into setup by use and the rest.
    public struct Call: Sendable, Hashable, Identifiable {
        public let id: Int
        public let context: Int
        public let unused: Int
        public let used: Int
        public let always: Int
        public var conversation: Int { max(0, context - unused - used - always) }
        public var unusedShare: Double { context > 0 ? Double(unused) / Double(context) : 0 }
    }

    /// Every call, with the setup in it. The setup is the same in every call; a call smaller
    /// than the setup (after a compaction, cleared results) shows it scaled to fit.
    public var calls: [Call] {
        let unused = tokens(.unused), used = tokens(.used), always = tokens(.always)
        let setup = unused + used + always
        return callContexts.enumerated().map { index, context in
            let scale = setup > context && setup > 0 ? Double(context) / Double(setup) : 1
            func part(_ value: Int) -> Int { Int(Double(value) * scale) }
            return Call(id: index + 1, context: context, unused: part(unused), used: part(used), always: part(always))
        }
    }

    /// Parts biggest first; their sum is the first call's context when it is known.
    /// Merged parts keep their texts one after another.
    static func fitted(_ parts: [Part], firstCall: Int?, restNote: String? = nil) -> [Part] {
        var parts = parts.filter { $0.tokens > 0 && $0.use != .conversation }
        let estimated = parts.reduce(0) { $0 + $1.tokens }
        if let firstCall, firstCall > 0 {
            if estimated > firstCall {
                let scale = Double(firstCall) / Double(estimated)
                parts = parts.map { var part = $0; part.tokens = Int(Double(part.tokens) * scale); return part }
                    .filter { $0.tokens > 0 }
                // Rounding down leaves a few tokens over: they go to the biggest part.
                if let biggest = parts.indices.max(by: { parts[$0].tokens < parts[$1].tokens }) {
                    parts[biggest].tokens += firstCall - parts.reduce(0) { $0 + $1.tokens }
                }
            }
            // After scaling down, the rest is only rounding.
            let rest = estimated > firstCall ? 0 : firstCall - estimated
            if rest > 0 {
                parts.append(Part(group: .conversation, name: "First prompt and the rest", tokens: rest, use: .conversation,
                                  detail: "The first call's recorded context that the setup parts don't explain: "
                                      + "your first prompt, attachments and the harness's own wrapping."
                                      + (restNote.map { " " + $0 } ?? "")))
            }
        }
        return parts.sorted { ($0.tokens, $1.name) > ($1.tokens, $0.name) }
    }
}

/// ≈ tokens of a text from its length: characters / k, k by script (Latin 4, Cyrillic 2.5,
/// the defaults of Insights' `ContextSize`). Only for splitting a recorded total into parts.
public enum TokenEstimate {
    public static func tokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var letters = 0, cyrillic = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if (0x0400...0x052F).contains(scalar.value) { cyrillic += 1 }
        }
        let k = letters > 0 && cyrillic * 2 >= letters ? 2.5 : 4.0
        return max(1, Int((Double(text.count) / k).rounded()))
    }
}
