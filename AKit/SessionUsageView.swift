import AKitModel
import AKitSessions
import SwiftUI

/// Number formats for token counts.
enum UsageText {
    /// "1.6M tokens · 45K output · peak context 180K · $0.75"
    static func summary(_ usage: SessionUsage) -> String {
        var parts = ["\(short(usage.tokens.total)) tokens", "\(short(usage.tokens.output)) output",
                     "peak context \(short(usage.peakContext))"]
        if usage.subagentRuns > 0 || !usage.subagentModels.isEmpty {
            parts.append("subagents \(short(usage.subagentTokens.total))")
        }
        if let cost = usage.cost { parts.append(money(cost)) }
        return parts.joined(separator: " · ")
    }

    static func short(_ value: Int) -> String { value.formatted(.number.notation(.compactName)) }
    static func full(_ value: Int) -> String { value.formatted(.number) }
    /// "$0.0123": dollar sign first and a decimal point, whatever the system region.
    static func money(_ value: Double) -> String { value.formatted(dollarStyle.precision(.fractionLength(2...4))) }
    /// Whole cents, for totals: "$1,234.56".
    static func dollars(_ value: Double) -> String { value.formatted(dollarStyle.precision(.fractionLength(2))) }
    private static let dollarStyle = FloatingPointFormatStyle<Double>.Currency(code: "USD", locale: Locale(identifier: "en_US"))

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }
}

/// Tokens per model, subagents and activity of one session.
struct SessionUsageView: View {
    let usage: SessionUsage

    var body: some View {
        if !usage.hasTokens && usage.toolCalls == 0 && usage.userPrompts == 0 {
            ContentUnavailableView("No usage recorded", systemImage: "chart.bar",
                                   description: Text("This session has no model responses with token counts."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if usage.hasTokens {
                        section("Tokens") { table }
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    section("Activity") { activity }
                    if !usage.tools.isEmpty {
                        section("Tools") { tools }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var note: String {
        var text = "Input excludes cache reads and writes. Reasoning is part of output."
        if usage.cost == nil { text += " This harness doesn't record cost." }
        return text
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private var table: some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Model").gridColumnAlignment(.leading)
                Text("Requests")
                Text("Input")
                Text("Output")
                Text("Reasoning")
                Text("Cache read")
                Text("Cache write")
                Text("Total")
                if usage.cost != nil { Text("Cost") }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(usage.models) { modelRow($0.id, $0.requests, $0.tokens, $0.cost) }
            ForEach(usage.subagentModels) { modelRow("Subagents: \($0.id)", $0.requests, $0.tokens, $0.cost, secondary: true) }
            if usage.models.count + usage.subagentModels.count > 1 {
                Divider()
                let all = usage.models + usage.subagentModels
                modelRow("Total", all.reduce(0) { $0 + $1.requests }, usage.tokens + usage.subagentTokens,
                         usage.cost)
                    .fontWeight(.semibold)
            }
        }
        .monospacedDigit()
        .textSelection(.enabled)
    }

    private func modelRow(_ name: String, _ requests: Int, _ tokens: TokenCounts, _ cost: Double?,
                          secondary: Bool = false) -> some View {
        GridRow {
            Text(name).foregroundStyle(secondary ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
            Text(UsageText.full(requests))
            Text(UsageText.full(tokens.input))
            Text(UsageText.full(tokens.output))
            Text(tokens.reasoning > 0 ? UsageText.full(tokens.reasoning) : "–")
            Text(UsageText.full(tokens.cacheRead))
            Text(UsageText.full(tokens.cacheWrite))
            Text(UsageText.full(tokens.total))
            if usage.cost != nil { Text(cost.map(UsageText.money) ?? "–") }
        }
    }

    private var activity: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            if usage.hasTokens {
                row("Context", "peak \(UsageText.full(usage.peakContext)), last \(UsageText.full(usage.lastContext)) tokens")
            }
            if let active = usage.activeTime {
                row("Active time", UsageText.duration(active))
            }
            if let first = usage.firstActivity, let last = usage.lastActivity {
                row("Wall time", UsageText.duration(last.timeIntervalSince(first)))
            }
            row("Prompts", UsageText.full(usage.userPrompts))
            row("Tool calls", usage.toolErrors > 0
                ? "\(UsageText.full(usage.toolCalls)) (\(UsageText.full(usage.toolErrors)) failed)"
                : UsageText.full(usage.toolCalls))
            if usage.compactions > 0 {
                row("Compactions", UsageText.full(usage.compactions))
            }
            if usage.subagentRuns > 0 {
                row("Subagent runs", UsageText.full(usage.subagentRuns))
            }
        }
        .monospacedDigit()
        .textSelection(.enabled)
    }

    private var tools: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(usage.tools, id: \.name) { tool in
                GridRow {
                    Text(tool.name).monospaced()
                    Text(UsageText.full(tool.calls)).monospacedDigit().gridColumnAlignment(.trailing)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value)
        }
    }
}
