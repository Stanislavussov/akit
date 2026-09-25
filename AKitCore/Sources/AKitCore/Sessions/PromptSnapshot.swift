import Foundation

/// What a harness sends to the model before the first message: the system prompt,
/// the tool definitions and the context it loads on its own (instructions files,
/// skill list, environment…).
public struct PromptSnapshot: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// Written into a session file by the harness itself (Claude Code).
        case recorded(session: URL)
        /// AKit started the harness and caught the prompt before any model request (Pi).
        case captured(project: URL, at: Date)
    }

    public let harness: HarnessID
    public let source: Source
    /// System prompt blocks as sent (Claude sends several, Pi one).
    public let sections: [String]
    public let tools: [PromptTool]
    public let context: [PromptContextPart]

    public init(harness: HarnessID, source: Source, sections: [String], tools: [PromptTool], context: [PromptContextPart]) {
        self.harness = harness
        self.source = source
        self.sections = sections
        self.tools = tools
        self.context = context
    }

    public var systemPrompt: String { sections.joined(separator: "\n\n") }

    /// Rough size in tokens (about 4 characters per token), for orientation only.
    public var estimatedTokens: Int {
        let characters = systemPrompt.count
            + tools.reduce(0) { $0 + $1.name.count + $1.description.count + $1.schema.count }
            + context.reduce(0) { $0 + $1.text.count }
        return characters / 4
    }
}

public struct PromptTool: Identifiable, Sendable, Hashable {
    /// Position in the list; names can repeat when an extension overrides a built-in tool.
    public let id: Int
    public let name: String
    public let description: String
    /// Input JSON schema, pretty-printed.
    public let schema: String

    public init(id: Int, name: String, description: String, schema: String) {
        self.id = id
        self.name = name
        self.description = description
        self.schema = schema
    }

    /// `[{name, description, schema | input_schema | parameters}]`.
    static func list(_ value: Any?) -> [PromptTool] {
        (value as? [JSONLines.Object] ?? []).enumerated().compactMap { index, tool in
            guard let name = tool["name"] as? String else { return nil }
            let schema = tool["schema"] ?? tool["input_schema"] ?? tool["parameters"]
            return PromptTool(id: index, name: name, description: tool["description"] as? String ?? "",
                              schema: schema is NSNull ? "" : JSONLines.pretty(schema))
        }
    }
}

/// One piece of context the harness loaded on its own.
public struct PromptContextPart: Identifiable, Sendable, Hashable {
    public let id: Int
    public let title: String
    /// Where it came from, e.g. the path of CLAUDE.md.
    public let source: String?
    public let text: String

    public init(id: Int, title: String, source: String? = nil, text: String) {
        self.id = id
        self.title = title
        self.source = source
        self.text = text
    }
}
