import AKitCorrections
import AKitErrorAnalysis
import AKitFoundation
import AKitInsights
import AKitKnowledge
import AKitLab
import AKitProjectSetup
import SwiftUI

/// Insights → Corrections (`akit corrections`, `docs/design/corrections.md`): sessions where you
/// corrected the agent, counted by code; Find Pattern… makes the one model call; each pattern has
/// your words verbatim and a rule to Apply… or Dismiss; applied rules show their verdict.
struct InsightsCorrectionsBox: View {
    @Environment(AppModel.self) private var model
    /// The Insights screen's scope: nil for every session.
    let project: String?
    @State private var report: CorrectionsReport?
    @State private var state = CorrectionsState()
    @State private var verdicts: [CorrectionVerdict] = []
    @State private var problem: String?
    @State private var finding = false
    @State private var applying: CorrectionPattern?
    @State private var removing: CorrectionRule?
    @State private var notice: String?
    /// Bumped after a find, an apply, a dismiss or a removal: everything is read again.
    @State private var reloads = 0

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sessions where you corrected the agent: an interrupt, a pushback (\u{201C}no\u{201D}, \u{201C}not that\u{201D}, \u{201C}you forgot\u{201D}…), your refusal of a tool call or a bad rating. Counted by code, no model call. Find Pattern… sends short excerpts of them to one model call and proposes up to 3 rules for what repeats.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let report {
                    summary(report)
                } else if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                if let notice {
                    Label(notice, systemImage: "checkmark.circle").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(state.shown) { pattern in
                    Divider()
                    patternCard(pattern)
                }
                if !verdicts.isEmpty {
                    Divider()
                    Text("Rules from corrections").font(.subheadline.bold())
                    ForEach(verdicts) { verdict in ruleRow(verdict) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text("Corrections").font(.headline)
        }
        .task(id: "\(project ?? "-")|\(model.lastScan?.timeIntervalSince1970 ?? 0)|\(reloads)") { await load() }
        .sheet(isPresented: $finding) {
            if let report {
                FindPatternSheet(report: report) { count in
                    notice = count == 0 ? "No correction repeats across sessions." : "Found \(count) pattern\(count == 1 ? "" : "s")."
                    reloads += 1
                }
            }
        }
        .sheet(item: $applying) { pattern in
            CorrectionRuleSheet(change: .apply(pattern)) { lines in
                notice = lines.joined(separator: " ")
                reloads += 1
            }
        }
        .sheet(item: $removing) { rule in
            CorrectionRuleSheet(change: .remove(rule)) { lines in
                notice = lines.joined(separator: " ")
                reloads += 1
            }
        }
    }

    private func summary(_ report: CorrectionsReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(report.sessionsCorrected) of \(report.sessionsScanned) sessions in the last \(report.days) days had a correction (\(Int((report.share * 100).rounded()))%).")
            if project == nil, report.byProject.count > 1 {
                Text(report.byProject.map { "\($0.name.map(Self.shortProject) ?? "no project") \($0.corrected)" }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Find Pattern…") { finding = true }
                    .disabled(Set(report.sessions.map(\.key)).count < 2)
                    .help(Set(report.sessions.map(\.key)).count < 2 ? "A pattern needs corrections in at least 2 sessions"
                          : "See what would be sent, then send it to one model call (at most about 15k tokens of excerpts)")
            }
        }
    }

    private func patternCard(_ pattern: CorrectionPattern) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pattern.title).font(.body.bold())
            Text("\(pattern.sessions) sessions · \(pattern.scope.map { "project \(Self.shortProject($0))" } ?? "every project")")
                .font(.callout).foregroundStyle(.secondary)
            Text("You said").font(.callout.bold())
            ForEach(pattern.reactions) { reaction in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(reaction.kind.title).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    Text(reaction.words.isEmpty ? "(no words)" : "\u{201C}\(reaction.words)\u{201D}")
                        .font(.callout).lineLimit(3).textSelection(.enabled)
                    Spacer()
                    if let file = reaction.file, model.sessions.contains(where: { $0.file.path == file }) {
                        Button("Show") {
                            model.revealSession = SessionReveal(path: file, step: reaction.step)
                            model.section = .sessions
                        }
                        .controlSize(.small)
                        .help("Open this session in Sessions at your correction")
                    }
                }
            }
            Text("Rule").font(.callout.bold())
            Text(CorrectionRules.bullet(pattern.rule)).font(.callout.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Apply…") { applying = pattern }
                    .help("Put the rule under \u{201C}## \(CorrectionRules.heading)\u{201D} in Global Instructions or a project's file; you see the diff first")
                Button("Dismiss") { dismiss(pattern) }
                    .help("Don't show this pattern again")
            }
        }
    }

    private func ruleRow(_ verdict: CorrectionVerdict) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verdict.statusTitle)
                .font(.caption.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Self.color(verdict.status).opacity(0.18), in: Capsule())
                .foregroundStyle(Self.color(verdict.status))
                .frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verdict.rule.title)
                Group {
                    if let before = verdict.before, let after = verdict.after {
                        Text("Corrected before: \(before.corrected) of \(before.sessions) · after: \(after.corrected) of \(after.sessions) · \(verdict.group ?? "")")
                    }
                    Text("\(verdict.rule.isGlobal ? "Global Instructions" : FileWalk.tilde(URL(filePath: verdict.rule.target), home: HarnessEnvironment.current.homeDirectory)) · \(verdict.note)")
                }
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if verdict.offersRemove {
                Button("Remove Rule…") { removing = verdict.rule }
                    .controlSize(.small)
                    .help("The rule didn't make corrections fewer: take it out again (diff first, backup)")
            }
        }
        .font(.callout)
    }

    static func color(_ status: CorrectionVerdict.Status) -> Color {
        switch status {
        case .fewer: .green
        case .more: .red
        case .noChange: .orange
        case .waiting, .removed: .secondary
        }
    }

    /// `github.com/me/app` → `app`.
    static func shortProject(_ id: String) -> String { id.split(separator: "/").last.map(String.init) ?? id }

    private func dismiss(_ pattern: CorrectionPattern) {
        let env = HarnessEnvironment.current
        Task {
            // The state's lock may wait: off the main actor.
            let problem = await Task.detached { () -> String? in
                do {
                    try CorrectionsState.update(env: env) { $0.dismiss(pattern) }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            notice = problem ?? "Dismissed: it isn't shown again."
            reloads += 1
        }
    }

    private func load() async {
        let env = HarnessEnvironment.current, project = project
        let result = await Task.detached { () -> (CorrectionsReport?, [CorrectionVerdict], CorrectionsState, String?) in
            do {
                return (try Corrections.report(env: env, project: project), try Corrections.verdicts(env: env),
                        try CorrectionsState.load(env: env), nil)
            } catch {
                return (nil, [], CorrectionsState(), error.localizedDescription)
            }
        }.value
        guard !Task.isCancelled else { return }
        (report, verdicts, state, problem) = result
        // Snapshots: `--query corrections-apply` opens Apply… of the first pattern.
        if DebugSnapshot.options?.query == "corrections-apply", applying == nil, let first = state.shown.first { applying = first }
    }
}

/// Find Pattern…: what would be sent (counted and shown before the call), the model, and the send.
struct FindPatternSheet: View {
    let report: CorrectionsReport
    let onDone: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pick: CorrectionPick?
    /// The input as the scrub leaves it, for the preview (a tool result may hold a token).
    @State private var shown = ""
    @State private var models: [String] = []
    @State private var defaultModel: String?
    @State private var chosen = ""
    @State private var thinking = Corrections.defaultThinking
    @State private var sending = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Pattern").font(.title2.bold())
            if let pick {
                Text("Sends \(pick.excerpts.count) corrections from \(pick.sessions) sessions (≈ \(pick.approxTokens) tokens and a short prompt) to one model call through Pi, under the sending policy, the scrub and the send log (corrections). For each correction: your words and the agent's 3 steps before it, cut short.")
                    .fixedSize(horizontal: false, vertical: true)
                if pick.cut > 0 { Text("\(pick.cut) more sessions are left out: the input's cap.").foregroundStyle(.secondary) }
                Form {
                    PiModelPicker(selection: $chosen, models: models,
                                  empty: "Default (\(defaultModel ?? (models.isEmpty ? "reading the list…" : "none")))",
                                  help: "Pi's models (pi --list-models); GPT-6 Luna by default", allowsOther: false) {
                        Text("Model")
                    }
                    Picker("Thinking", selection: $thinking) {
                        ForEach(LabHarness.pi.efforts, id: \.self) { Text($0).tag($0) }
                    }
                    .help("Pi's thinking level: a weak model finds patterns better with some thought (default medium)")
                }
                .formStyle(.grouped)
                DisclosureGroup("What is sent") {
                    ScrollView {
                        Text(shown).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                }
            } else {
                ProgressView("Reading the sessions…")
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if sending { ProgressView().controlSize(.small); Text("Waiting for the model…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send") { Task { await send() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || (pick?.sessions ?? 0) < 2)
            }
        }
        .padding(20)
        .frame(width: 620)
        .task {
            let env = HarnessEnvironment.current, report = report
            let made = await Task.detached { () -> (CorrectionPick, String) in
                let pick = CorrectionExcerpts.pick(report, env: env)
                return (pick, Scrubber.scrub(pick.input, own: LabSettings.load(env: env).scrub).text)
            }.value
            (pick, shown) = made
            let available = await LabRuns.models(for: .pi, env: env)
            models = available
            defaultModel = KnowledgeCheckModel.defaultModel(for: .pi, available: available)
        }
    }

    private func send() async {
        guard let pick else { return }
        sending = true
        problem = nil
        defer { sending = false }
        do {
            let found = try await Corrections.find(pick, model: chosen, thinking: thinking, env: .current)
            onDone(found.count)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Apply… of a pattern or Remove Rule… of an applied rule: the target, the diff, then the write.
struct CorrectionRuleSheet: View {
    enum Change: Sendable {
        case apply(CorrectionPattern)
        case remove(CorrectionRule)
    }

    let change: Change
    let onDone: ([String]) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// `global` or a project id; AKit's proposal first (the pattern's project when it has one).
    @State private var target: String

    init(change: Change, onDone: @escaping ([String]) -> Void) {
        self.change = change
        self.onDone = onDone
        if case .apply(let pattern) = change, let scope = pattern.scope { _target = State(initialValue: scope) }
        else { _target = State(initialValue: CorrectionRules.globalTarget) }
    }
    @State private var plan: CorrectionRules.Plan?
    @State private var problem: String?
    @State private var writing = false

    private var title: String {
        switch change {
        case .apply: "Apply Rule"
        case .remove: "Remove Rule"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            switch change {
            case .apply(let pattern):
                Text(pattern.title).font(.headline)
                Picker("Put it into", selection: $target) {
                    Text("Global Instructions (every project)").tag(CorrectionRules.globalTarget)
                    ForEach(model.brainProjectFolders.keys.sorted(), id: \.self) { Text($0).tag($0) }
                }
                .help("AKit proposes the target from your corrections: from one project → that project's file, else Global Instructions")
            case .remove(let rule):
                Text(rule.title).font(.headline)
            }
            if let plan {
                Text(plan.shown).font(.callout.monospaced()).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { DiffPreview(diff: plan.lines) }
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                ForEach(plan.notes, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                if case .apply = change {
                    Text("Applying marks this moment; after \(CorrectionVerdict.minAfter) sessions in the rule's scope the card shows whether corrections went down.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if writing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(title) { Task { await write() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil || writing)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            // A project this Mac doesn't have: Global Instructions.
            if target != CorrectionRules.globalTarget, model.brainProjectFolders[target] == nil { target = CorrectionRules.globalTarget }
        }
        .task(id: target) { await makePlan() }
    }

    private func makePlan() async {
        let env = HarnessEnvironment.current, brain = model.brain, folders = model.brainProjectFolders, store = model.projectStore
        let change = change, target = target
        let result = await Task.detached { () -> Result<CorrectionRules.Plan, Error> in
            let rendered = InstructionEdit.renderedFiles(projects: folders, store: store)
            do {
                switch change {
                case .apply(let pattern):
                    let chosen: CorrectionRules.Target = target == CorrectionRules.globalTarget ? .global
                        : folders[target].map { .project(id: target, folder: $0) } ?? .global
                    return .success(try CorrectionRules.planApply(pattern, to: chosen, brain: brain, rendered: rendered, env: env))
                case .remove(let rule):
                    return .success(try CorrectionRules.planRemove(rule, brain: brain, rendered: rendered, env: env))
                }
            } catch {
                return .failure(error)
            }
        }.value
        // A plan for a target the picker no longer shows must not be written.
        guard !Task.isCancelled, target == self.target else { return }
        switch result {
        case .success(let made):
            plan = made
            problem = nil
        case .failure(let error):
            plan = nil
            problem = error.localizedDescription
        }
    }

    private func write() async {
        guard let plan else { return }
        writing = true
        defer { writing = false }
        do {
            switch change {
            case .apply(let pattern): onDone(try await model.applyCorrectionRule(plan, pattern: pattern))
            case .remove: onDone(try await model.removeCorrectionRule(plan))
            }
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
