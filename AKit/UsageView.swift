import AKitCore
import SwiftUI

/// How far back the Usage screen looks.
enum UsagePeriod: String, CaseIterable, Identifiable {
    case week, month, quarter, year, all
    var id: Self { self }

    var title: String {
        switch self {
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .quarter: "Last 90 days"
        case .year: "Last 365 days"
        case .all: "All time"
        }
    }

    /// Start of the first day shown; nil = from the oldest record.
    func start(now: Date = .now, calendar: Calendar = .current) -> Date? {
        let days = switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .year: 365
        case .all: 0
        }
        guard days > 0 else { return nil }
        return calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: now))
    }
}

/// Usage screen: tokens and recorded cost per day and subscription, from the session
/// files of every installed harness. Only recorded numbers are shown; nothing is estimated.
struct UsageView: View {
    @Environment(AppModel.self) private var model
    @State private var period = DebugSnapshot.options?.query.flatMap(UsagePeriod.init(rawValue:)) ?? .month
    @State private var report: DailyUsageReport?
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        content
            .navigationTitle("Usage")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem {
                    Picker("Period", selection: $period) {
                        ForEach(UsagePeriod.allCases) { Text($0.title).tag($0) }
                    }
                    .help("Days to show")
                }
                ToolbarItem {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                        .disabled(model.isScanning || isLoading)
                        .help("Read the session files again (⌘R)")
                }
            }
            // Reload when the period changes and after every scan (new sessions, harnesses).
            .task(id: "\(period.rawValue)|\(model.lastScan?.timeIntervalSince1970 ?? 0)") { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            ContentUnavailableView("Couldn't read usage", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if let report, !report.isEmpty {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 12) {
                        UsageTable(report: report)
                        Text(note(report))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 640, alignment: .leading)
                    }
                    .padding(20)
                    // A table narrower than the window stays at the top left, not in the middle.
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
            }
        } else if report == nil || isLoading {
            ProgressView("Reading sessions…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No usage in this period", systemImage: "chart.bar.xaxis",
                                   description: Text("The installed harnesses recorded no model responses here."))
        }
    }

    private var subtitle: String {
        guard let report, !report.isEmpty else { return "" }
        var parts = ["\(UsageText.short(report.grandTotal.tokens.total)) tokens",
                     "\(UsageText.full(report.grandTotal.requests)) responses"]
        if let cost = report.grandTotal.cost { parts.append("\(UsageText.dollars(cost)) recorded") }
        return parts.joined(separator: " · ")
    }

    private func note(_ report: DailyUsageReport) -> String {
        var text = "Numbers come straight from the harnesses' session files. Tokens include cache reads and writes. "
            + "Cost is shown only where the harness recorded it (Pi and OpenCode do, Claude Code and Codex don't)."
        if report.grandTotal.unpricedRequests > 0 && report.grandTotal.cost != nil {
            text += " \"≥\" marks a cost that leaves out responses without a recorded cost."
        }
        return text + " Hover a cell for the harnesses and models behind it."
    }

    private func load() async {
        // The first scan finds the installed harnesses; wait for it.
        guard model.lastScan != nil else { return }
        isLoading = true
        defer { isLoading = false }
        let start = period.start()
        do {
            let records = try await model.usage(since: start ?? .distantPast)
            let from = start ?? records.map(\.time).min() ?? .now
            report = DailyUsageReport(records: records, from: from, to: .now)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Days down, subscriptions across, totals in the first row and the last column.
private struct UsageTable: View {
    let report: DailyUsageReport

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 20, verticalSpacing: 6) {
            GridRow {
                Text("Day").gridColumnAlignment(.leading)
                ForEach(report.subscriptions) { Text($0.name) }
                Text("Total")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            GridRow {
                Text("Total").gridColumnAlignment(.leading)
                ForEach(report.subscriptions) { cell(report.total(of: $0), title: "\($0.name), whole period") }
                cell(report.grandTotal, title: "Whole period")
            }
            .fontWeight(.semibold)
            Divider()
            ForEach(report.days, id: \.self) { day in
                GridRow {
                    Text(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    ForEach(report.subscriptions) { subscription in
                        cell(report.cell(day, subscription), title: "\(subscription.name), \(day.formatted(date: .abbreviated, time: .omitted))")
                    }
                    cell(report.total(ofDay: day), title: day.formatted(date: .abbreviated, time: .omitted))
                        .fontWeight(.medium)
                }
            }
        }
        .monospacedDigit()
        .textSelection(.enabled)
    }

    /// Tokens, and the recorded cost under them.
    @ViewBuilder
    private func cell(_ total: UsageTotal?, title: String) -> some View {
        if let total, total.requests > 0 {
            VStack(alignment: .trailing, spacing: 1) {
                Text(UsageText.short(total.tokens.total))
                if let cost = total.cost {
                    Text((total.unpricedRequests > 0 ? "≥ " : "") + UsageText.dollars(cost))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .help(Self.details(total, title: title))
        } else {
            Text("–").foregroundStyle(.tertiary)
        }
    }

    /// "Claude · claude-opus-5: 120M tokens (1.2M output), 340 responses"
    static func details(_ total: UsageTotal, title: String) -> String {
        let lines = total.parts.map { part in
            var line = "\(part.harness.displayName) · \(part.model): \(UsageText.short(part.tokens.total)) tokens "
                + "(\(UsageText.short(part.tokens.output)) output), \(UsageText.full(part.requests)) responses"
            if let cost = part.cost { line += ", \(UsageText.dollars(cost))" }
            return line
        }
        let tokens = total.tokens
        let summary = "Input \(UsageText.short(tokens.input)) · output \(UsageText.short(tokens.output)) · "
            + "cache read \(UsageText.short(tokens.cacheRead)) · cache write \(UsageText.short(tokens.cacheWrite))"
        return ([title, summary] + lines).joined(separator: "\n")
    }
}
