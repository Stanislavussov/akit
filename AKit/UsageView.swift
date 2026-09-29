import AKitModel
import AKitUsage
import AppKit
import Charts
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
    /// nil = all harnesses.
    @State private var harness: HarnessID? = DebugSnapshot.options?.harness.map { HarnessID($0, displayName: $0) }
    @State private var showEmptyDays = false
    /// Everything read for the period; the harness filter is applied on top.
    @State private var records: [UsageRecord]?
    @State private var range: ClosedRange<Date>?
    /// The report for the chosen harness, rebuilt from `records` when the filter changes.
    @State private var report: DailyUsageReport?
    /// Subscription limits the harnesses saw (Codex), filtered like `report`.
    @State private var limitSamples: [LimitSample] = []
    @State private var limitReport: SubscriptionLimitReport?
    @State private var error: String?
    @State private var isLoading = false
    @State private var updated: Date?
    /// Bumped by the Refresh button to read the session files again.
    @State private var reloads = 0

    var body: some View {
        content
            .navigationTitle("Usage")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem {
                    Picker("Harness", selection: $harness) {
                        Text("All harnesses").tag(HarnessID?.none)
                        ForEach(harnesses, id: \.self) { Text($0.displayName).tag(HarnessID?.some($0)) }
                    }
                    .help("Show the usage of one harness")
                }
                ToolbarItem {
                    Picker("Period", selection: $period) {
                        ForEach(UsagePeriod.allCases) { Text($0.title).tag($0) }
                    }
                    .help("Days to show")
                }
                ToolbarItem {
                    Button("Refresh", systemImage: "arrow.clockwise") { reloads += 1 }
                        .disabled(model.isScanning || isLoading)
                        .help("Read the session files again")
                }
            }
            // Read when the period changes, on Refresh and after a scan (new harnesses).
            .task(id: "\(period.rawValue)|\(reloads)|\(model.lastScan?.timeIntervalSince1970 ?? 0)") { await load() }
            .onChange(of: harness) { rebuildReport() }
    }

    /// Built from memory, so switching harnesses is instant.
    private func rebuildReport() {
        guard let records, let range else { return report = nil }
        let shown = harness.map { id in records.filter { $0.harness == id } } ?? records
        report = DailyUsageReport(records: shown, from: range.lowerBound, to: range.upperBound)
        let samples = harness.map { id in limitSamples.filter { $0.harness == id } } ?? limitSamples
        limitReport = samples.isEmpty ? nil : SubscriptionLimitReport(samples: samples, from: range.lowerBound, to: range.upperBound)
    }

    /// Harnesses that recorded something in the period.
    private var harnesses: [HarnessID] {
        var seen = Set<HarnessID>()
        let found = (records ?? []).map(\.harness).filter { seen.insert($0).inserted }
        // Keep the chosen one in the menu even when it has nothing in this period.
        return (found + [harness].compactMap(\.self)).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }.sorted()
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            ContentUnavailableView("Couldn't read usage", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if let report, !report.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    UsageSummary(report: report)
                    if let limitReport, !limitReport.isEmpty {
                        UsageCard(title: "Subscription limits") { LimitsPanel(report: report, limits: limitReport) }
                    }
                    UsageCard(title: "Tokens per day") { UsageChart(report: report, limits: limitReport) }
                    UsageCard(title: "By day", accessory: {
                        Toggle("Show days without usage", isOn: $showEmptyDays)
                            .toggleStyle(.checkbox)
                            .font(.callout)
                    }) {
                        UsageTable(report: report, limits: limitReport, showEmptyDays: showEmptyDays)
                    }
                    Text(note(report))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 720, alignment: .leading)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if records == nil || isLoading {
            ProgressView("Reading sessions…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(harness == nil ? "No usage in this period" : "No \(harness!.displayName) usage in this period",
                                   systemImage: "chart.bar.xaxis",
                                   description: Text("No model responses were recorded here. Try a longer period."))
        }
    }

    private var subtitle: String {
        guard let report, !report.isEmpty else { return "" }
        let parts = ["\(report.days.count) days", report.subscriptions.count == 1 ? "1 subscription" : "\(report.subscriptions.count) subscriptions",
                     updated.map { "updated \($0.formatted(date: .omitted, time: .shortened))" }]
        return parts.compactMap(\.self).joined(separator: " · ")
    }

    private func note(_ report: DailyUsageReport) -> String {
        var text = "Numbers come straight from the harnesses' session files. Tokens include cache reads and writes. "
            + "Cost comes from the harnesses too: Pi and OpenCode record it for each response, Claude Code once per "
            + "run when it exits normally (the /cost total), spread over that run's days by tokens. Codex records none."
        if report.grandTotal.estimatedCost > 0 {
            text += " \"≈\": Claude Code runs that exited without saving a cost (closed terminal, still running) are "
                + "estimated with the cost per transcript token learned from the runs that did save one. No price lists are used."
        }
        if report.grandTotal.unpricedRequests > 0 && report.grandTotal.cost != nil {
            text += " \"≥\" marks a cost that leaves out responses without one."
        }
        return text + " Hover a bar or a cell for the harnesses and models behind it."
    }

    private func load() async {
        // The first scan finds the installed harnesses; wait for it.
        guard model.lastScan != nil else { return }
        isLoading = true
        defer { isLoading = false }
        let start = period.start()
        do {
            async let usage = model.usage(since: start ?? .distantPast)
            async let limits = model.limits(since: start ?? .distantPast)
            let loaded = try await usage
            let now = Date.now
            range = (start ?? loaded.map(\.time).min() ?? now)...now
            limitSamples = try await limits
            records = loaded
            rebuildReport()
            updated = now
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Cost text

extension UsageText {
    /// "$12.30", "≈ $12.30" when part of it is estimated, "≥ …" when some responses have no cost.
    static func cost(of total: UsageTotal) -> String? {
        guard let cost = total.cost else { return nil }
        return (total.unpricedRequests > 0 ? "≥ " : "") + (total.estimatedCost > 0 ? "≈ " : "") + dollars(cost)
    }

    /// "5-hour 80% · weekly 9%", short: "5h 80% · week 9%". nil when there are none.
    static func limits(_ peaks: [SubscriptionLimitReport.Peak], short: Bool = false) -> String? {
        guard !peaks.isEmpty else { return nil }
        return peaks.map { peak in
            let name = short ? (peak.windowMinutes == 10_080 ? "week" : peak.windowMinutes % 60 == 0 ? "\(peak.windowMinutes / 60)h" : peak.windowName)
                : peak.windowName
            return "\(name) \(percent(peak.usedPercent))"
        }.joined(separator: " · ")
    }

    static func percent(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) + "%" }

    /// "$378.26 recorded · $1,092.41 estimated"
    static func costSplit(of total: UsageTotal) -> String? {
        guard let cost = total.cost else { return nil }
        let recorded = cost - total.estimatedCost
        guard total.estimatedCost > 0 else { return "\(dollars(recorded)) recorded" }
        return recorded > 0.005 ? "\(dollars(recorded)) recorded · \(dollars(total.estimatedCost)) estimated"
            : "\(dollars(total.estimatedCost)) estimated"
    }
}

// MARK: - Colors

/// A fixed color per subscription, so filtering never repaints the rest.
/// The eight hues and their order come from a palette checked for color-blind readers.
enum SubscriptionColor {
    private static let slots: [(light: UInt32, dark: UInt32)] = [
        (0x2A78D6, 0x3987E5), // blue
        (0xEB6834, 0xD95926), // orange
        (0x1BAF7A, 0x199E70), // aqua
        (0xEDA100, 0xC98500), // yellow
        (0xE87BA4, 0xD55181), // magenta
        (0x008300, 0x008300), // green
        (0x4A3AA7, 0x9085E9), // violet
        (0xE34948, 0xE66767), // red
    ]

    /// Known subscriptions keep their slot; others get a stable one from their id.
    private static let known = ["anthropic", "openai", "opencode-go", "minimax", "google-antigravity",
                                "github-copilot", "google", "opencode"]

    static func color(for subscription: Subscription) -> Color {
        let index = known.firstIndex(of: subscription.id)
            ?? subscription.id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % slots.count
        let slot = slots[index % slots.count]
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: dark ? slot.dark : slot.light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Pieces

/// Rounded panel with a title, like the grouped sections of System Settings.
private struct UsageCard<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                accessory
            }
            content
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
    }
}

/// Headline numbers of the period.
private struct UsageSummary: View {
    let report: DailyUsageReport

    var body: some View {
        let total = report.grandTotal
        let active = report.days.filter { report.total(ofDay: $0) != nil }
        let busiest = active.max { (report.total(ofDay: $0)?.tokens.total ?? 0) < (report.total(ofDay: $1)?.tokens.total ?? 0) }
        HStack(alignment: .top, spacing: 12) {
            tile("Tokens", UsageText.short(total.tokens.total),
                 "\(UsageText.short(total.tokens.output)) output · \(UsageText.full(total.requests)) responses")
            tile("Cost", UsageText.cost(of: total) ?? "–",
                 total.cost == nil ? "These harnesses don't record cost" : costDetail(total))
            tile("Active days", "\(active.count)", "of \(report.days.count) days in the period")
            if let busiest, let busiestTotal = report.total(ofDay: busiest) {
                tile("Busiest day", UsageText.short(busiestTotal.tokens.total),
                     busiest.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            }
        }
    }

    /// "5-hour 80% · weekly 9%", short: "5h 80% · week 9%". nil when there are none.
    static func limits(_ peaks: [SubscriptionLimitReport.Peak], short: Bool = false) -> String? {
        guard !peaks.isEmpty else { return nil }
        return peaks.map { peak in
            let name = short ? (peak.windowMinutes == 10_080 ? "week" : peak.windowMinutes % 60 == 0 ? "\(peak.windowMinutes / 60)h" : peak.windowName)
                : peak.windowName
            return "\(name) \(percent(peak.usedPercent))"
        }.joined(separator: " · ")
    }

    static func percent(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) + "%" }

    /// "$378.26 recorded · $1,092.41 estimated", or how many responses have a cost at all.
    private func costDetail(_ total: UsageTotal) -> String {
        guard total.unpricedRequests > 0, total.estimatedCost == 0 else { return UsageText.costSplit(of: total) ?? "" }
        let priced = total.requests - total.unpricedRequests
        return "\(UsageText.full(priced)) of \(UsageText.full(total.requests)) responses have a cost"
    }

    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
    }
}

/// The last limit state each subscription reported: plan, share used per window, reset time.
/// Harnesses report it only after a response, so it is as fresh as the last use.
private struct LimitsPanel: View {
    let report: DailyUsageReport
    let limits: SubscriptionLimitReport

    private var subscriptions: [Subscription] {
        let ids = limits.subscriptionIDs
        return report.subscriptions.filter { ids.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(subscriptions) { subscription in
                let samples = limits.latest(of: subscription)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(SubscriptionColor.color(for: subscription)).frame(width: 8, height: 8)
                        Text(subscription.name).fontWeight(.semibold)
                        if let plan = samples.first?.planName { Text(plan).foregroundStyle(.secondary) }
                        Spacer()
                        if let seen = samples.map(\.time).max() {
                            Text("as of \(seen.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(samples, id: \.windowMinutes) { sample in
                        HStack(spacing: 10) {
                            Text(sample.windowName.prefix(1).uppercased() + sample.windowName.dropFirst())
                                .frame(width: 70, alignment: .leading)
                            ProgressView(value: min(max(sample.usedPercent, 0), 100), total: 100)
                                .tint(sample.usedPercent >= 90 ? .red : SubscriptionColor.color(for: subscription))
                                .frame(maxWidth: 320)
                            Text("\(UsageText.percent(sample.usedPercent)) used")
                                .monospacedDigit()
                                .frame(width: 80, alignment: .trailing)
                            Text(resetText(sample))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("The table shows each day's peak use of these limits for subscriptions without a cost.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resetText(_ sample: LimitSample) -> String {
        guard let resets = sample.resetsAt else { return "" }
        return resets > .now ? "resets \(resets.formatted(date: .abbreviated, time: .shortened))"
            : "has reset since (\(resets.formatted(date: .abbreviated, time: .shortened)))"
    }
}

/// Stacked bars: tokens per day, one color per subscription. Hovering a day shows its numbers.
private struct UsageChart: View {
    let report: DailyUsageReport
    let limits: SubscriptionLimitReport?
    @State private var hovered: Date?

    private struct Bar: Identifiable {
        let id: String
        let day: Date
        let subscription: Subscription
        let tokens: Int
    }

    private var bars: [Bar] {
        report.days.flatMap { day in
            report.subscriptions.compactMap { subscription in
                report.cell(day, subscription).map {
                    Bar(id: "\(day.timeIntervalSince1970)|\(subscription.id)", day: day, subscription: subscription,
                        tokens: $0.tokens.total)
                }
            }
        }
    }

    var body: some View {
        let hoveredDay = hovered.map { Calendar.current.startOfDay(for: $0) }
        Chart {
            ForEach(bars) { bar in
                BarMark(x: .value("Day", bar.day, unit: .day), y: .value("Tokens", bar.tokens))
                    .foregroundStyle(by: .value("Subscription", bar.subscription.name))
                    .opacity(hoveredDay == nil || hoveredDay == bar.day ? 1 : 0.35)
            }
            if let hoveredDay, let total = report.total(ofDay: hoveredDay) {
                RuleMark(x: .value("Day", hoveredDay, unit: .day))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                        DayPopover(report: report, limits: limits, day: hoveredDay, total: total)
                    }
            }
        }
        .chartForegroundStyleScale(domain: report.subscriptions.map(\.name),
                                   range: report.subscriptions.map(SubscriptionColor.color(for:)))
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.separator.opacity(0.6))
                AxisValueLabel { Text(UsageText.short(value.as(Int.self) ?? 0)) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartLegend(position: .top, alignment: .leading, spacing: 12)
        .chartXSelection(value: $hovered)
        .frame(height: 240)
    }
}

/// Numbers of one day, shown over the chart.
private struct DayPopover: View {
    let report: DailyUsageReport
    let limits: SubscriptionLimitReport?
    let day: Date
    let total: UsageTotal

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.caption.weight(.semibold))
            ForEach(report.subscriptions) { subscription in
                if let cell = report.cell(day, subscription) {
                    HStack(spacing: 6) {
                        Circle().fill(SubscriptionColor.color(for: subscription)).frame(width: 7, height: 7)
                        Text(subscription.name)
                        Spacer(minLength: 12)
                        Text(UsageText.short(cell.tokens.total)).monospacedDigit()
                        if let cost = UsageText.cost(of: cell) { Text(cost).monospacedDigit().foregroundStyle(.secondary) }
                    }
                    if let text = UsageText.limits(limits?.peaks(day, subscription) ?? []) {
                        Text("Limits used: \(text)").foregroundStyle(.secondary).padding(.leading, 13)
                    }
                }
            }
            Divider()
            HStack {
                Text("Total")
                Spacer(minLength: 12)
                Text(UsageText.short(total.tokens.total)).monospacedDigit()
                if let cost = UsageText.cost(of: total) { Text(cost).monospacedDigit().foregroundStyle(.secondary) }
            }
            .fontWeight(.semibold)
        }
        .font(.caption)
        .padding(10)
        .frame(minWidth: 200)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}

/// Days down, subscriptions across, the period total in the first row.
/// Each cell has a small bar: its share of the column's busiest day.
private struct UsageTable: View {
    let report: DailyUsageReport
    let limits: SubscriptionLimitReport?
    let showEmptyDays: Bool

    private let dayWidth: CGFloat = 150
    private let columnWidth: CGFloat = 116

    /// Largest day of each subscription, for the cell bars.
    private var peaks: [String: Int] {
        var result: [String: Int] = [:]
        for day in report.days {
            for subscription in report.subscriptions {
                if let tokens = report.cell(day, subscription)?.tokens.total {
                    result[subscription.id] = max(result[subscription.id] ?? 0, tokens)
                }
            }
        }
        return result
    }

    private var days: [Date] {
        showEmptyDays ? report.days : report.days.filter { report.total(ofDay: $0) != nil }
    }

    /// Year only when the period isn't all in the current year.
    private var showsYear: Bool {
        let calendar = Calendar.current
        return report.days.contains { !calendar.isDate($0, equalTo: .now, toGranularity: .year) }
    }

    var body: some View {
        let peaks = peaks
        ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                row(title: "Total", cells: report.subscriptions.map { report.total(of: $0) }, total: report.grandTotal,
                    tooltip: "Whole period", peaks: [:], bold: true)
                Divider()
                ForEach(Array(days.enumerated()), id: \.element) { index, day in
                    row(title: day.formatted(showsYear ? .dateTime.weekday(.abbreviated).day().month(.abbreviated).year()
                                                       : .dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                        day: day, cells: report.subscriptions.map { report.cell(day, $0) }, total: report.total(ofDay: day),
                        tooltip: day.formatted(date: .complete, time: .omitted), peaks: peaks)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
                }
            }
            .textSelection(.enabled)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Day").frame(width: dayWidth, alignment: .leading)
            ForEach(report.subscriptions) { subscription in
                HStack(spacing: 5) {
                    Circle().fill(SubscriptionColor.color(for: subscription)).frame(width: 8, height: 8)
                    Text(subscription.name).lineLimit(1)
                }
                .frame(width: columnWidth, alignment: .trailing)
            }
            Text("Total").frame(width: columnWidth, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func row(title: String, day: Date? = nil, cells: [UsageTotal?], total: UsageTotal?, tooltip: String,
                     peaks: [String: Int], bold: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(title).frame(width: dayWidth, alignment: .leading)
            ForEach(Array(zip(report.subscriptions, cells)), id: \.0.id) { subscription, cell in
                cellView(cell, color: SubscriptionColor.color(for: subscription), peak: peaks[subscription.id],
                         limits: day.flatMap { UsageText.limits(limits?.peaks($0, subscription) ?? [], short: true) },
                         tooltip: "\(subscription.name) · \(tooltip)")
                    .frame(width: columnWidth, alignment: .trailing)
            }
            cellView(total, color: nil, peak: nil, limits: nil, tooltip: tooltip)
                .fontWeight(.semibold)
                .frame(width: columnWidth, alignment: .trailing)
        }
        .fontWeight(bold ? .semibold : .regular)
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func cellView(_ total: UsageTotal?, color: Color?, peak: Int?, limits: String?, tooltip: String) -> some View {
        if let total, total.requests > 0 {
            VStack(alignment: .trailing, spacing: 2) {
                Text(UsageText.short(total.tokens.total))
                // A subscription without a cost shows how much of its limits that day used.
                if let text = UsageText.cost(of: total) ?? limits {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let color, let peak, peak > 0 {
                    Capsule().fill(color)
                        .frame(width: max(3, 56 * CGFloat(total.tokens.total) / CGFloat(peak)), height: 3)
                }
            }
            .help(Self.details(total, title: tooltip) + (limits.map { "\nLimits used (peak): \($0)" } ?? ""))
        } else {
            Text("–").foregroundStyle(.quaternary)
        }
    }

    /// "Claude · claude-opus-5: 120M tokens (1.2M output), 340 responses"
    static func details(_ total: UsageTotal, title: String) -> String {
        let lines = total.parts.map { part in
            var line = "\(part.harness.displayName) · \(part.model): \(UsageText.short(part.tokens.total)) tokens "
                + "(\(UsageText.short(part.tokens.output)) output), \(UsageText.full(part.requests)) responses"
            if let cost = part.cost { line += ", " + (part.estimatedCost > 0 ? "≈ " : "") + UsageText.dollars(cost) }
            return line
        }
        let tokens = total.tokens
        let summary = "Input \(UsageText.short(tokens.input)) · output \(UsageText.short(tokens.output)) · "
            + "cache read \(UsageText.short(tokens.cacheRead)) · cache write \(UsageText.short(tokens.cacheWrite))"
        return ([title, summary, UsageText.costSplit(of: total).map { "Cost: \($0)" }].compactMap(\.self) + lines)
            .joined(separator: "\n")
    }
}
