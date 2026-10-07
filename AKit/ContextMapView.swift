import AKitFoundation
import AKitHarnesses
import AKitLab
import AKitMCP
import AKitModel
import AKitSessions
import AppKit
import Charts
import SwiftUI

/// Sessions → Overview: what happened in one session at a glance. Where its context went
/// (what the harness setup costs in every call and which parts the session never used) and
/// how its tool calls ended. Read from the session file when the tab opens.
struct SessionOverviewView: View {
    let session: SessionSummary
    @State private var overview: SessionOverview?
    @State private var error: String?

    var body: some View {
        Group {
            if let overview {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if let footprint = overview.footprint {
                            ContextMapView(footprint: footprint, project: session.project)
                        } else {
                            Label("This session has no recorded system prompt (Claude Code writes one from 2.1.26x, Pi from 1.0), so its context can't be split into parts.",
                                  systemImage: "square.grid.3x3.square")
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        ToolOutcomesView(outcomes: overview.tools).id("tools")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .task {
                    // Snapshots of the lower parts: `--query calls|tools`.
                    guard let target = DebugSnapshot.options?.query, ["calls", "tools"].contains(target) else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo(target, anchor: .top)
                }
                }
            } else if let error {
                ContentUnavailableView("Couldn't read the session", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(session.id)|\(session.modified.timeIntervalSince1970)") {
            overview = nil
            error = nil
            let session = session
            do {
                let read = try await Task.detached(priority: .userInitiated) { try SessionOverview.read(session) }.value
                guard !Task.isCancelled else { return }
                overview = read ?? SessionOverview(footprint: nil, tools: ToolOutcomes(tools: []))
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

/// The map of one session's context: the headline numbers, a treemap of the first call
/// (area = tokens, color = used or not), the setup's share of every call, and the biggest
/// unused parts.
struct ContextMapView: View {
    let footprint: ContextFootprint
    /// The session's folder: where project rules, skills and settings are.
    var project: URL?
    @State private var selected: ContextMapView.Block?
    @State private var asShare = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headline
            VStack(alignment: .leading, spacing: 8) {
                Text("First call").font(.headline)
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        ContextTreemap(blocks: blocks, footprint: footprint, selected: $selected)
                            .frame(height: 420)
                        legend
                    }
                    .frame(minWidth: 420, maxWidth: .infinity)
                    Group {
                        if let selected {
                            ScrollView {
                                ContextPartDetail(block: selected, footprint: footprint, project: project) { self.selected = Block($0) }
                                    .id(selected.id)
                            }
                        } else {
                            Text("Click a block to see what it is, the text the model gets, the file that defines it "
                                 + "and how to cut it.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                    .frame(width: 380, height: 450, alignment: .topLeading)
                }
            }
            if footprint.callContexts.count > 1 { calls.id("calls") }
            if !unused.isEmpty { biggestUnused }
            Text("Call contexts are recorded. The parts are estimated from their characters and fitted to the first call's "
                 + "recorded context. A part loaded at the start is sent again with every call, so the setup's tokens count once per call.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Snapshots: `--select <part name>` opens a block.
        .task {
            guard let name = DebugSnapshot.options?.select, selected == nil else { return }
            selected = blocks.first { $0.name == name }
        }
    }

    // MARK: Headline

    private var headline: some View {
        let unused = footprint.tokens(.unused)
        let calls = footprint.callContexts.count
        return HStack(alignment: .top, spacing: 12) {
            tile("Unused setup", "≈ \(UsageText.short(unused))", "tokens in every call", color: .red)
            tile("Of the first call", Self.percent(footprint.shareOfFirstCall(unused)),
                 "setup in all: \(Self.percent(footprint.shareOfFirstCall(footprint.setupTokens)))", color: .red)
            tile("Of the whole session", Self.percent(footprint.shareOfSession(unused)),
                 "≈ \(UsageText.short(unused * calls)) of \(UsageText.short(footprint.sent)) sent in \(calls) call\(calls == 1 ? "" : "s")",
                 color: .red)
        }
    }

    private func tile(_ title: String, _ value: String, _ caption: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(color).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(10)
        .frame(minWidth: 150, maxWidth: 230, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([ContextFootprint.Use.unused, .used, .always, .conversation], id: \.self) { use in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Self.color(use)).frame(width: 10, height: 10)
                    Text(Self.title(use))
                }
            }
        }
        .font(.caption)
    }

    // MARK: Calls

    private var calls: some View {
        let calls = footprint.calls
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Every call").font(.headline)
                Spacer()
                Picker("", selection: $asShare) {
                    Text("Tokens").tag(false)
                    Text("Share").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            CallsChart(points: Self.points(calls), asShare: asShare)
                .frame(height: 200)
            if let first = calls.first, let last = calls.last {
                Text("Unused setup is \(Self.percent(first.unusedShare)) of call 1 and "
                     + "\(Self.percent(last.unusedShare)) of call \(last.id): the same tokens, sent again with each call.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static let seriesNames = ["Unused setup", "Used setup", "Always loaded", "Conversation"]

    static func points(_ calls: [ContextFootprint.Call]) -> [CallsChart.Point] {
        calls.flatMap { call in
            zip(seriesNames, [call.unused, call.used, call.always, call.conversation]).map {
                CallsChart.Point(call: call.id, series: $0, tokens: $1)
            }
        }
    }

    static func seriesColor(_ name: String) -> Color {
        switch name {
        case seriesNames[0]: color(.unused)
        case seriesNames[1]: color(.used)
        case seriesNames[2]: color(.always)
        default: color(.conversation)
        }
    }

    // MARK: Biggest unused

    private var unused: [ContextFootprint.Part] {
        Array(footprint.parts.filter { $0.use == .unused }.prefix(10))
    }

    private var biggestUnused: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Biggest unused parts").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("Part"); Text("Kind"); Text("≈ Tokens"); Text("First call"); Text("Session")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(unused) { part in
                    GridRow {
                        Button(part.name) { selected = Block(part) }
                            .buttonStyle(.link)
                            .lineLimit(1)
                        Text(part.group.title).foregroundStyle(.secondary)
                        Text(UsageText.short(part.tokens)).gridColumnAlignment(.trailing)
                        Text(Self.percent(footprint.shareOfFirstCall(part.tokens))).gridColumnAlignment(.trailing)
                        Text(Self.percent(footprint.shareOfSession(part.tokens))).gridColumnAlignment(.trailing)
                    }
                    .font(.callout)
                }
            }
            .monospacedDigit()
        }
    }

    // MARK: Blocks

    /// A treemap block: one part, or a group's small parts of one use put together.
    struct Block: Identifiable, Hashable {
        var id: String
        var group: ContextFootprint.Group
        var name: String
        var tokens: Int
        var use: ContextFootprint.Use
        var calls = 0
        var source: String?
        var detail: String?
        var text: String?
        var count = 1
        /// The parts of a block of small ones, biggest first.
        var members: [ContextFootprint.Part] = []

        init(_ part: ContextFootprint.Part) {
            id = part.id
            group = part.group
            name = part.name
            tokens = part.tokens
            use = part.use
            calls = part.calls
            source = part.source
            detail = part.detail
            text = part.text
        }

        init(group: ContextFootprint.Group, use: ContextFootprint.Use, parts: [ContextFootprint.Part]) {
            id = "\(group.rawValue)|small|\(use.rawValue)"
            self.group = group
            name = "\(parts.count) small"
            tokens = parts.reduce(0) { $0 + $1.tokens }
            self.use = use
            calls = parts.reduce(0) { $0 + $1.calls }
            members = parts.sorted { $0.tokens > $1.tokens }
            count = parts.count
        }
    }

    /// Parts under 0.3% of the first call are put together per group and use, so the map stays readable.
    private var blocks: [Block] {
        let small = max(1, footprint.firstCall * 3 / 1000)
        var blocks: [Block] = []
        for group in ContextFootprint.Group.allCases {
            let parts = footprint.parts.filter { $0.group == group }
            blocks += parts.filter { $0.tokens >= small }.map(Block.init)
            for use in [ContextFootprint.Use.unused, .used, .always, .conversation] {
                let tiny = parts.filter { $0.tokens < small && $0.use == use }
                if tiny.count == 1 { blocks.append(Block(tiny[0])) }
                if tiny.count > 1 { blocks.append(Block(group: group, use: use, parts: tiny)) }
            }
        }
        return blocks
    }

    /// `34%`, `4.2%`, `<0.1%`: small parts keep a decimal, so they don't read as 0.
    static func percent(_ share: Double) -> String {
        let value = share * 100
        if value <= 0 { return "0%" }
        if value < 0.1 { return "<0.1%" }
        if value < 10 { return String(format: "%.1f%%", value) }
        return "\(Int(value.rounded()))%"
    }

    static func color(_ use: ContextFootprint.Use) -> Color {
        switch use {
        case .unused: Color(red: 0.86, green: 0.27, blue: 0.24)
        case .used: Color(red: 0.25, green: 0.66, blue: 0.36)
        case .always: Color.gray
        case .conversation: Color(red: 0.42, green: 0.62, blue: 0.86)
        }
    }

    static func title(_ use: ContextFootprint.Use) -> String {
        switch use {
        case .unused: "Never used"
        case .used: "Used"
        case .always: "Always loaded"
        case .conversation: "Conversation"
        }
    }
}

/// The treemap: one framed area per group, its blocks inside, area = tokens.
private struct ContextTreemap: View {
    let blocks: [ContextMapView.Block]
    let footprint: ContextFootprint
    @Binding var selected: ContextMapView.Block?

    var body: some View {
        GeometryReader { geometry in
            let groups = ContextFootprint.Group.allCases.filter { group in blocks.contains { $0.group == group } }
            let sums = groups.map { group in Double(blocks.filter { $0.group == group }.reduce(0) { $0 + $1.tokens }) }
            let frames = TreemapLayout.squarify(sums, in: CGRect(origin: .zero, size: geometry.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(groups.enumerated()), id: \.element) { index, group in
                    groupView(group, tokens: Int(sums[index]), frame: frames[index])
                }
            }
        }
    }

    @ViewBuilder
    private func groupView(_ group: ContextFootprint.Group, tokens: Int, frame: CGRect) -> some View {
        let header: CGFloat = frame.height > 44 && frame.width > 70 ? 17 : 0
        let inner = CGRect(x: frame.minX + 1, y: frame.minY + header + 1, width: max(0, frame.width - 2), height: max(0, frame.height - header - 2))
        let members = blocks.filter { $0.group == group }.sorted { $0.tokens > $1.tokens }
        let rects = TreemapLayout.squarify(members.map { Double($0.tokens) }, in: inner)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(.background.secondary)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                .frame(width: max(0, frame.width - 2), height: max(0, frame.height - 2))
                .offset(x: frame.minX + 1, y: frame.minY + 1)
            if header > 0 {
                Text("\(group.title) · \(UsageText.short(tokens)) · \(ContextMapView.percent(footprint.shareOfFirstCall(tokens)))")
                    .font(.caption.bold())
                    .lineLimit(1)
                    .frame(width: max(0, frame.width - 10), alignment: .leading)
                    .offset(x: frame.minX + 6, y: frame.minY + 2)
            }
            ForEach(Array(members.enumerated()), id: \.element.id) { index, block in
                blockView(block, frame: rects[index])
            }
        }
    }

    private func blockView(_ block: ContextMapView.Block, frame: CGRect) -> some View {
        let isSelected = selected?.id == block.id
        let share = ContextMapView.percent(footprint.shareOfFirstCall(block.tokens))
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(ContextMapView.color(block.use).opacity(isSelected ? 1 : 0.78))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(isSelected ? Color.primary : .clear, lineWidth: 2))
            if frame.width > 46, frame.height > 18 {
                VStack(alignment: .leading, spacing: 0) {
                    Text(block.name).font(.caption.weight(.medium)).lineLimit(frame.height > 44 ? 2 : 1)
                    if frame.height > 32 {
                        Text("\(UsageText.short(block.tokens)) · \(share)").font(.caption2).monospacedDigit().opacity(0.85)
                    }
                }
                .foregroundStyle(.white)
                .padding(4)
            }
        }
        .frame(width: max(0, frame.width - 2), height: max(0, frame.height - 2), alignment: .topLeading)
        .clipped()
        .offset(x: frame.minX + 1, y: frame.minY + 1)
        .contentShape(Rectangle())
        .onTapGesture { selected = isSelected ? nil : block }
        .help("\(block.name) · \(block.group.title) · ≈ \(UsageText.short(block.tokens)) tokens · \(share) of the first call · \(ContextMapView.title(block.use))")
    }
}

/// Each call's context as a stacked bar: the setup by use, then the conversation.
struct CallsChart: View {
    struct Point: Identifiable {
        let call: Int
        let series: String
        let tokens: Int
        var id: String { "\(call)|\(series)" }
    }

    let points: [Point]
    let asShare: Bool

    var body: some View {
        Chart(points) { point in
            BarMark(x: .value("Call", point.call), y: .value("Tokens", point.tokens), stacking: asShare ? .normalized : .standard)
                .foregroundStyle(by: .value("Part", point.series))
        }
        .chartForegroundStyleScale(domain: ContextMapView.seriesNames, range: ContextMapView.seriesNames.map(ContextMapView.seriesColor))
        .chartXAxisLabel("Call")
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { label(value.as(Double.self) ?? 0) }
            }
        }
    }

    private func label(_ number: Double) -> Text {
        Text(asShare ? MetricsText.percent(number) : UsageText.short(Int(number)))
    }
}

/// What a selected block is: its numbers, its text, the files that define it and how to cut it.
private struct ContextPartDetail: View {
    @Environment(AppModel.self) private var model
    let block: ContextMapView.Block
    let footprint: ContextFootprint
    let project: URL?
    /// Opens one part of a block of small ones.
    let open: (ContextFootprint.Part) -> Void
    @State private var files: [URL] = []
    @State private var showText = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(block.name).font(.headline).textSelection(.enabled)
                    Text(block.group.title).foregroundStyle(.secondary)
                    Spacer()
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                    row("Size", "≈ \(UsageText.full(block.tokens)) tokens in every call")
                    row("Share", "\(ContextMapView.percent(footprint.shareOfFirstCall(block.tokens))) of the first call · "
                        + "\(ContextMapView.percent(footprint.shareOfSession(block.tokens))) of all context sent")
                    row("Use", useText)
                    if let source = block.source { row("From", source) }
                    if let detail = block.detail { row("Holds", detail) }
                    if let hint { row(block.use == .unused ? "To cut" : "To change", hint) }
                }
                .textSelection(.enabled)
                if !block.members.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(block.members) { part in
                            HStack {
                                Button(part.name) { open(part) }.buttonStyle(.link).lineLimit(1)
                                Spacer()
                                Text("≈ \(UsageText.short(part.tokens))").foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }
                if !files.isEmpty || server != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(files, id: \.self) { file in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.tildePath).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                                    .textSelection(.enabled)
                                HStack(spacing: 8) {
                                    if !ClaudeSetupFiles.mayHoldKeys(file) {
                                        Button("Open") { NSWorkspace.shared.open(file) }
                                            .help("Open the file in its default app to edit it")
                                    }
                                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                                        .help(ClaudeSetupFiles.mayHoldKeys(file) ? "The file may hold keys, so AKit doesn't open it" : "")
                                }
                            }
                            .controlSize(.small)
                        }
                        if let server {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Defined in \(server.file.tildePath)").font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    Button("Show in MCP Servers") { model.section = .mcp }
                                    if !ClaudeSetupFiles.neverOffered.contains(server.file.lastPathComponent) {
                                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([server.file]) }
                                            .help("The file may hold keys, so AKit doesn't open it")
                                    }
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
                if let text = block.text, !text.isEmpty {
                    DisclosureGroup("Text sent to the model (\(UsageText.full(text.count)) characters)", isExpanded: $showText) {
                        ScrollView {
                            Text(text)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: 280)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: block.id) {
            let block = block, project = project, home = HarnessEnvironment.current.homeDirectory
            let harness = footprint.harness
            files = await Task.detached { Self.files(of: block, harness: harness, home: home, project: project) }.value
        }
    }

    /// The files that define the part.
    nonisolated static func files(of block: ContextMapView.Block, harness: HarnessID, home: URL, project: URL?) -> [URL] {
        guard block.count == 1 else { return [] }
        if harness == .pi { return piFiles(of: block, home: home, project: project) }
        switch block.group {
        case .rules:
            return block.source.map { [URL(filePath: $0)] }?.filter { FileManager.default.fileExists(atPath: $0.path) } ?? []
        case .skills: return ClaudeSetupFiles.files(.skill, name: block.name, home: home, project: project)
        case .subagents: return ClaudeSetupFiles.files(.subagent, name: block.name, home: home, project: project)
        case .hooks: return ClaudeSetupFiles.files(.hook, name: block.name, home: home, project: project)
        case .mcp: return ClaudeSetupFiles.files(.mcpServer, name: block.name, home: home, project: project)
        case .tools: return ClaudeSetupFiles.files(.settings, name: block.name, home: home, project: project)
        case .systemPrompt, .other, .conversation: return []
        }
    }

    /// Pi records the path of every AGENTS.md and SKILL.md; tools are chosen in settings.json.
    /// mcp.json may hold keys, so it isn't offered (the MCP Servers screen shows the server).
    nonisolated static func piFiles(of block: ContextMapView.Block, home: URL, project: URL?) -> [URL] {
        let fm = FileManager.default
        switch block.group {
        case .rules, .skills:
            guard let path = block.source, fm.fileExists(atPath: path) else { return [] }
            return [URL(filePath: path)]
        case .tools:
            let root = HarnessCatalog.configRoot(of: .pi, in: .current) ?? home.appending(path: ".pi/agent")
            return [root.appending(path: "settings.json"), project?.appending(path: ".pi/settings.json")]
                .compactMap { $0 }.filter { fm.fileExists(atPath: $0.path) }
        default:
            return []
        }
    }

    /// The MCP server as AKit's MCP Servers screen knows it: one this harness uses, the
    /// session's project entry before a user-wide one.
    private var server: MCPServer? {
        guard block.group == .mcp, block.count == 1 else { return nil }
        let key = ContextFootprint.serverKey(block.name)
        let candidates = model.mcpServers.filter {
            ContextFootprint.serverKey($0.name) == key && $0.usedBy.contains(footprint.harness)
        }
        let projectPath = project?.standardizedFileURL.path
        func inProject(_ server: MCPServer) -> Bool {
            guard let projectPath else { return false }
            return server.file.standardizedFileURL.path.hasPrefix(projectPath + "/") || server.keyPath.contains(projectPath)
        }
        return candidates.first(where: inProject) ?? candidates.first { $0.scope == .global } ?? candidates.first
    }

    private var useText: String {
        switch block.use {
        case .used: "Called \(block.calls) time\(block.calls == 1 ? "" : "s") in this session"
        case .unused: block.count > 1 ? "None of them was called in this session" : "Never called in this session"
        case .always: "Sent with every call; whether the model followed it isn't recorded"
        case .conversation: "Not setup: what this session itself sent"
        }
    }

    /// How to turn the part off or shrink it. Check the next session's Overview to see that it went.
    private var hint: String? {
        footprint.harness == .pi ? piHint : claudeHint
    }

    /// Pi's switches, from its docs (settings.md, skills.md, mcp.md).
    private var piHint: String? {
        switch block.group {
        case .tools:
            "Remove it from the tools Pi declares: \"defaultTools\": [\"-\(block.name)\"] in settings.json, or name only the tools you need with --tools."
        case .skills:
            "Each listed skill's name, description and path are sent with every call. Add disable-model-invocation: true "
                + "to its SKILL.md: /skill:\(block.name) still runs it, the model no longer sees it."
        case .mcp:
            "Turn the server off (\"enabled\": false) or narrow its exposure in ~/.pi/agent/mcp.json or .pi/mcp.json, or with /mcp."
        case .rules:
            "Sent with every call: shorten it, or move rarely needed parts into a skill."
        case .systemPrompt:
            "Part of Pi's own prompt."
        default:
            nil
        }
    }

    private var claudeHint: String? {
        let paths = files.map(\.path)
        switch block.group {
        case .tools where block.name == "Artifact":
            return "Turn artifacts off: \"enableArtifact\": false in ~/.claude/settings.json, /config → Artifacts, "
                + "or CLAUDE_CODE_DISABLE_ARTIFACT=1 (code.claude.com/docs/en/artifacts)."
        case .tools:
            return "A tool built into Claude Code. A deny rule with its bare name removes it from Claude's context: "
                + "\"permissions\": {\"deny\": [\"\(block.name)\"]} in settings.json, or --disallowedTools \(block.name) "
                + "(code.claude.com/docs/en/cli-reference)."
        case .mcp:
            return "Remove the server, or turn it off for projects that don't need it. With tool search on (the default) "
                + "only its tool names and instructions are sent until the model loads a tool."
        case .skills where paths.contains { $0.contains("/plugins/") }:
            return "Each listed skill's description is sent with every call. This one comes with a plugin, and an update "
                + "replaces the plugin's files: turn the plugin off (/plugin) if you don't need its skills here."
        case .skills where paths.contains { $0.contains("/skills/synced/") }:
            return "Each listed skill's description is sent with every call. claude.ai syncs this one from your account: "
                + "turn it off in your claude.ai skills settings."
        case .skills where paths.isEmpty:
            return "Each listed skill's description is sent with every call. AKit found no file for it: it comes with "
                + "Claude Code itself or from a source AKit doesn't read."
        case .skills:
            return "Each listed skill's description is sent with every call. Make the skill manual "
                + "(disable-model-invocation: true in its SKILL.md) or remove it; Insights recommends this across many sessions."
        case .subagents where paths.isEmpty:
            return "Its line in the subagent list is sent with every call. AKit found no file for it: it is built into Claude Code."
        case .subagents:
            return "Its line in the subagent list is sent with every call. Remove the file, or the plugin it comes with."
        case .rules:
            return "Sent with every call: shorten it, or move rarely needed parts into a skill."
        case .hooks where paths.isEmpty:
            return "Its output is added to the context. It isn't in a file AKit offers (settings.local.json, managed settings "
                + "or a plugin's plugin.json)."
        case .hooks:
            return "Its output is added to the context. Change or remove the hook in the file below."
        case .systemPrompt:
            return "Part of Claude Code's own prompt; some sections come with features or plugins (output styles, MCP servers, browser tools)."
        case .other, .conversation:
            return nil
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
