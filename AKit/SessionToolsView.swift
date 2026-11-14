import AKitSessions
import Charts
import SwiftUI

/// Sessions → Tools: what each tool or MCP server cost in context, tokens and dollars, as a chart
/// and a table sorted by any column.
struct SessionToolsView: View {
    let costs: ToolCosts

    enum Group: String, CaseIterable, Identifiable {
        case tools, servers
        var id: Self { self }
        var title: String { self == .tools ? "Tools" : "MCP servers" }
    }

    enum Metric: String, CaseIterable, Identifiable {
        case tokens, cost, added, reread, calls, largest
        var id: Self { self }
        var title: String {
            switch self {
            case .tokens: "Tokens"
            case .cost: "Cost"
            case .added: "Added"
            case .reread: "Re-read"
            case .calls: "Calls"
            case .largest: "Largest"
            }
        }

        func value(_ tool: ToolCosts.Tool) -> Double {
            switch self {
            case .tokens: Double(tool.tokens)
            case .cost: tool.cost ?? 0
            case .added: Double(tool.added)
            case .reread: Double(tool.reread)
            case .calls: Double(tool.calls)
            case .largest: Double(tool.largest)
            }
        }
    }

    @State private var group = Group.tools
    @State private var metric = Metric.tokens
    @State private var mostFirst = true

    private var hasCost: Bool { costs.cost != nil }
    private var metrics: [Metric] { Metric.allCases.filter { $0 != .cost || hasCost } }

    private var rows: [ToolCosts.Tool] {
        let all = group == .tools ? costs.tools : costs.servers
        return all.sorted { a, b in
            let (x, y) = (metric.value(a), metric.value(b))
            if x != y { return mostFirst ? x > y : x < y }
            return a.name < b.name
        }
    }

    var body: some View {
        if costs.tools.isEmpty {
            ContentUnavailableView("No tool calls", systemImage: "wrench.and.screwdriver",
                                   description: Text("This session has no tool calls with recorded token counts."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    totals
                    controls
                    chart
                    table
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var totals: some View {
        HStack(spacing: 24) {
            tile("Calls", UsageText.full(costs.tools.reduce(0) { $0 + $1.calls }))
            tile("Added to context", UsageText.short(costs.tools.reduce(0) { $0 + $1.added }))
            tile("Tokens", UsageText.short(costs.tools.reduce(0) { $0 + $1.tokens }))
            if let cost = costs.cost { tile(costs.estimated ? "Cost (estimated)" : "Cost", UsageText.money(cost)) }
        }
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
        .askAKit("Session tools: \(label)", facts: ["\(label): \(value)"])
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $group) {
                ForEach(Group.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(costs.servers.isEmpty)
            Picker("Sort by", selection: $metric) {
                ForEach(metrics) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Picker("Order", selection: $mostFirst) {
                Text("Most first").tag(true)
                Text("Least first").tag(false)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private var chart: some View {
        let shown = Array(rows.prefix(15))
        return Chart(shown) { tool in
            BarMark(x: .value(metric.title, metric.value(tool)), y: .value("Tool", label(tool)))
                .annotation(position: .trailing) {
                    Text(format(metric, tool)).font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartYScale(domain: shown.map(label))
        .frame(height: CGFloat(max(shown.count, 1)) * 24 + 30)
    }

    private func label(_ tool: ToolCosts.Tool) -> String { group == .tools ? tool.displayName : tool.name }

    private func format(_ metric: Metric, _ tool: ToolCosts.Tool) -> String {
        switch metric {
        case .cost: tool.cost.map(UsageText.money) ?? "–"
        case .calls: UsageText.full(tool.calls)
        default: UsageText.short(Int(metric.value(tool)))
        }
    }

    private var table: some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text(group.title).gridColumnAlignment(.leading)
                ForEach(metrics) { column in
                    Button {
                        if metric == column { mostFirst.toggle() } else { (metric, mostFirst) = (column, true) }
                    } label: {
                        HStack(spacing: 2) {
                            Text(column.title)
                            if metric == column { Image(systemName: mostFirst ? "chevron.down" : "chevron.up") }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Sort by \(column.title)")
                }
                Text("Share")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(rows) { tool in
                GridRow {
                    Text(label(tool)).monospaced().lineLimit(1).truncationMode(.middle)
                    ForEach(metrics) { Text(format($0, tool)) }
                    Text(costs.lastContext > 0
                         ? (Double(tool.added) / Double(costs.lastContext)).formatted(.percent.precision(.fractionLength(1))) : "–")
                }
                .askAKit("Session tool cost: \(label(tool))", facts: metrics.map { "\($0.title): \(format($0, tool))" })
            }
        }
        .monospacedDigit()
        .textSelection(.enabled)
    }

    private var note: String {
        var text = "Added: tokens a tool's results added to the context (the recorded growth of the next request, "
            + "split by result length). Re-read: the same tokens read again by later requests until a compaction. "
            + "Tokens: added plus re-read. Share: added, as part of the last request's context."
        if costs.estimated {
            text += " Cost is estimated from Anthropic list prices: added tokens at the cache write price, re-reads at the cache read price."
        } else if hasCost {
            text += " Cost: the tool's share of each request's recorded cost."
        } else {
            text += " No cost: the harness records none and the model has no known price."
        }
        return text
    }
}
