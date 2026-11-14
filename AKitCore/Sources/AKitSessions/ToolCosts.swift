import AKitFoundation
import AKitModel
import Foundation

/// What each tool of a session cost in context, tokens and money. Only recorded numbers:
/// a call's result enters the context of the next request, so the growth of the recorded
/// context from the request that made the call to the next one (less that request's own
/// output) is what the results added. Calls made in one response share that growth by the
/// length of their results. The result then stays in the context and is read again by every
/// later request until a compaction or the end. Cost is the share of each later request's
/// recorded cost (Pi records it; Claude Code doesn't, so it stays nil there).
public struct ToolCosts: Sendable, Hashable, Codable {
    public struct Tool: Sendable, Hashable, Codable, Identifiable {
        /// The tool name; a shell call adds its program: `Bash: agent-browser`.
        public let name: String
        public var id: String { name }
        public var calls = 0
        /// Tokens its results added to the context.
        public var added = 0
        /// The largest addition of one call.
        public var largest = 0
        /// Its results read again by later requests (before a compaction), in tokens.
        public var reread = 0
        /// Share of recorded cost; nil when no request had a cost.
        public var cost: Double?

        public init(name: String) { self.name = name }

        /// The MCP server of an MCP tool.
        public var server: String? { MCPServers.server(ofTool: name) }
        /// `mcp__claude-in-chrome__navigate` → `claude-in-chrome: navigate`.
        public var displayName: String {
            guard let server else { return name }
            return "\(server): \(name.dropFirst(5 + server.count + 2))"
        }
        /// Added plus re-read: all input tokens its results caused.
        public var tokens: Int { added + reread }
    }

    /// Most tokens first.
    public var tools: [Tool] = []
    /// Context of the last request, to show a tool's share of it.
    public var lastContext = 0

    public init(tools: [Tool] = [], lastContext: Int = 0) {
        self.tools = tools
        self.lastContext = lastContext
    }

    /// Per MCP server: its tools added up, most tokens first.
    public var servers: [Tool] {
        var byServer: [String: Tool] = [:]
        for tool in tools {
            guard let server = tool.server else { continue }
            var sum = byServer[server] ?? Tool(name: server)
            sum.calls += tool.calls
            sum.added += tool.added
            sum.largest = max(sum.largest, tool.largest)
            sum.reread += tool.reread
            if let cost = tool.cost { sum.cost = (sum.cost ?? 0) + cost }
            byServer[server] = sum
        }
        return byServer.values.sorted(by: Self.order)
    }

    static func order(_ a: Tool, _ b: Tool) -> Bool { (a.tokens, a.calls, b.name) > (b.tokens, b.calls, a.name) }

    /// `Bash` with `{"command": "agent-browser open …"}` → `Bash: agent-browser`; other tools keep their name.
    public static func key(tool: String, input: Any?) -> String {
        guard ["bash", "Bash"].contains(tool), let command = (input as? [String: Any])?["command"] as? String,
              let program = program(of: command) else { return tool }
        return "\(tool): \(program)"
    }

    /// The program a shell command runs: past `cd …&&`, env assignments and `sudo`/`npx`-like launchers.
    static func program(of command: String) -> String? {
        let segments = command.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let segment = segments.first { !$0.hasPrefix("cd ") && $0 != "cd" } ?? segments.first ?? ""
        let launchers: Set = ["sudo", "npx", "bunx", "pnpx", "env", "time", "exec", "uvx"]
        for word in segment.split(whereSeparator: \.isWhitespace).map(String.init) {
            if word.contains("=") && !word.hasPrefix("-") && word.first != "=" { continue }
            if launchers.contains(word) || word.hasPrefix("-") { continue }
            let name = (word as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()"))
            return name.isEmpty ? nil : String(name.prefix(40))
        }
        return nil
    }
}

/// The order of responses, tool calls, results and compactions on the active branch, for `ToolCosts`.
struct ToolTrace {
    private enum Event {
        case response(key: String, tokens: TokenCounts, cost: Double?)
        case call(id: String, tool: String)
        case result(id: String, length: Int)
        case compaction
    }

    private var events: [Event] = []

    /// A model response; lines of one response (same key) keep the last numbers.
    mutating func response(key: String?, tokens: TokenCounts, cost: Double?) {
        if let key, case .response(let last, _, _)? = events.last(where: { if case .response = $0 { true } else { false } }),
           last == key, let index = events.lastIndex(where: { if case .response = $0 { true } else { false } }) {
            events[index] = .response(key: key, tokens: tokens, cost: cost)
            return
        }
        events.append(.response(key: key ?? "#\(events.count)", tokens: tokens, cost: cost))
    }

    mutating func call(id: String, tool: String) { events.append(.call(id: id, tool: tool)) }
    mutating func result(id: String, length: Int) { events.append(.result(id: id, length: length)) }
    mutating func compaction() { events.append(.compaction) }

    var costs: ToolCosts {
        struct Response { var tokens: TokenCounts; var cost: Double?; var calls: [String] = []; var compactedBefore = false }
        var responses: [Response] = []
        var toolOf: [String: String] = [:]
        var length: [String: Int] = [:]
        var compacted = false
        for event in events {
            switch event {
            case .response(_, let tokens, let cost):
                responses.append(Response(tokens: tokens, cost: cost, compactedBefore: compacted))
                compacted = false
            case .call(let id, let tool):
                toolOf[id] = tool
                if !responses.isEmpty { responses[responses.count - 1].calls.append(id) }
            case .result(let id, let count): length[id, default: 0] += count
            case .compaction: compacted = true
            }
        }
        var tools: [String: ToolCosts.Tool] = [:]
        for (index, response) in responses.enumerated() {
            for id in response.calls { tools[toolOf[id] ?? "tool", default: ToolCosts.Tool(name: toolOf[id] ?? "tool")].calls += 1 }
            let next = index + 1
            guard !response.calls.isEmpty, next < responses.count, !responses[next].compactedBefore else { continue }
            let growth = responses[next].tokens.context - response.tokens.context - response.tokens.output
            guard growth > 0 else { continue }
            let total = response.calls.reduce(0) { $0 + (length[$1] ?? 0) }
            for id in response.calls {
                let name = toolOf[id] ?? "tool"
                let share = total > 0 ? Double(length[id] ?? 0) / Double(total) : 1 / Double(response.calls.count)
                let added = Int((Double(growth) * share).rounded())
                guard added > 0 else { continue }
                var tool = tools[name]!
                tool.added += added
                tool.largest = max(tool.largest, added)
                // The next request reads it as new input; it and every later one until a compaction pay for it.
                var later = next
                while later < responses.count, later == next || !responses[later].compactedBefore {
                    let request = responses[later]
                    if later > next { tool.reread += added }
                    if let cost = request.cost, request.tokens.context > 0 {
                        tool.cost = (tool.cost ?? 0) + cost * Double(added) / Double(request.tokens.context)
                    }
                    later += 1
                }
                tools[name] = tool
            }
        }
        return ToolCosts(tools: tools.values.sorted(by: ToolCosts.order), lastContext: responses.last?.tokens.context ?? 0)
    }
}
