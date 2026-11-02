import AKitFoundation
import AKitModel
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
    /// System prompt blocks as sent (Claude sends several, Pi one), with token-like
    /// values masked: the text includes CLAUDE.md / AGENTS.md, which may hold one.
    public let sections: [String]
    public let tools: [PromptTool]
    /// The instruction files joined into the prompt, in the order the model gets them.
    public let instructionFiles: [PromptInstructionFile]
    /// Other context the harness loaded on its own (skills list, environment…).
    public let context: [PromptContextPart]

    public init(harness: HarnessID, source: Source, sections: [String], tools: [PromptTool],
                instructionFiles: [PromptInstructionFile] = [], context: [PromptContextPart]) {
        self.harness = harness
        self.source = source
        self.sections = sections
        self.tools = tools
        self.instructionFiles = instructionFiles
        self.context = context
    }

    public var systemPrompt: String { sections.joined(separator: "\n\n") }

    /// Rough size in tokens (about 4 characters per token), for orientation only.
    public var estimatedTokens: Int {
        let characters = systemPrompt.count
            + tools.reduce(0) { $0 + $1.name.count + $1.description.count + $1.schema.count }
            + context.reduce(0) { $0 + $1.text.count }
            + (harness == .pi ? 0 : instructionFiles.reduce(0) { $0 + $1.text.count })
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

/// One instruction file (CLAUDE.md, AGENTS.md…) the harness joined into the prompt.
public struct PromptInstructionFile: Identifiable, Sendable, Hashable {
    public enum Scope: Sendable, Hashable {
        /// The harness's own global file: ~/.claude/CLAUDE.md, Pi's agent folder.
        case global
        /// Claude Code's managed file, set by the organization.
        case managed
        /// A folder above the project: every session below it gets the file.
        case above
        /// The project folder (or a rule file inside it).
        case project
        /// CLAUDE.local.md: the project's own file, kept out of git.
        case local
        /// Claude Code's auto memory (MEMORY.md).
        case memory
        /// A kind this version of AKit doesn't know, as the harness names it.
        case other(String)

        public var title: String {
            switch self {
            case .global: "Global"
            case .managed: "Managed"
            case .above: "Folder above"
            case .project: "Project"
            case .local: "Local"
            case .memory: "Auto memory"
            case .other(let name): name
            }
        }
    }

    /// Position in the order the model gets the files.
    public let id: Int
    public let path: String
    public let scope: Scope
    /// The text as sent, with token-like values masked.
    public let text: String

    public init(id: Int, path: String, scope: Scope, text: String) {
        self.id = id
        self.path = path
        self.scope = scope
        self.text = text
    }

    /// `.project` for a file inside `cwd`, `.above` for one in a folder above it, nil otherwise
    /// or without `cwd`. A file under `.claude/` (Claude Code's `.claude/CLAUDE.md`, rules)
    /// belongs to the folder that holds `.claude`. Links are resolved (`/tmp` is `/private/tmp`).
    static func folderScope(of path: String, cwd: URL?) -> Scope? {
        guard let cwd else { return nil }
        let here = cwd.resolvingSymlinksInPath().path
        var components = URL(filePath: path).deletingLastPathComponent().pathComponents
        if let dotClaude = components.firstIndex(of: ".claude") { components = Array(components[..<dotClaude]) }
        let folder = URL(filePath: NSString.path(withComponents: components)).resolvingSymlinksInPath().path
        if folder == here || folder.hasPrefix(here == "/" ? "/" : here + "/") { return .project }
        return here.hasPrefix(folder == "/" ? "/" : folder + "/") ? .above : nil
    }
}
