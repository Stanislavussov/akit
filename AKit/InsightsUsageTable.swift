import AKitInsights
import SwiftUI

/// The Insights screen's table over the window: skills, MCP servers or tools, with Unused Only and a
/// sort. The same numbers as `akit stats --details` and `akit stats tools --details`.
struct InsightsUsageTable: View {
    let stats: StatsReport
    let tools: ToolsReport

    enum Kind: String, CaseIterable, Identifiable {
        case skills, servers, tools
        var id: Self { self }
        var title: String {
            switch self {
            case .skills: "Skills"
            case .servers: "MCP Servers"
            case .tools: "Tools"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case contextSpace, fewestCalls, mostCalls, leastRecent, name
        var id: Self { self }
        var title: String {
            switch self {
            case .contextSpace: "Context Space"
            case .fewestCalls: "Fewest Calls"
            case .mostCalls: "Most Calls"
            case .leastRecent: "Least Recently Used"
            case .name: "Name"
            }
        }
    }

    /// Snapshots: `--section insights --tab skills|servers|tools` picks the table, `--query unused` turns on Unused Only,
    /// `--query open` opens every MCP server's tool list.
    @State private var kind = DebugSnapshot.options?.section == .insights
        ? DebugSnapshot.options?.tab.flatMap(Kind.init(rawValue:)) ?? .skills : .skills
    @State private var unusedOnly = DebugSnapshot.options?.section == .insights && DebugSnapshot.options?.query == "unused"
    @State private var sort = Sort.contextSpace
    /// The table shows the first `InsightsView.shortTable` rows until Show All.
    @State private var showAll = false
    /// MCP servers whose tool list is open.
    @State private var expanded: Set<String> = []

    /// Context space exists only for skills; the other tables fall back to Fewest Calls.
    private var effectiveSort: Sort { kind != .skills && sort == .contextSpace ? .fewestCalls : sort }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                controls
                switch kind {
                case .skills: skillsTable
                case .servers: serversTable
                case .tools: toolsTable
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text("\(kind.title), Last \(stats.window.days) Days").font(.headline)
        }
        .help(kind == .skills ? "The same numbers as akit stats --details" : "The same numbers as akit stats tools --details")
    }

    private var controls: some View {
        HStack {
            Picker("Table", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Skills, MCP servers or tools of the sessions in the window")
            Spacer()
            Toggle("Unused Only", isOn: $unusedOnly)
                .toggleStyle(.checkbox)
                .help("Only rows with no call made in the window, in any session of the scope: their last call is before the window, or there is none")
            Picker("Sort", selection: Binding(get: { effectiveSort }, set: { sort = $0 })) {
                ForEach(Sort.allCases.filter { kind == .skills || $0 != .contextSpace }) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .help("Least Recently Used puts never-called rows first, then the oldest last call")
        }
        .onChange(of: kind) { showAll = false }
    }

    // MARK: Skills

    private var skillsTable: some View {
        let all = sorted(stats.skills.filter { !unusedOnly || $0.unused }, calls: { $0.modelCalls + $0.userCalls + $0.piModelCalls },
                         weight: \.approxContextSpace, last: \.lastCall, name: \.name)
        return VStack(alignment: .leading, spacing: 10) {
            Text(InsightsView.statsLine(stats)).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let dropped = stats.droppedDescriptions.text {
                Label(dropped, systemImage: "text.badge.minus").font(.callout)
                    .foregroundStyle(stats.droppedDescriptions.withNameOnly > 0 ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Some skills were listed by name only, usually because Claude Code's skill listing was over its budget (1% of the context window by default), or because of a user override (name-only). Such a skill can't be picked by its description, so the session doesn't count in Listed. Making unused skills manual gives the others their descriptions back.")
            }
            if all.isEmpty {
                Text(unusedOnly && !stats.skills.isEmpty ? "No unused skills in this window." : "No skill listings in this window.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("Skill")
                        Text("Owner")
                        Text("Listed").gridColumnAlignment(.trailing)
                        Text("Model calls").gridColumnAlignment(.trailing)
                        Text("User calls").gridColumnAlignment(.trailing)
                        Text("Last call").gridColumnAlignment(.trailing)
                        Text("≈ Tokens").gridColumnAlignment(.trailing)
                        Text("≈ Context space").gridColumnAlignment(.trailing)
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows(all), id: \.name) { skill in
                        GridRow {
                            Text(skill.name).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(skill.unused ? Color.orange : Color.primary)
                                .help("Counted since \(InsightsView.day(skill.windowStart)), the start of its current description or of the window"
                                      + (skill.unused ? ". Unused: no call by the model or you made in the window." : ""))
                            Text([InsightsView.ownerTitle(skill.owner.kind), skill.owner.name].compactMap { $0 }.joined(separator: " "))
                                .lineLimit(1).foregroundStyle(.secondary)
                            Text("\(skill.listedSessions) · \(InsightsView.count(skill.listedDays, "day"))")
                                .help("Sessions where it was listed with its description, on how many days")
                            Text(InsightsView.modelCalls(skill))
                                .help("Model calls in every session that listed it, by name only too: they protect it. The % is the share of the sessions in Listed with a model call. Pi's reads of its SKILL.md come after +.")
                            Text("\(skill.userCalls)")
                                .help("Times you called it with /\(skill.name) (or Pi's <skill> prompt); built-in commands don't count")
                            lastCall(skill.lastCall)
                            Text("≈ \(ContextSize.short(skill.approxTokens))")
                                .help("Its description in every request where it is listed")
                            Text("≈ \(ContextSize.short(skill.approxContextSpace))")
                                .help("≈ description tokens × requests, summed over the sessions where it was listed")
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
                showAllButton(all.count, noun: "Skills")
            }
        }
    }

    // MARK: MCP servers

    private var serversTable: some View {
        let all = sorted(tools.servers.filter { !unusedOnly || $0.unused }, calls: \.calls, weight: \.availableSessions,
                         last: \.lastCall, name: \.name)
        return VStack(alignment: .leading, spacing: 10) {
            toolsSummary
            if all.isEmpty {
                Text(unusedOnly && !tools.servers.isEmpty ? "No unused MCP servers in this window." : "No MCP server tools in this window.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("MCP server")
                        Text("Tools called").gridColumnAlignment(.trailing)
                        Text("Calls").gridColumnAlignment(.trailing)
                        Text("Available").gridColumnAlignment(.trailing)
                        Text("Last call").gridColumnAlignment(.trailing)
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    // One grid row per item: a server, or the open list of its tools without a call, across all columns.
                    ForEach(serverLines(rows(all))) { line in
                        switch line {
                        case .server(let server):
                            GridRow {
                                serverName(server)
                                Text("\(server.toolsCalled) / \(server.tools)")
                                    .help("Its tools with a call in the window, of the tools it had available or called")
                                calls(server.calls, unused: server.unused)
                                    .help("Calls of all its tools made in the window, subagent runs included")
                                Text("\(server.availableSessions)")
                                    .help("Sessions where at least one of its tools was available")
                                lastCall(server.lastCall)
                            }
                            .font(.callout.monospacedDigit())
                        case .notCalled(let server):
                            GridRow {
                                Text("Not called: " + server.unusedTools.map { Self.shortTool($0, server: server.name) }.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                    .padding(.leading, 20)
                                    .gridCellColumns(5)
                                    .gridCellUnsizedAxes(.horizontal)
                                    .help("Its tools without a call made in the window")
                            }
                        }
                    }
                }
                showAllButton(all.count, noun: "MCP Servers")
            }
            notes
        }
        .onAppear {
            if DebugSnapshot.options?.query == "open" { expanded = Set(tools.servers.map(\.name)) }
        }
    }

    /// A line of the MCP Servers table.
    enum ServerLine: Identifiable {
        case server(ToolsReport.Server)
        case notCalled(ToolsReport.Server)

        var id: String {
            switch self {
            case .server(let server): "server:" + server.name
            case .notCalled(let server): "notCalled:" + server.name
            }
        }
    }

    /// Each server, followed by its tools without a call while it is open.
    private func serverLines(_ servers: [ToolsReport.Server]) -> [ServerLine] {
        servers.flatMap { server in
            expanded.contains(server.name) && !server.unusedTools.isEmpty ? [.server(server), .notCalled(server)] : [.server(server)]
        }
    }

    /// The name, with a disclosure for the tools it never called in the window.
    @ViewBuilder
    private func serverName(_ server: ToolsReport.Server) -> some View {
        if server.unusedTools.isEmpty {
            Text(Self.cut(server.name)).lineLimit(1)
                .help(server.name)
        } else {
            let open = expanded.contains(server.name)
            Button {
                if open { expanded.remove(server.name) } else { expanded.insert(server.name) }
            } label: {
                Label(Self.cut(server.name), systemImage: open ? "chevron.down" : "chevron.right")
                    .lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(server.unused ? Color.orange : Color.primary)
            .help(open ? "Hide the tools of \(server.name) without a call" : "Show the \(InsightsView.count(server.unusedTools.count, "tool")) of \(server.name) without a call in the window")
        }
    }

    /// Long names (MCP tools, servers) cut in the middle, so the numbers stay in view; the tooltip has the whole name.
    static func cut(_ name: String, to limit: Int = 48) -> String {
        guard name.count > limit else { return name }
        let half = (limit - 1) / 2
        return name.prefix(half) + "…" + name.suffix(limit - 1 - half)
    }

    // MARK: Tools

    private var toolsTable: some View {
        let all = sorted(tools.tools.filter { !unusedOnly || $0.unused }, calls: \.calls, weight: \.availableSessions,
                         last: \.lastCall, name: \.name)
        return VStack(alignment: .leading, spacing: 10) {
            toolsSummary
            if all.isEmpty {
                Text(unusedOnly && !tools.tools.isEmpty ? "No unused tools in this window." : "No tools in this window.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("Tool")
                        Text("Harness")
                        Text("Calls").gridColumnAlignment(.trailing)
                        Text("Available").gridColumnAlignment(.trailing)
                        Text("Last call").gridColumnAlignment(.trailing)
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows(all)) { tool in
                        GridRow {
                            Text(Self.cut(tool.name)).lineLimit(1)
                                .foregroundStyle(tool.unused ? Color.orange : Color.primary)
                                .help(tool.name + (tool.server.map { ": a tool of the MCP server \($0)" } ?? ": a built-in or extension tool"))
                            Text(tool.harnesses.map(Self.harnessTitle).joined(separator: ", ")).lineLimit(1).foregroundStyle(.secondary)
                            calls(tool.calls, unused: tool.unused)
                                .help("Calls made in the window, subagent runs included, in \(InsightsView.count(tool.calledSessions, "session"))")
                            Text("\(tool.availableSessions) · \(InsightsView.count(tool.availableDays, "day"))")
                                .help(tool.server == nil
                                      ? "Sessions with a full tool list (a Claude Code prompt snapshot, Pi 1.0+) where it was available, on how many days"
                                      : "Sessions where it was listed, on how many days")
                            lastCall(tool.lastCall)
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
                showAllButton(all.count, noun: "Tools")
            }
            notes
        }
    }

    private var toolsSummary: some View {
        let summary = tools.summary
        return Text("\(InsightsView.count(summary.sessions, "session")), \(summary.sessionsWithToolList) with a full tool list · "
                    + "\(InsightsView.count(summary.calls, "tool call"))")
            .font(.callout).foregroundStyle(.secondary)
            .help("Sessions started in the window, and of them those with a full tool list (a Claude Code prompt snapshot with tools, Pi 1.0+); only those say which built-in tools were available. Tool calls: made in the window in the scope's sessions, subagent runs included.")
    }

    private var notes: some View {
        ForEach(tools.notes, id: \.self) { note in
            Text(note + ".").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Cells

    private func calls(_ calls: Int, unused: Bool) -> some View {
        Text(unused ? "Unused" : calls.formatted()).foregroundStyle(unused ? Color.orange : Color.primary)
    }

    private func lastCall(_ iso: String?) -> some View {
        Text(iso.map(InsightsView.day) ?? "—")
            .foregroundStyle(.secondary)
            .help(iso == nil ? "No call recorded in this scope's sessions"
                  : "The latest call in this scope's sessions, also before the window")
    }

    @ViewBuilder
    private func showAllButton(_ total: Int, noun: String) -> some View {
        if total > InsightsView.shortTable {
            Button(showAll ? "Show Fewer" : "Show All \(total) \(noun)") { showAll.toggle() }
                .buttonStyle(.link)
        }
    }

    private func rows<T>(_ all: [T]) -> [T] { showAll ? all : Array(all.prefix(InsightsView.shortTable)) }

    // MARK: Sorting

    /// `weight` breaks ties (the most first): context space for skills, sessions available for tools and servers.
    private func sorted<T>(_ items: [T], calls: (T) -> Int, weight: (T) -> Int, last: (T) -> String?, name: (T) -> String) -> [T] {
        items.sorted { a, b in
            let byName = name(a).localizedStandardCompare(name(b)) == .orderedAscending
            switch effectiveSort {
            case .contextSpace:
                return weight(a) != weight(b) ? weight(a) > weight(b) : byName
            case .fewestCalls, .mostCalls:
                if calls(a) != calls(b) { return effectiveSort == .fewestCalls ? calls(a) < calls(b) : calls(a) > calls(b) }
                return weight(a) != weight(b) ? weight(a) > weight(b) : byName
            case .leastRecent:
                // ISO 8601 in UTC sorts as text; never called comes first.
                let x = last(a) ?? "", y = last(b) ?? ""
                if x != y { return x < y }
                return weight(a) != weight(b) ? weight(a) > weight(b) : byName
            case .name:
                return byName
            }
        }
    }

    // MARK: Text

    /// `mcp__docs__search` → `search` within its server.
    static func shortTool(_ name: String, server: String) -> String {
        let prefix = "mcp__\(server)__"
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    static func harnessTitle(_ harness: String) -> String {
        switch harness {
        case "claude": "Claude Code"
        case "pi": "Pi"
        default: harness
        }
    }
}
