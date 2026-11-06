import AKitKnowledge
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Work Log → Report (docs/design/worklog.md, W13): per day of a week or a month the norm, the
/// work, what is missing and the breaks, then hours per kind and per ticket. Copy puts the table
/// on the clipboard (tabs, for a spreadsheet); Export CSV… saves it.
struct WorkLogReportView: View {
    @Environment(WorkLogModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let report = model.report
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ControlGroup {
                    Button("Back", systemImage: "chevron.left") { model.moveReport(-1) }
                        .help(model.reportPeriod == .week ? "The week before" : "The month before")
                    Button("Today") { model.reportAnchor = .now }
                        .help("The week or month of today")
                    Button("On", systemImage: "chevron.right") { model.moveReport(1) }
                        .help(model.reportPeriod == .week ? "The week after" : "The month after")
                }
                .fixedSize()
                Text(title).font(.headline).lineLimit(1).layoutPriority(1)
                Spacer()
                Picker("Period", selection: $model.reportPeriod) {
                    ForEach(KnowledgeWorkLog.Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                WorkLogHoursField()
                Button("Copy", systemImage: "doc.on.doc") { copy(report) }
                    .disabled(report == nil)
                    .help("Copy the table with tabs between the columns: it pastes into a spreadsheet")
                Button("Export CSV…", systemImage: "square.and.arrow.up") { export(report) }
                    .disabled(report == nil)
                    .help("Save the table as a CSV file: one row per day and a total, hours with two decimals")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        WorkLogReportSummary(report: report)
                        WorkLogReportTable(report: report)
                        WorkLogReportParts(report: report)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("No report", systemImage: "tablecells", description: Text("The work log couldn't be read."))
            }
        }
    }

    private var title: String {
        let range = model.reportRange
        guard let from = KnowledgeWorkLog.date(range.from), let to = KnowledgeWorkLog.date(range.to) else { return "" }
        if model.reportPeriod == .month { return from.formatted(.dateTime.month(.wide).year()) }
        let week = Calendar(identifier: .iso8601).component(.weekOfYear, from: from)
        return "Week \(week) · \(from.formatted(.dateTime.day().month(.abbreviated))) – \(to.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    private func copy(_ report: KnowledgeWorkLog.Report?) {
        guard let report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.daysCSV.replacingOccurrences(of: ",", with: "\t"), forType: .string)
        model.notice = "Copied the report of \(report.from) – \(report.to)."
    }

    private func export(_ report: KnowledgeWorkLog.Report?) {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "worklog-\(report.from)-\(report.to).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(report.daysCSV.utf8).write(to: url, options: .atomic)
            model.notice = "Saved \(url.lastPathComponent)."
        } catch {
            model.problem = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

/// Work, norm and missing for the whole period, large.
private struct WorkLogReportSummary: View {
    let report: KnowledgeWorkLog.Report

    var body: some View {
        HStack(spacing: 28) {
            figure("Work", report.work, .primary)
            figure("Norm", report.norm, .secondary)
            figure("Missing", report.missing, report.missing > 0 ? .orange : .green)
            figure("Over", max(0, report.work - report.norm), .secondary)
            Spacer()
            if report.rows.contains(where: \.open) {
                Label("Days marked ◦ end with an entry without an end: its time isn't counted. Add a later entry or a block.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 320, alignment: .trailing)
            }
        }
    }

    private func figure(_ title: String, _ minutes: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(KnowledgeWorkLog.Report.h(minutes)) h").font(.title2.monospacedDigit()).foregroundStyle(color)
        }
    }
}

/// One row per day; a click on a day opens it in the calendar.
private struct WorkLogReportTable: View {
    @Environment(WorkLogModel.self) private var model
    let report: KnowledgeWorkLog.Report

    var body: some View {
        let kinds = Array(report.kinds.map(\.kind).filter { KnowledgeWorkLog.kind($0.isEmpty ? "other" : $0).isWork }.prefix(6))
        Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text("Day").gridColumnAlignment(.leading)
                Text("Norm")
                Text("Work")
                Text("Missing")
                Text("Break")
                ForEach(kinds, id: \.self) { Text(KnowledgeWorkLog.kind($0.isEmpty ? "other" : $0).title) }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(report.rows, id: \.date) { row in
                GridRow {
                    Button {
                        if let date = KnowledgeWorkLog.date(row.date) { model.calendarAnchor = date }
                        model.calendarDay = row.date
                        model.tab = .calendar
                    } label: {
                        Text(name(row.date) + (row.open ? " ◦" : ""))
                    }
                    .buttonStyle(.link)
                    .help("Open this day in the calendar")
                    Text(cell(row.norm))
                    Text(cell(row.work))
                    Text(row.missing > 0 ? cell(row.missing) : "–").foregroundStyle(row.missing > 0 ? .orange : .secondary)
                    Text(cell(row.pause)).foregroundStyle(.secondary)
                    ForEach(kinds, id: \.self) { Text(cell(row.kinds[$0] ?? 0)).foregroundStyle(.secondary) }
                }
                .monospacedDigit()
                .opacity(row.norm == 0 && row.work == 0 ? 0.5 : 1)
            }
            Divider()
            GridRow {
                Text("Total").bold()
                Text(cell(report.norm))
                Text(cell(report.work)).bold()
                Text(cell(report.missing)).foregroundStyle(report.missing > 0 ? .orange : .secondary)
                Text(cell(report.rows.reduce(0) { $0 + $1.pause })).foregroundStyle(.secondary)
                ForEach(kinds, id: \.self) { kind in Text(cell(report.kinds.first { $0.kind == kind }?.minutes ?? 0)) }
            }
            .monospacedDigit()
        }
        .textSelection(.enabled)
    }

    private func cell(_ minutes: Int) -> String { minutes == 0 ? "–" : KnowledgeWorkLog.Report.h(minutes) }

    private func name(_ date: String) -> String {
        KnowledgeWorkLog.date(date)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? date
    }
}

/// Hours per ticket and per kind for the period.
private struct WorkLogReportParts: View {
    let report: KnowledgeWorkLog.Report

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            list("Tickets", report.tickets.map { ($0.ticket.isEmpty ? "No ticket" : $0.ticket, $0.minutes) },
                 note: "Work entries by the first ticket id in their text (COL-123)")
            list("Kinds", report.kinds.map { (KnowledgeWorkLog.kind($0.kind.isEmpty ? "other" : $0.kind).title, $0.minutes) },
                 note: "Breaks included")
        }
    }

    private func list(_ title: String, _ items: [(String, Int)], note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).lineLimit(1).layoutPriority(1)
            Text(note).font(.caption).foregroundStyle(.secondary)
            if items.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            ForEach(items, id: \.0) { name, minutes in
                HStack {
                    Text(name).textSelection(.enabled)
                    Spacer(minLength: 24)
                    Text("\(KnowledgeWorkLog.Report.h(minutes)) h").monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(width: 260)
            }
        }
    }
}
