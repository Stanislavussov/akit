import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import SwiftUI

/// A mode's judge and the validation of its check (`akit analysis judge|validate|validation`):
/// who judges, the pool run and what the notes missed, dev and test runs with TPR and TNR,
/// the labels behind them, and how far the check can be trusted.
struct ModeJudgePanel: View {
    @Environment(AnalysisModel.self) private var analysis
    let mode: Mode
    @State private var editJudge = false
    @State private var confirmTest = false
    /// Counting the sessions a pool run would judge (it reads every transcript's size).
    @State private var counting = false

    private var data: AnalysisData { analysis.data }
    private var judge: LabAgent? { data.judges[mode.id] }
    private var checker: String { Validation.checker(judge: judge, modeID: mode.id) }
    private var results: [ValidationResult] {
        (data.validation[mode.id] ?? []).filter { $0.modeVersion == mode.version && $0.checker == checker }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Judge & validation").font(.title3.bold())
                TrustBadge(level: data.trust[mode.id]?.level ?? .none)
                Spacer()
            }
            judgeRow
            if judge != nil { poolRun }
            validation
            labels
        }
        .sheet(isPresented: $editJudge) { JudgeAgentSheet(mode: mode, current: judge) }
    }

    // MARK: Judge

    @ViewBuilder private var judgeRow: some View {
        let seen = data.seenByMode.mapValues(\.count)
        let eligible = Judges.eligible(data.modes, seen: seen).contains { $0.id == mode.id }
        if let judge {
            HStack {
                Label("Judged by \(judge.label)", systemImage: "person.badge.shield.checkmark")
                Spacer()
                Button("Change…") { editJudge = true }
                    .disabled(!eligible)
                Button("Disable") {
                    let id = mode.id, name = mode.name
                    analysis.act { env in
                        try ValidationStore(env: env).setJudge(nil, for: id)
                        return "No judge for \(name)."
                    }
                }
                .help("The mode falls back to its code check, or to \"seen in k notes\"")
            }
            .controlSize(.small)
        } else {
            HStack {
                Text(CodeChecks.check(for: mode.id).map { $0.kind == .mechanical ? "No judge: the mechanical code check is exact." : "No judge: the heuristic code check is what gets validated." }
                     ?? "No judge and no code check: the mode stays \"seen in k notes\".")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Enable Judge…") { editJudge = true }
                    .controlSize(.small)
                    .disabled(!eligible)
            }
        }
        if !eligible {
            Text("Only a mode in the top 3 by notes with a fix drafted or applied gets a judge; this one isn't. Other modes get a code check or stay \"seen in k notes\".")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var poolRun: some View {
        HStack {
            if let results = data.judgeResults[mode.id], let rate = AnalysisText.rate(results) {
                Text("Over the pool: present in \(rate)").monospacedDigit()
            } else {
                Text("Not run over the pool yet.").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Run Judge over the Pool…", systemImage: "play", action: judgePool)
                .controlSize(.small)
                .disabled(counting)
                .help("Judge every reviewed session: where the mode is, and the cases the notes missed (a model call per session; the cost first)")
        }
        if let missed = analysis.judgeMissed[mode.id] {
            VStack(alignment: .leading, spacing: 3) {
                Text(missed.isEmpty ? "The notes missed none of the judge's finds." : "The notes missed \(missed.count) of the judge's finds:")
                    .fontWeight(.medium)
                ForEach(missed.prefix(12), id: \.self) { key in
                    Text("· \(data.notes(of: key)?.title ?? key)").foregroundStyle(.secondary).lineLimit(1)
                }
                if missed.count > 12 { Text("and \(missed.count - 12) more").foregroundStyle(.secondary) }
            }
            .font(.callout)
        }
    }

    // MARK: Validation

    @ViewBuilder private var validation: some View {
        let check = CodeChecks.check(for: mode.id)
        if judge == nil, check?.kind == .mechanical {
            Text("Exact by construction: TPR = TNR = 1 against the definition, so no validation and no correction.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            let testRan = results.contains { $0.set == .test }
            let validatable = judge != nil || check != nil
            // A heuristic code check is validated on its verdicts over the index: they must be
            // for this version of the mode, or every label would count as unchecked.
            let unchecked = judge == nil && check?.kind == .heuristic && data.currentCheck(mode) == nil
            HStack {
                Button("Validate on Dev…") { validate(.dev) }
                    .disabled(!validatable || unchecked)
                Button("Validate on Test…") {
                    if judge == nil { confirmTest = true } else { validate(.test) }
                }
                .disabled(!validatable || testRan || unchecked)
                if testRan {
                    Text("Test ran for v\(mode.version) with this check: iterate on dev; a change of the mode, model or prompt allows a new test run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !validatable {
                    Text("Enable a judge first: there is no check to validate.").font(.caption).foregroundStyle(.secondary)
                } else if unchecked {
                    Text("Run the code check for v\(mode.version) first: validation reads its verdicts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .controlSize(.small)
            .confirmationDialog("Validate on the test set?", isPresented: $confirmTest) {
                Button("Validate on Test") { validate(.test) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The test set runs once for v\(mode.version) with this check: its TPR and TNR decide how far the check is trusted, and another test run needs a new version of the mode or of the check. Iterate on dev first. Nothing is sent: the code check's verdicts are read here.")
            }
            ForEach([Validation.LabelSet.dev, .test], id: \.self) { set in
                if let result = results.last(where: { $0.set == set }) { ValidationResultView(result: result) }
            }
            let older = (data.validation[mode.id] ?? []).count - results.count
            if older > 0 {
                Text("\(older) earlier runs for another version, model or prompt don't count.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Valid: the Wilson lower bounds of TPR and TNR are both ≥ 80% on 30+ test labels per class; 20+ is provisional.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The pool judge's confirmation, with the cost of only the sessions it would judge.
    private func judgePool() {
        guard let judge else { return }
        let mode = mode, env = analysis.env
        let sessions = data.pool.map { (key: $0.sessionKey, file: $0.transcript) }
        counting = true
        Task {
            let pending = await Task.detached { Judges.pending(mode: mode, sessions: sessions, agent: judge, env: env).count }.value
            counting = false
            analysis.send = .judgePool(mode, data: data, pending: pending, model: analysis)
        }
    }

    private func validate(_ set: Validation.LabelSet) {
        let id = mode.id
        if let judge {
            let count = set == .dev ? data.splits[id]?.dev.count : data.splits[id]?.test.count
            analysis.send = .validate(mode, set: set, judge: judge, sessions: count ?? 20)
        } else {
            // A heuristic code check reads its verdicts over the index: nothing is sent.
            analysis.act { env in
                guard let mode = try await ModeStore(env: env).mode(id) else { throw AnalysisFailure("There is no mode \(id).") }
                let result = try await Validation.run(mode: mode, set: set, modes: try await ModeStore(env: env).list(), gate: nil,
                                                      workFolder: AnalysisModel.workFolder(env), env: env)
                return "Validated \(mode.name) on \(set.rawValue): TPR \(AnalysisText.percent(result.tpr)), TNR \(AnalysisText.percent(result.tnr))."
            }
        }
    }

    // MARK: Labels

    private var labels: some View {
        let labels = ModeLabels.labels(for: mode.id, modes: data.modes, bootstrap: Array(data.labels.values), book: data.book,
                                       toughCalls: data.book.toughCalls(of: mode.id))
        let bySource = Dictionary(grouping: labels, by: \.source)
        let split = data.splits[mode.id]
        return VStack(alignment: .leading, spacing: 3) {
            Text("Labels: \(labels.count) (\(labels.filter(\.positive).count) present, \(labels.filter { !$0.positive }.count) absent) · "
                 + "bootstrap \(bySource[.bootstrap]?.count ?? 0), similar cases \(bySource[.similarCase]?.count ?? 0), tough calls \(bySource[.toughCall]?.count ?? 0)")
            if let split {
                Text("Split: train \(split.train.count) · dev \(split.dev.count) · test \(split.test.count). Exemplars come from train only.")
            } else {
                Text("Not split yet: the first validation run splits the labels 10 / 30 / 60.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// One dev or test run: TPR and TNR with their Wilson lower bounds and the labels behind them.
private struct ValidationResultView: View {
    let result: ValidationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(result.set == .test ? "Test" : "Dev").fontWeight(.semibold)
                Text(result.at.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 2) {
                metric("TPR", result.tpr, low: result.tprLow, labels: result.labels.onPositives, word: "present")
                metric("TNR", result.tnr, low: result.tnrLow, labels: result.labels.onNegatives, word: "absent")
            }
            .monospacedDigit()
            let extras = [result.toughLeftOut > 0 ? "\(result.toughLeftOut) tough calls left out" : nil,
                          result.unchecked > 0 ? "\(result.unchecked) labels without a verdict" : nil].compactMap(\.self)
            if !extras.isEmpty { Text(extras.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
        }
        .font(.callout)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func metric(_ name: String, _ value: Double?, low: Double?, labels: [Bool], word: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(AnalysisText.percent(value)).fontWeight(.medium)
            Text("lower bound \(AnalysisText.percent(low))")
                .foregroundStyle((low ?? 0) >= Validation.lowerBound ? .green : .orange)
            Text("on \(labels.count) labels \(word)").foregroundStyle(.secondary)
        }
    }
}

/// Who judges a mode: harness, model and effort (`akit analysis judge enable`).
private struct JudgeAgentSheet: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    let current: LabAgent?
    @State private var harness: LabHarness
    @State private var modelName: String
    @State private var effort: String
    @State private var error: String?
    @State private var busy = false

    /// Change…: the current judge preselected.
    init(mode: Mode, current: LabAgent?) {
        self.mode = mode
        self.current = current
        _harness = State(initialValue: current?.harness ?? .claudeCode)
        _modelName = State(initialValue: current?.model ?? "")
        _effort = State(initialValue: current?.effort ?? "high")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Judge for \(mode.name)").font(.title2.bold())
            Text("An LLM judge decides per session whether the mode is present, from the transcript. It runs on every session of later batches and over the pool by button. A new model or prompt needs a new test run.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                ReviewAgentFields(harness: $harness, modelName: $modelName, effort: $effort, keepsValues: current != nil)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 150)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (harness == .claudeCode && modelName.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func save() {
        let agent = LabAgent(harness: harness, model: modelName.trimmingCharacters(in: .whitespaces), effort: effort, mode: .call)
        let id = mode.id, name = mode.name
        busy = true
        error = nil
        Task {
            do {
                try await analysis.run { env in
                    try ValidationStore(env: env).setJudge(agent, for: id)
                    return "\(name) is judged by \(agent.label). Validate it on dev."
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

extension AnalysisSend {
    /// `akit analysis judge run`: the mode's judge over every reviewed session.
    /// `pending`: the sessions not judged before on an unchanged file; only they are sent.
    static func judgePool(_ mode: Mode, data: AnalysisData, pending: Int, model: AnalysisModel) -> AnalysisSend {
        let id = mode.id
        let skipped = data.pool.count - pending
        return AnalysisSend(
            title: "Run the Judge over the Pool",
            detail: "Judges \(pending) of the \(data.pool.count) reviewed sessions for \(mode.name) (a digest of each transcript, secrets masked)"
                + (skipped > 0 ? "; \(skipped) judged before on an unchanged file are skipped and cost nothing." : ".")
                + " Then: where it finds the mode, and the cases the notes missed.",
            characters: pending * 60_000,
            fixedAgent: data.judges[id]
        ) { agent, gate, env in
            let store = ModeStore(env: env)
            guard let mode = try await store.mode(id) else { throw AnalysisFailure("There is no mode \(id).") }
            let pool = NotesStore(env: env).all()
            let results = try await Judges.run(mode: mode, sessions: pool.map { ($0.sessionKey, $0.transcript) }, agent: agent, gate: gate,
                                               runID: nil, workFolder: AnalysisModel.workFolder(env), env: env)
            let missed = Judges.missedByNotes(results, modeID: id, pool: pool, modes: try await store.list())
            await MainActor.run { model.judgeMissed[id] = missed }
            let rate = results.rate()
            return "Present in \(rate.positive) of \(rate.total) sessions; the notes missed \(missed.count) of them."
        }
    }

    /// `akit analysis validate MODE dev|test` for a judge: it judges the set's sessions.
    static func validate(_ mode: Mode, set: Validation.LabelSet, judge: LabAgent, sessions: Int) -> AnalysisSend {
        let id = mode.id
        return AnalysisSend(
            title: set == .test ? "Validate on Test" : "Validate on Dev",
            detail: set == .test
                ? "Judges the \(sessions) held-out test sessions once for this mode version and judge, and records TPR and TNR. Iterate on dev first: test runs once."
                : "Judges the \(sessions) dev sessions and records TPR and TNR against your labels.",
            characters: max(sessions, 1) * 60_000,
            fixedAgent: judge
        ) { _, gate, env in
            let store = ModeStore(env: env)
            guard let mode = try await store.mode(id) else { throw AnalysisFailure("There is no mode \(id).") }
            let result = try await Validation.run(mode: mode, set: set, modes: try await store.list(), gate: gate,
                                                  workFolder: AnalysisModel.workFolder(env), env: env)
            let trust = Validation.trust(modeID: id, modeVersion: mode.version, checker: result.checker,
                                         results: ValidationStore(env: env).results()[id] ?? [])
            return "\(mode.name) on \(set.rawValue): TPR \(AnalysisText.percent(result.tpr)) (low \(AnalysisText.percent(result.tprLow))), "
                + "TNR \(AnalysisText.percent(result.tnr)) (low \(AnalysisText.percent(result.tnrLow))) · \(trust.level.rawValue)."
        }
    }}
