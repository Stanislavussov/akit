import AKitSessions
import Charts
import SwiftUI

/// How a session's tool calls ended: the shares of all calls, one bar per tool split by
/// outcome, and the failures with the first line of an example result.
struct ToolOutcomesView: View {
    let outcomes: ToolOutcomes
    @State private var allTools = false

    typealias Outcome = ToolOutcomes.Outcome

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tool calls").font(.title3.bold())
            if outcomes.calls == 0 {
                Text("The main conversation called no tools.").foregroundStyle(.secondary)
            } else {
                tiles
                overall
                perTool
                if !failures.isEmpty { failureTable }
                Text("Counts are exact. The kind of a failure is read from its result text, so it is a best guess. "
                     + "Deterministic: the same call fails the same way again (wrong input, a failing command). "
                     + "Transient: a timeout, the network or a rate limit; a retry may pass. Subagents' own calls aren't counted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        HStack(alignment: .top, spacing: 12) {
            tile("Calls", UsageText.full(outcomes.calls), "\(outcomes.tools.count) tool\(outcomes.tools.count == 1 ? "" : "s")", color: .primary)
            tile("Succeeded", ContextMapView.percent(outcomes.share(outcomes.count(.ok))), "\(outcomes.count(.ok)) calls",
                 color: Self.color(.ok))
            tile("Failed", ContextMapView.percent(outcomes.share(outcomes.failed)),
                 "\(outcomes.failed) calls · \(outcomes.deterministicFailures) deterministic", color: outcomes.failed > 0 ? Self.color(.inputMistake) : .secondary)
            tile("Rejected", ContextMapView.percent(outcomes.share(outcomes.count(.rejected))),
                 "\(outcomes.count(.rejected)) by you, a rule or a hook", color: outcomes.count(.rejected) > 0 ? Self.color(.rejected) : .secondary)
            tile("Interrupted", ContextMapView.percent(outcomes.share(outcomes.count(.interrupted))),
                 "\(outcomes.count(.interrupted)) calls", color: .secondary)
        }
    }

    private func tile(_ title: String, _ value: String, _ caption: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(color).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(10)
        .frame(minWidth: 110, maxWidth: 190, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Bars

    private var present: [Outcome] { Outcome.allCases.filter { outcomes.count($0) > 0 } }

    private var overall: some View {
        Chart(present, id: \.self) { outcome in
            BarMark(x: .value("Calls", outcomes.count(outcome)), y: .value("All", "All calls"))
                .foregroundStyle(by: .value("Outcome", outcome.title))
        }
        .chartForegroundStyleScale(domain: Outcome.allCases.map(\.title), range: Outcome.allCases.map(Self.color))
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 54)
    }

    struct Point: Identifiable {
        let tool: String
        let outcome: String
        let count: Int
        var id: String { "\(tool)|\(outcome)" }
    }

    private var shownTools: [ToolOutcomes.Tool] { allTools ? outcomes.tools : Array(outcomes.tools.prefix(12)) }

    private var points: [Point] {
        shownTools.flatMap { tool in
            Outcome.allCases.compactMap { outcome in
                tool.count(outcome) > 0 ? Point(tool: label(tool), outcome: outcome.title, count: tool.count(outcome)) : nil
            }
        }
    }

    private func label(_ tool: ToolOutcomes.Tool) -> String {
        let failed = tool.failed > 0 ? " · \(ContextMapView.percent(Double(tool.failed) / Double(tool.calls))) failed" : ""
        return "\(tool.displayName) (\(tool.calls))\(failed)"
    }

    private var perTool: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("By tool").font(.headline)
                Text("share of each tool's calls").foregroundStyle(.secondary)
                Spacer()
                if outcomes.tools.count > 12 {
                    Toggle("All \(outcomes.tools.count) tools", isOn: $allTools).toggleStyle(.checkbox)
                }
            }
            Chart(points) { point in
                BarMark(x: .value("Calls", point.count), y: .value("Tool", point.tool), height: .fixed(14), stacking: .normalized)
                    .foregroundStyle(by: .value("Outcome", point.outcome))
            }
            .chartForegroundStyleScale(domain: Outcome.allCases.map(\.title), range: Outcome.allCases.map(Self.color))
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks { _ in AxisValueLabel().font(.callout) }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(shownTools.count) * 37)
        }
    }

    // MARK: Failures

    private struct Failure: Identifiable {
        let tool: ToolOutcomes.Tool
        let outcome: Outcome
        var id: String { "\(tool.name)|\(outcome.rawValue)" }
    }

    private var failures: [Failure] {
        outcomes.tools.flatMap { tool in
            Outcome.allCases.filter { $0 != .ok && tool.count($0) > 0 }.map { Failure(tool: tool, outcome: $0) }
        }
        .sorted { $0.tool.count($0.outcome) > $1.tool.count($1.outcome) }
    }

    private var failureTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What went wrong").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Tool"); Text("Outcome"); Text("Kind"); Text("Calls"); Text("Example")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(failures) { failure in
                    GridRow {
                        Text(failure.tool.displayName).lineLimit(1)
                        HStack(spacing: 5) {
                            Circle().fill(Self.color(failure.outcome)).frame(width: 8, height: 8)
                            Text(failure.outcome.title)
                        }
                        Text(kind(failure.outcome)).foregroundStyle(.secondary)
                        Text("\(failure.tool.count(failure.outcome))").monospacedDigit().gridColumnAlignment(.trailing)
                        Text(failure.tool.examples[failure.outcome] ?? "")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func kind(_ outcome: Outcome) -> String {
        if outcome.isDeterministic { return "Deterministic" }
        switch outcome {
        case .transient: return "Transient"
        case .rejected: return "Policy"
        case .interrupted: return "By you"
        default: return "Unknown"
        }
    }

    static func color(_ outcome: Outcome) -> Color {
        switch outcome {
        case .ok: Color(red: 0.25, green: 0.66, blue: 0.36)
        case .rejected: .orange
        case .interrupted: .gray
        case .inputMistake: Color(red: 0.86, green: 0.27, blue: 0.24)
        case .commandFailed: Color(red: 0.62, green: 0.16, blue: 0.30)
        case .transient: .yellow
        case .otherError: .pink
        case .noResult: Color.secondary.opacity(0.4)
        }
    }
}
