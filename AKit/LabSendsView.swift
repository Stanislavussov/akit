import AKitFoundation
import AKitLab
import SwiftUI

/// Lab → Sends: every model call that sent session data or code out (`sends.jsonl`), newest
/// first, with the tokens and the cost the harness recorded.
struct LabSendsView: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [Row]?
    @State private var monthCost: Double = 0
    @State private var limit: Double?

    struct Row: Identifiable {
        let id: Int
        let record: SendRecord
    }

    var body: some View {
        VStack(spacing: 0) {
            if let rows, rows.isEmpty {
                ContentUnavailableView("No sends yet", systemImage: "paperplane",
                                       description: Text("Every model call that sends session data or code out is logged here: where it went, the tokens and the cost the harness recorded."))
            } else {
                table
            }
            Divider()
            footer
        }
        // Runs write the log; reload whenever a run changes.
        .task(id: model.labRuns) { await load() }
    }

    private var table: some View {
        Table(rows ?? []) {
            TableColumn("Date") { row in
                Text(row.record.date.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 110, ideal: 130)
            TableColumn("Purpose") { row in Text(row.record.purpose) }
                .width(min: 60, ideal: 70)
            TableColumn("Destination") { row in
                Text("\(row.record.harness.title) · \(row.record.provider) · \(row.record.account)")
                    .help("\(row.record.harness.title) · \(row.record.provider) · \(row.record.account) · \(row.record.org)")
            }
            .width(min: 160, ideal: 210)
            TableColumn("Model") { row in Text(row.record.model.isEmpty ? "default" : row.record.model) }
                .width(min: 60, ideal: 120)
            TableColumn("Tokens in / cached / out") { row in
                let usage = row.record.usage
                Text("\(UsageText.short(usage.input)) / \(UsageText.short(usage.cached)) / \(UsageText.short(usage.output))")
                    .monospacedDigit()
            }
            .width(min: 120, ideal: 150)
            TableColumn("Cost") { row in
                Text(row.record.usage.cost.map(UsageText.money) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(row.record.usage.cost == nil ? .secondary : .primary)
            }
            .width(min: 50, ideal: 70)
            TableColumn("Session") { row in
                Text(sessionText(row.record))
                    .truncationMode(.middle)
                    .help(row.record.session ?? "")
            }
            .width(min: 80, ideal: 160)
        }
    }

    private var footer: some View {
        HStack {
            Text("This month: \(UsageText.dollars(monthCost)) recorded")
            Text("·")
            Text(limit.map { "limit \(UsageText.dollars($0))" } ?? "no limit")
            Spacer()
            if let rows { Text(rows.count == 1 ? "1 send" : "\(rows.count) sends") }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help("The limit is set in Settings → Lab. Only costs the harnesses recorded count.")
    }

    /// A session key as is; a transcript path by its file name.
    private func sessionText(_ record: SendRecord) -> String {
        guard let session = record.session else { return "—" }
        return session.hasPrefix("/") ? URL(filePath: session).lastPathComponent : session
    }

    private func load() async {
        let env = HarnessEnvironment.current
        let (records, limit) = await Task.detached {
            (SendLog.records(env: env), LabSettings.load(env: env).monthlyLimit)
        }.value
        rows = records.reversed().enumerated().map { Row(id: $0.offset, record: $0.element) }
        monthCost = SendLog.monthCost(records)
        self.limit = limit
    }
}
