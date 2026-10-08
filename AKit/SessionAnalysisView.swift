import AKitLab
import AKitSessions
import SwiftUI

/// Lab metrics of one Claude Code session: what it cost, where the context went,
/// friction and commits. Computed from the transcript and git when the tab opens.
struct SessionAnalysisView: View {
    @Environment(AppModel.self) private var model
    let session: SessionSummary
    @State private var metrics: SessionMetrics?
    @State private var error: String?

    var body: some View {
        Group {
            if let metrics {
                ScrollView {
                    MetricsView(metrics: metrics)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let error {
                ContentUnavailableView("Couldn't analyze the session", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(session.id)|\(session.modified.timeIntervalSince1970)") {
            metrics = nil
            error = nil
            do {
                let loaded = try await model.analysis(of: session)
                guard !Task.isCancelled else { return }
                metrics = loaded
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

/// The sections of a session's metrics; also shown for Lab runs.
struct MetricsView: View {
    let metrics: SessionMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Cost") { cost }
            if metrics.contextRent.total > 0 {
                section("Context rent") { ContextRentView(rent: metrics.contextRent) }
            }
            section("Friction") { friction }
            if !metrics.commits.isEmpty {
                section("Commits") { commits }
            }
            Text("Numbers come from the recorded transcript and git, never from the agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private var cost: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            row("API calls", UsageText.full(metrics.calls)
                + (metrics.subagentCalls > 0 ? " (subagents \(UsageText.full(metrics.subagentCalls)))" : ""),
                help: "One per model response of the main conversation")
            row("Fresh tokens", UsageText.full(metrics.freshTokens)
                + (metrics.subagentFreshTokens > 0 ? " (subagents \(UsageText.full(metrics.subagentFreshTokens)))" : ""),
                help: "Input + cache writes + output: what each call added. Cache reads are the context sent again.")
            row("Cache reads", UsageText.full(metrics.cacheReadTokens))
            row("Output", UsageText.full(metrics.outputTokens))
            row("Context", "baseline \(UsageText.full(metrics.baselineContext)) · peak \(UsageText.full(metrics.peakContext))",
                help: "Baseline: the first call (system prompt, tools, instructions, skill listing)")
            if let wall = metrics.wallSeconds {
                row("Time", "wall \(UsageText.duration(TimeInterval(wall)))"
                    + (metrics.activeSeconds.map { " · active \(UsageText.duration(TimeInterval($0)))" } ?? ""))
            }
            if !metrics.models.isEmpty { row("Models", metrics.models.joined(separator: ", ")) }
        }
        .monospacedDigit()
        .textSelection(.enabled)
    }

    private var friction: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Tool calls", UsageText.full(metrics.toolCalls))
            row("Failed", UsageText.full(metrics.toolErrors), warn: metrics.toolErrors > 0,
                help: "Tool calls that ended with an error, without rejected and interrupted ones")
            row("Re-reads", UsageText.full(metrics.rereads), warn: metrics.rereads > 0,
                help: "Read of a file and range already read, with no edit of it in between")
            row("Rejected", UsageText.full(metrics.rejected), warn: metrics.rejected > 0,
                help: "Tool calls refused by you, a permission rule or the auto mode classifier")
            row("Interrupts", UsageText.full(metrics.interrupts), warn: metrics.interrupts > 0,
                help: "Times you stopped the agent: your messages that start with [Request interrupted by user")
            if let repeated = metrics.repeatedCalls {
                row("Repeated calls", UsageText.full(repeated), warn: repeated > 0,
                    help: "The same tool with the same input 3 or more times in a row; each run counts once")
            }
            if metrics.compactions > 0 { row("Compactions", UsageText.full(metrics.compactions)) }
        }
        .monospacedDigit()
    }

    private var commits: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(metrics.commits, id: \.sha) { commit in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(commit.sha.prefix(9)).monospaced().foregroundStyle(.secondary)
                    Text(commit.subject).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    switch commit.onMainBranch {
                    case true?: Label("On main", systemImage: "checkmark.circle").foregroundStyle(.green)
                    case false?: Label("Not on main", systemImage: "arrow.triangle.branch").foregroundStyle(.orange)
                    case nil: Label("Unknown", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                            .help("The session's folder is gone or isn't a git repository")
                    }
                }
                .font(.callout)
                .textSelection(.enabled)
            }
        }
    }

    private func row(_ label: String, _ value: String, warn: Bool = false, help: String? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).foregroundStyle(warn ? .orange : .primary)
        }
        .help(help ?? "")
    }
}

/// One stacked bar and a legend: where the tokens sent to the model came from.
struct ContextRentView: View {
    let rent: ContextRent

    private var parts: [(name: String, value: Int, color: Color, help: String)] {
        [("Baseline", rent.baseline, .gray, "System prompt, tools, instructions and skill listing of the first call"),
         ("Reading code", rent.readCode, .blue, "Read, Grep, Glob and read-only shell commands (cat, sed -n, grep…)"),
         ("Own output", rent.ownOutput, .purple, "The agent's text, thinking and tool inputs, heredoc writes included"),
         ("Injections", rent.injections, .orange, "Hook context, reminders and loaded skills added by the harness and plugins"),
         ("Other", rent.other, .teal, "Your prompts, other tool results and what the characters don't explain")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.name) { part in
                        Rectangle()
                            .fill(part.color.gradient)
                            .frame(width: max(0, geometry.size.width * rent.share(part.value) - 1))
                    }
                }
            }
            .frame(height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(parts, id: \.name) { part in
                    GridRow {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(part.color).frame(width: 10, height: 10)
                            Text(part.name)
                        }
                        Text(MetricsText.percent(rent.share(part.value))).gridColumnAlignment(.trailing)
                        Text("≈ \(UsageText.short(part.value)) tokens sent").foregroundStyle(.secondary)
                    }
                    .help(part.help)
                }
            }
            .monospacedDigit()
            Text("Each piece of context counts once per call that sent it again. The growth between two calls is split by characters, so the parts are approximate.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}
