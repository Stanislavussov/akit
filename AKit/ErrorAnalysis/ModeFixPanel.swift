import AKitErrorAnalysis
import AKitFoundation
import SwiftUI

/// A failure or efficiency mode's fix (`akit analysis fix …`): the draft written before any
/// run, T when it was applied, the status, the mode's check before and after T, and a try on
/// control tasks. The user applies the fix; AKit never does.
struct ModeFixPanel: View {
    enum Sheet: String, Identifiable {
        case draft, applied, reject, control
        var id: String { rawValue }
    }

    @Environment(AnalysisModel.self) private var analysis
    let mode: Mode
    /// Snapshots: `--query fix --add` opens the draft sheet.
    @State private var sheet: Sheet? = DebugSnapshot.options?.query == "fix" && DebugSnapshot.options?.add == true ? .draft : nil
    /// Confirmed or Didn't Help, waiting for the user's go.
    @State private var verdict: Mode.FixStatus?

    var body: some View {
        let draft = analysis.data.fixes[mode.id]
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Fix").font(.title3.bold())
                Text(status).foregroundStyle(.secondary)
                Spacer()
            }
            if let reason = mode.fixReason, mode.fix == .rejected {
                Label("Rejected: \(reason)", systemImage: "xmark.circle").foregroundStyle(.red)
            }
            actions(draft)
            if let draft { DraftView(draft: draft) }
            if mode.fixAppliedAt != nil { FixEvaluationView(mode: mode) }
        }
        .confirmationDialog(verdict == .confirmed ? "Mark the fix as confirmed?" : "Mark the fix as didn't help?",
                            isPresented: Binding(get: { verdict != nil }, set: { if !$0 { verdict = nil } }), presenting: verdict) { status in
            Button(status == .confirmed ? "Confirmed" : "Didn't Help") { setFix(status) }
            Button("Cancel", role: .cancel) {}
        } message: { status in
            Text(status == .confirmed
                 ? "Your verdict that the fix of \(mode.name) worked, saved with the mode and in History. Look at Before and after T first."
                 : "Your verdict that the fix of \(mode.name) didn't help, saved with the mode and in History. Look at Before and after T first.")
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .draft: FixDraftSheet(mode: mode, draft: draft)
            case .applied: MarkAppliedSheet(mode: mode)
            case .reject: RejectFixSheet(mode: mode)
            case .control:
                RunCellsSheet(tasks: Set(analysis.data.controlTasks.filter { $0.modeID == mode.id }.map(\.id)), fixMode: mode.id)
            }
        }
    }

    private var status: String {
        switch mode.fix {
        case nil, .open?: "open: no draft yet"
        case .applied?: "applied" + (mode.fixAppliedAt.map { " at \($0.formatted(date: .abbreviated, time: .shortened)) (T)" } ?? "")
        case let fix?: fix.title + (mode.fixAppliedAt.map { " · applied \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
        }
    }

    private func actions(_ draft: FixDraft?) -> some View {
        HStack {
            Button(draft == nil ? "Draft Fix…" : "Edit Draft…", systemImage: "square.and.pencil") { sheet = .draft }
                .help("Write down the change, what should change in transcripts and the \"helped\" criterion, before any run")
            // T is set once; after that, Edit Draft's Start Over is the way back.
            if draft != nil, mode.fixAppliedAt == nil {
                Button("Mark Applied…", systemImage: "checkmark.circle") { sheet = .applied }
                    .help("You applied it: T, the anchor of before and after")
            }
            if mode.fix == .applied || mode.fix == .confirmed || mode.fix == .didntHelp || mode.fix == .rejected {
                Divider().frame(height: 16)
                status("Confirmed", .confirmed)
                status("Didn't Help", .didntHelp)
                Button("Rejected…") { sheet = .reject }.disabled(mode.fix == .rejected)
            }
            if draft?.patch != nil {
                Divider().frame(height: 16)
                Button("Try on Control Tasks…", systemImage: "checklist") { sheet = .control }
                    .disabled(analysis.data.controlTasks.isEmpty)
                    .help(analysis.data.controlTasks.isEmpty ? "Make control tasks on the Evals tab first"
                          : "Queue baseline and variant cells: the draft appended to its file in each clone")
            }
        }
        .controlSize(.small)
    }

    private func status(_ title: String, _ status: Mode.FixStatus) -> some View {
        Button(title) { verdict = status }
            .disabled(mode.fix == status)
    }

    private func setFix(_ status: Mode.FixStatus) {
        let id = mode.id, name = mode.name
        analysis.act { env in
            _ = try await ModeStore(env: env).setFix(id, status)
            return "\(name): fix \(status.title)."
        }
    }
}

/// The written draft: layer, text, expectations and exemplar notes.
private struct DraftView: View {
    @Environment(AnalysisModel.self) private var analysis
    let draft: FixDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(draft.layer.title)\(draft.skillName.map { " \($0)" } ?? "") · drafted \(draft.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(draft.text)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Text("Expected change: ").fontWeight(.medium) + Text(draft.expectedChange)
            Text("Helped when: ").fontWeight(.medium) + Text(draft.helpedCriterion)
            if !draft.exemplars.isEmpty {
                DisclosureGroup("\(draft.exemplars.count) exemplar notes") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(draft.exemplars, id: \.self) { PoolNoteView(ref: $0, data: analysis.data) }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The mode's check over indexed sessions before and after T (`akit analysis fix show`),
/// read off the main thread: failure rates with Wilson intervals, the probabilities, Fisher's
/// p, the verdict, the smallest detectable effect, flags, regressions and the matrix change.
private struct FixEvaluationView: View {
    struct Loaded: Sendable {
        var evaluation: FixEvaluation?
        var regressions: [String]
        var matrix: [(key: String, difference: TransitionMatrix.Difference)]
    }

    @Environment(AnalysisModel.self) private var analysis
    let mode: Mode
    @State private var loaded: Loaded?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Before and after T").font(.headline)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let loaded {
                if let evaluation = loaded.evaluation {
                    evaluationView(evaluation, loaded: loaded)
                } else {
                    Text("No check results for this mode yet: run its code check, or its judge over the pool.").foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .font(.callout)
        .task(id: "\(mode.id)|\(mode.version)|\(mode.fixAppliedAt?.timeIntervalSince1970 ?? 0)|\(analysis.data.trust[mode.id]?.level.rawValue ?? "")") {
            await load()
        }
    }

    @ViewBuilder private func evaluationView(_ evaluation: FixEvaluation, loaded: Loaded) -> some View {
        let scale = min(1, max(0.1, ((max(evaluation.before.interval.high, evaluation.after.interval.high)) * 10).rounded(.up) / 10))
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            side("Before T", evaluation.before, scale: scale)
            side("After T", evaluation.after, scale: scale)
        }
        HStack(spacing: 10) {
            VerdictBadge(verdict: evaluation.verdict)
            Text(String(format: "P(after < before) %.3f · P(after > before) %.3f · Fisher p %.3f",
                        evaluation.probabilityLower, evaluation.probabilityHigher, evaluation.fisherP))
                .monospacedDigit()
        }
        Text(verdictText(evaluation)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let mde = evaluation.minimumDetectable {
            Text("With these numbers only a drop to about \(AnalysisText.percent(mde)) or lower would show (80% power).")
                .foregroundStyle(.secondary)
        }
        ForEach(evaluation.flags, id: \.self) { flag in
            Label(flag, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        if !loaded.regressions.isEmpty {
            Label("Higher failure rate after T: " + loaded.regressions.map { analysis.data.mode($0)?.name ?? $0 }.joined(separator: ", "),
                  systemImage: "arrow.up.right.circle")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !loaded.matrix.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Transition matrix, reviewed sessions after T against before (beyond noise):").fontWeight(.medium)
                ForEach(loaded.matrix, id: \.key) { cell in
                    let parts = cell.key.split(separator: "|").map(String.init)
                    let column = parts.last == TransitionMatrix.noFailures ? "no failures" : parts.last ?? ""
                    let better = column == "no failures" ? cell.difference.change > 0 : cell.difference.change < 0
                    Text(String(format: "%@ → %@: %+.0f%% (%d → %d)", parts.first ?? "", column, cell.difference.change * 100,
                                cell.difference.before, cell.difference.after))
                        .foregroundStyle(better ? .green : .red)
                        .monospacedDigit()
                }
            }
        }
    }

    private func side(_ title: String, _ side: FixEvaluation.Side, scale: Double) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            IntervalBar(value: side.sessions > 0 ? Double(side.failures) / Double(side.sessions) : nil, interval: side.interval, scale: scale)
                .frame(width: 200, height: 14)
            Text("\(side.failures) of \(side.sessions) sessions (95% \(AnalysisText.percent(side.interval.low))–\(AnalysisText.percent(side.interval.high)))")
                .monospacedDigit()
            Text([side.model, side.harnessVersion.map { "harness \($0)" }].compactMap(\.self).joined(separator: " · "))
                .foregroundStyle(.secondary)
        }
    }

    private func verdictText(_ evaluation: FixEvaluation) -> String {
        switch evaluation.verdict {
        case .helped: "Helped: P(after < before) ≥ 0.95 and no more than 50% that it got worse."
        case .notShown: "Not shown: the rule fixed before the run isn't met."
        case .noConclusion: "No conclusion: fewer than \(Fixes.minimumPerSide) sessions on a side."
        }
    }

    private func load() async {
        let mode = mode
        let pool = analysis.data.pool
        let modes = analysis.data.modes
        let env = analysis.env
        do {
            loaded = try await Task.detached { () -> Loaded in
                let evaluation = try Fixes.evaluate(mode, env: env)
                guard let applied = mode.fixAppliedAt else { return Loaded(evaluation: evaluation, regressions: [], matrix: []) }
                let rose = try Fixes.regressions(modes: modes, since: applied, env: env).filter { $0 != mode.id }
                let matrix = try Fixes.matrixDifference(appliedAt: applied, pool: pool, env: env)
                    .filter { !$0.value.dimmed && !$0.value.withinNoise }
                    .sorted { $0.key < $1.key }
                    .map { (key: $0.key, difference: $0.value) }
                return Loaded(evaluation: evaluation, regressions: rose, matrix: matrix)
            }.value
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct VerdictBadge: View {
    let verdict: FixEvaluation.Verdict

    var body: some View {
        let (text, color): (String, Color) = switch verdict {
        case .helped: ("helped", .green)
        case .notShown: ("not shown", .orange)
        case .noConclusion: ("no conclusion", .secondary)
        }
        Text(text)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
