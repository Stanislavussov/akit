import AKitInsights
import SwiftUI

/// Insights → Stuck Loops: Pi sessions where the user asked the same thing 3+ times and got almost
/// the same answer, by model and thinking level, with the advice (`akit stats loops`,
/// `docs/design/repeat-loops.md`). Show opens a loop in Sessions at its first ask.
struct InsightsLoopsBox: View {
    @Environment(AppModel.self) private var model
    let report: LoopsReport
    @State private var showAll = false

    private static let shortList = 5

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pi sessions where you asked the same thing 3 or more times in a row and got almost the same answer: a sign to raise thinking or switch the model. Found by code, no model call. In Pi, AKit's extension says so after the run (⌥T raises thinking).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(report.sessionsWithLoops) of \(report.sessionsScanned) Pi sessions in the last \(report.days) days had a stuck loop.")
                if !report.groups.isEmpty {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Model").bold()
                            Text("Thinking").bold()
                            Text("Loops").bold()
                            Text("Most asks").bold()
                            Text("What to do").bold()
                        }
                        ForEach(report.groups) { group in
                            GridRow {
                                Text(group.model ?? "not recorded").monospaced()
                                Text(group.thinking ?? "not recorded")
                                Text("\(group.loops) in \(group.sessions) session\(group.sessions == 1 ? "" : "s")").monospacedDigit()
                                Text("\(group.maxAsks)").monospacedDigit()
                                Text(group.advice).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .font(.callout)
                    Divider()
                    ForEach(showAll ? report.loops : Array(report.loops.prefix(Self.shortList))) { loop in
                        row(loop)
                    }
                    if report.loops.count > Self.shortList {
                        Button(showAll ? "Show Fewer" : "Show All \(report.loops.count) Loops") { showAll.toggle() }
                            .buttonStyle(.link)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text("Stuck Loops").font(.headline)
        }
    }

    private func row(_ loop: LoopsReport.Loop) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(loop.started.map { String($0.prefix(10)) } ?? "—").monospacedDigit().foregroundStyle(.secondary)
            Text("Asked \(loop.asks)×").monospacedDigit()
            if let folder = loop.cwd { Text((folder as NSString).lastPathComponent).foregroundStyle(.secondary) }
            Text([loop.model, loop.thinking.map { "thinking \($0)" }].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if let file = loop.file, model.sessions.contains(where: { $0.file.path == file }) {
                Button("Show") {
                    model.revealSession = SessionReveal(path: file, step: loop.firstStep)
                    model.section = .sessions
                }
                .controlSize(.small)
                .help("Open this session in Sessions at the loop's first ask")
            }
        }
        .font(.callout)
    }
}
