import AKitFoundation
import AKitLab
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
                            ContextMapView(footprint: footprint)
                        } else {
                            Label("This session has no recorded system prompt (older Claude Code versions don't write one), so its context can't be split into parts.",
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
    @State private var selected: ContextMapView.Block?
    @State private var asShare = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headline
            VStack(alignment: .leading, spacing: 8) {
                Text("First call").font(.headline)
                ContextTreemap(blocks: blocks, footprint: footprint, selected: $selected)
                    .frame(height: 360)
                legend
                if let selected {
                    detail(selected)
                } else {
                    Text("Click a block to see what it is, where it comes from and how much of the session it took.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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

    // MARK: Selection

    private func detail(_ block: Block) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(block.name).font(.headline)
                    Text(block.group.title).foregroundStyle(.secondary)
                    Spacer()
                    if let path = block.source, path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
                    }
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                    row("Size", "≈ \(UsageText.full(block.tokens)) tokens in every call")
                    row("Share", "\(Self.percent(footprint.shareOfFirstCall(block.tokens))) of the first call · "
                        + "\(Self.percent(footprint.shareOfSession(block.tokens))) of all context sent")
                    row("Use", useText(block))
                    if let source = block.source { row("From", source) }
                    if let detail = block.detail { row("Holds", detail) }
                    if block.use == .unused, let hint = Self.hint(block.group) { row("To cut", hint) }
                }
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private func useText(_ block: Block) -> String {
        switch block.use {
        case .used: "Called \(block.calls) time\(block.calls == 1 ? "" : "s") in this session"
        case .unused: block.count > 1 ? "None of them was called in this session" : "Never called in this session"
        case .always: "Sent with every call; whether the model followed it isn't recorded"
        case .conversation: "Not setup: what this session itself sent"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
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
        var count = 1

        init(_ part: ContextFootprint.Part) {
            id = part.id
            group = part.group
            name = part.name
            tokens = part.tokens
            use = part.use
            calls = part.calls
            source = part.source
            detail = part.detail
        }

        init(group: ContextFootprint.Group, use: ContextFootprint.Use, parts: [ContextFootprint.Part]) {
            id = "\(group.rawValue)|small|\(use.rawValue)"
            self.group = group
            name = "\(parts.count) small"
            tokens = parts.reduce(0) { $0 + $1.tokens }
            self.use = use
            calls = parts.reduce(0) { $0 + $1.calls }
            detail = parts.map(\.name).joined(separator: ", ")
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

    /// Where an unused part can be cut.
    static func hint(_ group: ContextFootprint.Group) -> String? {
        switch group {
        case .tools: "A tool of the harness or a plugin; a plugin's tools go away with the plugin."
        case .mcp: "Remove the server or turn it off for projects that don't need it (MCP screen)."
        case .skills: "Each listed skill's description is sent with every call. Make the skill manual or remove its plugin (Insights recommends this across many sessions)."
        case .subagents: "A subagent type from a plugin or an agents folder; its line is sent with every call."
        default: nil
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
