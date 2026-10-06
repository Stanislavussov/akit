import AKitBrain
import AKitFoundation
import AKitHarnesses
import AKitInsights
import SwiftUI

/// Insights screen: what the skill listing costs in every request, and the auto skills the
/// model never calls. The same report as `akit recommend --details`, from the same core calls
/// (`Recommender.load`), so the screen and the command never disagree.
struct InsightsView: View {
    @Environment(AppModel.self) private var model
    /// nil: every session on this Mac, with the other Macs' summaries. Snapshots: `--select <project id>`.
    @State private var project: String? = DebugSnapshot.options?.select
    @State private var loaded: Recommender.Loaded?
    @State private var isLoading = false
    @State private var problem: String?
    @State private var patch: InsightsPatch?
    @State private var dismissing: RecommendReport.Recommendation?
    /// What the last Apply or Dismiss did.
    @State private var notice: String?
    /// Counts the loads started, so a superseded one can tell.
    @State private var generation = 0
    /// Set when session capture is off or out of date on this Mac.
    @State private var captureNotice: String?

    var body: some View {
        Group {
            if let loaded {
                content(loaded.report)
            } else if let problem {
                ContentUnavailableView {
                    Label("Couldn't read the session index", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                ProgressView("Reading new session lines…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Insights")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Scope", selection: $project) {
                    Text("All Sessions").tag(String?.none)
                    ForEach(scopes, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .fixedSize()
                .help("All sessions on this Mac with the other Macs' summaries, or only the sessions bound to one project")
            }
            ToolbarItem {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Import Now", systemImage: "arrow.clockwise") { Task { await load() } }
                        .disabled(model.lastScan == nil)
                        .help("Read new Claude Code and Pi session lines into the index (counts and sizes, never message text), then count again")
                }
            }
            ToolbarItem {
                GuideButton(guide: .screens, section: SidebarSection.insights.rawValue)
            }
        }
        // Every rescan (launch, ⌘R, a commit made here) loads again: the brain decides who owns a skill.
        .task(id: LoadKey(project: project, scan: model.lastScan)) { await load() }
        // Its status runs `claude` and `launchctl`: off the main thread, once each time the screen appears.
        .task {
            let brain = model.brain?.root
            captureNotice = await Task.detached { await Self.captureNotice(env: .current, brain: brain) }.value
        }
        .sheet(item: $patch) { patch in
            InsightsPatchSheet(patch: patch) { notice = $0 }
        }
        .alert("Hide This Advice?", isPresented: Binding(get: { dismissing != nil }, set: { if !$0 { dismissing = nil } }),
               presenting: dismissing) { item in
            Button("Dismiss") { Task { await dismissAdvice(item) } }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            let space = item.evidence.approxContextSpace
            Text("\(item.subject) is hidden until its ≈ context space reaches ≈ \(ContextSize.short(Dismissals.showsAgainAt(space))) (twice now's ≈ \(ContextSize.short(space))).")
        }
    }

    /// The loaded projects, plus the chosen one while its report is still loading.
    private var scopes: [String] {
        var ids = loaded?.projects ?? []
        if let project, !ids.contains(project) { ids.insert(project, at: 0) }
        return ids
    }

    private var subtitle: String {
        guard let date = loaded?.lastImport else { return "" }
        return "Last import \(date.formatted(.relative(presentation: .named)))"
    }

    // MARK: Content

    private func content(_ report: RecommendReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let notice {
                    HStack(alignment: .firstTextBaseline) {
                        Label(notice, systemImage: "checkmark.circle").foregroundStyle(.green)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Close", systemImage: "xmark") { self.notice = nil }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let trouble = model.machine.problem {
                    Label(trouble, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let captureNotice {
                    Label(captureNotice, systemImage: "record.circle").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                owners(report)
                recommendations(report)
                footer(report)
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private func owners(_ report: RecommendReport) -> some View {
        let owners = report.summary.approxContextPerRequestByOwner.filter { $0.skills > 0 }
        let largest = max(owners.map(\.approxTokens).max() ?? 1, 1)
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if owners.isEmpty {
                    Text("No skill listing recorded in this scope yet. Import Now reads the session files on this Mac; akit setup (or akit insights install) records new sessions as they start.")
                        .foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(owners, id: \.owner) { owner in
                            GridRow {
                                Text(Self.ownerTitle(owner.owner))
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.quaternary).frame(width: 260, height: 8)
                                    Capsule().fill(.tint)
                                        .frame(width: max(3, 260 * CGFloat(owner.approxTokens) / CGFloat(largest)), height: 8)
                                }
                                Text("≈ \(ContextSize.short(owner.approxTokens))").monospacedDigit()
                                Text(Self.count(owner.skills, "skill")).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("≈ \(ContextSize.short(owners.map(\.approxTokens).reduce(0, +))) tokens of skill descriptions in every request. ≈ tokens = description characters / k (\(report.calibration.describe)).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text("≈ Context per Request, by Owner").font(.headline)
        }
    }

    private func recommendations(_ report: RecommendReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recommendations").font(.headline)
            Text("Auto skills the model never called: listed in ≥ \(Self.count(report.rule.minSessions, "session")) on ≥ \(Self.count(report.rule.minDistinctDays, "day")), summed over this Mac and the other Macs' summaries. Making one manual takes its description out of every request; /name still runs it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if report.recommendations.isEmpty {
                Text("Nothing to recommend.").padding(.top, 4)
            }
            ForEach(report.recommendations, id: \.id) { card($0) }
        }
    }

    private func card(_ item: RecommendReport.Recommendation) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.subject).font(.headline)
                    if item.skill != Recommender.wholePlugin {
                        Text(Self.ownerText(item.owner))
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(item.isPatch ? "Layer patch" : "Advice").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(item.id).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                        .help("The id akit recommend apply and dismiss take")
                }
                Text(Self.evidenceText(item.evidence)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let skills = item.evidence.skills {
                    DisclosureGroup(Self.count(skills.count, "skill")) {
                        Text(skills.joined(separator: ", ")).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                }
                if item.isPatch, let layer = item.action.layer {
                    Text("\(LayerPatch.path(layer: layer)): mode auto → manual").font(.callout.monospaced())
                }
                if let text = item.action.text {
                    Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if item.stale {
                    Label("Other Macs' summaries are old (\(item.staleMachines.joined(separator: ", "))): sync the brain first, they may have called it since.",
                          systemImage: "clock.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if item.isPatch {
                        Button("Apply…") { open(item, change: .manual) }
                            .disabled(model.brain == nil)
                            .help("Show the layer.yaml change that makes the skill manual, then commit it in the brain")
                    }
                    Button("Dismiss…") {
                        if item.patch != nil { open(item, change: .keepAuto) } else { dismissing = item }
                    }
                    .help(item.patch != nil ? "Keep the skill auto: pins it in its layer.yaml (keep_auto), so it isn't recommended again"
                          : "Hide this advice until its ≈ context space doubles")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func footer(_ report: RecommendReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if report.hiddenByDismissal > 0 {
                Text("Hidden by dismissal: \(report.hiddenByDismissal) (they return when their ≈ context space doubles).")
            }
            if !report.noData.isEmpty {
                DisclosureGroup("No data: \(Self.count(report.noData.count, "skill")) only Pi uses (Pi records no skill list)") {
                    Text(report.noData.map(\.skill).joined(separator: ", ")).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(report.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: Actions

    private struct LoadKey: Equatable {
        let project: String?
        let scan: Date?
    }

    private func load() async {
        // Before the first scan the brain isn't loaded yet, and without it every layer skill looks unowned.
        guard model.lastScan != nil else { return }
        let env = HarnessEnvironment.current
        // Loads overlap (a rescan during Import Now, two actions in a row) and an older one can
        // finish last: only the newest may show its report and end the spinner.
        generation += 1
        let mine = generation
        isLoading = true
        do {
            let result = try await Recommender.load(env: env, brain: model.brain, project: project, projectsRoot: model.projectsRoot)
            guard mine == generation else { return }
            loaded = result
            problem = nil
            // Snapshots: `--add` opens Apply… of the first layer patch.
            if DebugSnapshot.options?.add == true, patch == nil, let item = result.report.recommendations.first(where: \.isPatch) {
                open(item, change: .manual)
            }
        } catch {
            guard mine == generation else { return }
            problem = error.localizedDescription
        }
        isLoading = false
    }

    /// Opens the patch sheet: the recommended change, or `keep_auto` for Dismiss.
    private func open(_ item: RecommendReport.Recommendation, change: LayerPatch.Change) {
        guard let before = item.patch?.before, let layer = item.action.layer else { return }
        do {
            let after = try change == .manual ? item.patch?.after ?? before
                : LayerPatch.edit(before, skill: item.skill, layer: layer, change: .keepAuto)
            patch = InsightsPatch(item: item, layer: layer, change: change, before: before, after: after)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func dismissAdvice(_ item: RecommendReport.Recommendation) async {
        let env = HarnessEnvironment.current
        let entry = Dismissals.Entry(id: item.id, at: Date().formatted(.iso8601), approxContextSpace: item.evidence.approxContextSpace)
        do {
            try await Dismissals.dismiss(entry, project: item.scope.project, brain: model.brain?.root, home: env.homeDirectory,
                                         machine: MachineProfile.load(home: env.homeDirectory), env: env)
            notice = "Dismissed \(item.subject)."
        } catch {
            problem = error.localizedDescription
        }
        // A personal Mac commits the dismissal in the brain: the rescan shows it in Brain and loads this screen again.
        await model.refresh()
    }

    // MARK: Text

    /// A line when session capture (`akit insights install`) is off or out of date on this Mac.
    nonisolated static func captureNotice(env: HarnessEnvironment, brain: URL?) async -> String? {
        let status = await CaptureInstaller(env: env, brainRoot: brain).status()
        var off: [String] = [], outdated: [String] = []
        if status.claude.claudeFound, brain != nil, status.claude.installedVersion == nil {
            off.append("Claude Code")
        } else if status.claude.versionMismatch {
            outdated.append("Claude Code")
        }
        let piFound = HarnessCatalog.configRoot(of: .pi, in: env).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if piFound, status.pi.state == "missing" { off.append("Pi") }
        if status.pi.state == "outdated" { outdated.append("Pi") }
        if !status.launchd.loaded { off.append("the hourly import") }
        let parts = [off.isEmpty ? nil : "off for \(off.joined(separator: ", "))",
                     outdated.isEmpty ? nil : "out of date for \(outdated.joined(separator: ", "))"].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return "Session capture is \(parts.joined(separator: "; ")). Run akit setup (or akit insights install --yes) in Terminal."
    }


    /// `3 sessions`, `1 day`.
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// An owner kind as the command's text output says it.
    static func ownerTitle(_ kind: String) -> String {
        switch kind {
        case SkillOwner.Kind.handInstalled.rawValue: "hand-installed"
        case SkillOwner.Kind.builtIn.rawValue: "built-in"
        default: kind
        }
    }

    static func ownerText(_ owner: RecommendReport.Owner) -> String {
        [ownerTitle(owner.kind), owner.name].compactMap { $0 }.joined(separator: " ")
    }

    static func evidenceText(_ evidence: RecommendReport.Evidence) -> String {
        let period = evidence.from.map { " (\($0) … \(evidence.to ?? $0))" } ?? ""
        let macs = evidence.machines.count > 1 ? " on \(evidence.machines.count) Macs" : ""
        let rate = Int((evidence.callRateUpperBound95 * 100).rounded(.up))
        return "≈ \(ContextSize.short(evidence.approxContextSpace)) context space · listed in \(count(evidence.sessions, "session")) on "
            + "\(count(evidence.distinctDays, "day"))\(period)\(macs) · model calls 0 (rate < \(rate)% at 95%) · user calls \(evidence.userCalls)"
    }
}

/// A layer.yaml change the Insights screen is about to commit: the recommended `mode: manual`,
/// or `keep_auto: true` when the recommendation is dismissed.
struct InsightsPatch: Identifiable {
    let item: RecommendReport.Recommendation
    let layer: String
    let change: LayerPatch.Change
    let before: String
    let after: String

    var id: String { "\(item.id)-\(change == .manual ? "manual" : "keep")" }
}

/// The diff of one layer.yaml change and its commit. Nothing reaches a project or the home
/// folder here: they pick the change up when they are set up again.
struct InsightsPatchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let patch: InsightsPatch
    let onDone: (String) -> Void
    @State private var projects: [String] = []
    @State private var busy = false
    @State private var error: String?

    private var isManual: Bool { patch.change == .manual }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isManual ? "Set \(patch.item.skill) to Manual" : "Keep \(patch.item.skill) Auto").font(.title2.bold())
            Text(isManual
                 ? "The skill's description leaves the agent's context; /\(patch.item.skill) still runs it. This changes \(LayerPatch.path(layer: patch.layer)) in the brain and commits it."
                 : "Pins the skill to auto, so AKit stops recommending to make it manual. This changes \(LayerPatch.path(layer: patch.layer)) in the brain and commits it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if patch.item.stale {
                Label("Other Macs' summaries are old (\(patch.item.staleMachines.joined(separator: ", "))): sync the brain first, they may have called \(patch.item.skill) since.",
                      systemImage: "clock.badge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DiffPreview(diff: TextDiff.lines(from: patch.before, to: patch.after))
                }
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .frame(height: 220)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            if isManual, !projects.isEmpty {
                Text("It takes effect after these are set up again: \(Self.projectsText(projects)).")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Commit", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || model.brain == nil)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task {
            guard let brain = model.brain else { return }
            projects = Recommender.projectsUsing(patch.layer, brain: brain, home: HarnessEnvironment.current.homeDirectory)
        }
    }

    /// A home folder has no Set Up button yet: it is applied with the command.
    static func projectsText(_ projects: [String]) -> String {
        projects.map { $0.hasPrefix("home/") ? "\($0) (run akit apply --home)" : "\($0) (Brain → Set Up Project…)" }
            .joined(separator: ", ")
    }

    private func commit() {
        guard let brain = model.brain else { return }
        busy = true
        error = nil
        Task {
            let env = HarnessEnvironment.current
            do {
                // The file, not the app's copy, says whether this is a work Mac.
                try await LayerPatch.commit(skill: patch.item.skill, layer: patch.layer, change: patch.change, before: patch.before,
                                            after: patch.after, brain: brain.root, machine: MachineProfile.load(home: env.homeDirectory),
                                            env: env)
                var message = "Committed “\(patch.change.message(skill: patch.item.skill, layer: patch.layer))”."
                if isManual, !projects.isEmpty { message += " It takes effect after these are set up again: \(Self.projectsText(projects))." }
                await model.refresh()
                onDone(message)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
