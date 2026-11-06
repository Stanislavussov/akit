import AppKit
import Charts
import MeetingsCore
import SwiftUI

/// Costs… (M21): what OpenRouter charged per day, week or month in a range, for every model or
/// one; a chart, a table, totals and Copy CSV.
struct CostsView: View {
    let model: MeetingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var grouping: CostReport.Grouping = .day
    @State private var range: Range = .thisMonth
    @State private var from = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var aiModel = ""

    enum Range: String, CaseIterable, Identifiable {
        case thisWeek, thisMonth, last30, last90, thisYear, all, custom
        var id: Self { self }
        var title: String {
            switch self {
            case .thisWeek: "This week"
            case .thisMonth: "This month"
            case .last30: "Last 30 days"
            case .last90: "Last 3 months"
            case .thisYear: "This year"
            case .all: "All time"
            case .custom: "Custom"
            }
        }
    }

    /// The range's first and last day.
    private var dates: (from: Date, to: Date) {
        let calendar = Calendar.current
        let now = Date()
        func start(_ component: Calendar.Component) -> Date { calendar.dateInterval(of: component, for: now)?.start ?? now }
        switch range {
        case .thisWeek: return (start(.weekOfYear), now)
        case .thisMonth: return (start(.month), now)
        case .last30: return (calendar.date(byAdding: .day, value: -29, to: now) ?? now, now)
        case .last90: return (calendar.date(byAdding: .day, value: -89, to: now) ?? now, now)
        case .thisYear: return (start(.year), now)
        case .all: return (model.meetings.map(\.started).min() ?? now, now)
        case .custom: return (from, to)
        }
    }

    var body: some View {
        let (start, end) = dates
        let filter = aiModel.isEmpty ? nil : aiModel
        let rows = CostReport.rows(model.meetings, asks: model.askEntries, grouping: grouping, from: start, to: end, model: filter)
        let totals = CostReport.totals(model.meetings, asks: model.askEntries, from: start, to: end, model: filter)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Costs").font(.title3.bold())
                Spacer()
                Text("What OpenRouter charged for each meeting's calls and for Ask.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Picker("Group by", selection: $grouping) {
                    ForEach(CostReport.Grouping.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Picker("Period", selection: $range) {
                    ForEach(Range.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Picker("Model", selection: $aiModel) {
                    Text("All models").tag("")
                    ForEach(CostReport.models(model.meetings, asks: model.askEntries), id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
            }
            if range == .custom {
                HStack {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, displayedComponents: .date)
                }
                .fixedSize()
            }
            HStack(spacing: 24) {
                total("Cost", String(format: "$%.3f", totals.cost))
                total("Meetings", "\(totals.meetings)")
                total("Questions", "\(totals.questions)")
                total("Recorded", lengthText(totals.seconds))
                total("Per hour", totals.costPerHour.map { String(format: "$%.3f", $0) } ?? "—")
                total("Per day", String(format: "$%.3f", totals.costPerDay))
                total("Month limit", String(format: "$%.2f of $%.0f", model.monthCost, model.settings.monthlyLimitUSD))
            }
            Chart(rows) { row in
                BarMark(x: .value("Period", row.start, unit: grouping == .day ? .day : grouping == .week ? .weekOfYear : .month),
                        y: .value("USD", row.cost))
                    .foregroundStyle(Color.accentColor.gradient)
            }
            .chartYAxis { AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text(String(format: "$%.2f", v)) } }
            } }
            .frame(height: 160)
            Table(rows.reversed()) {
                TableColumn("Period") { Text(CostReport.label($0, grouping: grouping)) }
                TableColumn("Meetings") { Text("\($0.meetings)").monospacedDigit() }.width(70)
                TableColumn("Questions") { Text($0.questions > 0 ? "\($0.questions)" : "—").monospacedDigit() }.width(70)
                TableColumn("Recorded") { Text($0.seconds > 0 ? lengthText($0.seconds) : "—").monospacedDigit() }.width(90)
                TableColumn("Cost") { Text(String(format: "$%.4f", $0.cost)).monospacedDigit() }.width(90)
                TableColumn("Per hour") { Text($0.costPerHour.map { String(format: "$%.3f", $0) } ?? "—").monospacedDigit() }.width(80)
            }
            HStack {
                Button("Copy CSV") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(CostReport.csv(rows), forType: .string)
                }
                .help("The table as CSV (period, meetings, hours, usd, usd_per_hour, questions) for a spreadsheet")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 640)
    }

    private func total(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
    }
}
