import AKitBrain
import AKitFoundation
import AKitInsights
import SwiftUI

/// Insights screen: what the skill listing costs in every request, and the auto skills the
/// model never calls. The same report as `akit recommend --details`, from the same core calls
/// (`Recommender.load`), so the screen and the command never disagree.
struct InsightsView: View {
    @Environment(AppModel.self) private var model
    /// nil: every session on this Mac, with the other Macs' summaries. Snapshots: `--select <project id>`.
    @State private var project: String? = DebugSnapshot.options?.select
    /// The skills table's window; recommendations keep the rule's own.
    @State private var days = InsightsStats.defaultDays
    /// The skills table shows the first `shortTable` rows until Show All.
    @State private var allSkills = false
    /// The Changes list shows the newest `shortChanges` until Show All.
    @State private var allChanges = false
    @State private var loaded: Recommender.Loaded?
    @State private var isLoading = false
    @State private var problem: String?
    @State private var patch: InsightsPatch?
    @State private var dismissing: RecommendReport.Recommendation?
    /// What the last Apply or Dismiss did.
    /// Any new notice drops the previous Plan… list; the patch sheet sets its own after it.
    @State private var notice: String? {
        didSet { toPlan = [] }
    }
    /// Projects a committed layer patch reaches only after they are set up again (Plan… buttons under the notice).
    @State private var toPlan: [String] = []
    /// The project Plan… opened in Set Up Project.
    @State private var planning: PlanRequest?
    /// Counts the loads started, so a superseded one can tell.
    @State private var generation = 0
    /// Session capture on this Mac (`akit insights status`); nil until checked.
    @State private var capture: CaptureInstaller.Status?
    /// Bumped after Install Capture…, so the status is read again.
    @State private var captureChecks = 0
    /// Snapshots: `--capture` opens Install Capture….
    @State private var installingCapture = DebugSnapshot.options?.capture == true
    @State private var addingMark = false

    var body: some View {
        Group {
            if let loaded {
                content(loaded)
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
            ToolbarItem(placement: .navigation) {
                Picker("Window", selection: $days) {
                    ForEach([7, 30, 90], id: \.self) { Text("\($0) Days").tag($0) }
                }
                .fixedSize()
                .help("The days the Skills table counts; recommendations always use their rule's own window")
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
        .task(id: LoadKey(project: project, days: days, scan: model.lastScan)) { await load() }
        // Its status runs `claude` and `launchctl`: off the main thread, each time the screen appears
        // or the brain changes (the Claude plugin lives there).
        .task(id: CaptureKey(brain: model.brain?.root, checks: captureChecks)) {
            let brain = model.brain?.root
            capture = await Task.detached { await CaptureInstaller(env: .current, brainRoot: brain).status() }.value
        }
        .sheet(item: $patch) { patch in
            InsightsPatchSheet(patch: patch) { message, projects in
                notice = message
                toPlan = projects
            }
        }
        .sheet(item: $planning) { ProjectSetupSheet(initialProject: $0.home ? nil : $0.folder, forHome: $0.home) }
        .sheet(isPresented: $addingMark) {
            AddMarkSheet { message in
                notice = message
                Task { await load() }
            }
        }
        .sheet(isPresented: $installingCapture) {
            CaptureInstallSheet { message in
                notice = message
                captureChecks += 1
            }
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

    private func content(_ loaded: Recommender.Loaded) -> some View {
        let report = loaded.report
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let notice {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Label(notice, systemImage: "checkmark.circle").foregroundStyle(.green)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Close", systemImage: "xmark") {
                                self.notice = nil
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                        if !toPlan.isEmpty { planButtons }
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
                if let capture { captureLine(capture) }
                owners(report)
                recommendations(report)
                skills(loaded.stats)
                changes(loaded.changes)
                footer(report)
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    /// After a layer patch: the projects that pick it up only when they are set up again. Plan… opens
    /// Set Up Project with the project's saved answers, where the change is shown as a diff before
    /// anything is written. This Mac's home folder gets Update Home Folder, the same with the core layer.
    private var planButtons: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("It takes effect after these are set up again:").font(.callout)
            ForEach(toPlan, id: \.self) { id in
                HStack(alignment: .firstTextBaseline) {
                    Text(id).font(.callout.monospaced())
                    if id == ProjectRecords.homeID(machineName: model.machine.homeName) {
                        Button("Plan…") { planning = PlanRequest(folder: HarnessEnvironment.current.homeDirectory, home: true) }
                            .help("Open Update Home Folder: the change as a diff, then Apply")
                    } else if id.hasPrefix("home/") {
                        Text("another Mac's home folder: update it on that Mac").font(.callout).foregroundStyle(.secondary)
                    } else if let folder = model.brainProjectFolders[id] {
                        Button("Plan…") { planning = PlanRequest(folder: folder) }
                            .help("Open Set Up Project for \(folder.tildePath): the change as a diff, then Apply")
                    } else {
                        Text("not on this Mac").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.leading, 26)
    }

    struct PlanRequest: Identifiable {
        let folder: URL
        var home = false
        var id: URL { folder }
    }

    /// Session capture off or out of date, or turned off in `akit setup`: a line and Install Capture….
    @ViewBuilder
    private func captureLine(_ status: CaptureInstaller.Status) -> some View {
        let text = CaptureNotice.text(status: status, brainPresent: model.brain != nil)
        let chosen = CaptureNotice.offByChoice(status: status, brainPresent: model.brain != nil)
        if text != nil || chosen != nil {
            HStack(alignment: .firstTextBaseline) {
                if let text {
                    Label(text, systemImage: "record.circle").foregroundStyle(.orange)
                } else if let chosen {
                    Label(chosen, systemImage: "record.circle").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Install Capture…") { installingCapture = true }
                    .help("Show what recording new sessions as they start takes on this Mac, then set it up")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func owners(_ report: RecommendReport) -> some View {
        let owners = report.summary.approxContextPerRequestByOwner.filter { $0.skills > 0 }
        let largest = max(owners.map(\.approxTokens).max() ?? 1, 1)
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if owners.isEmpty {
                    Text("No skill listing recorded in this scope yet. Import Now reads the session files on this Mac; session capture (Install Capture…, or akit setup) records new sessions as they start.")
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
            Text("Auto skills the model never called: listed with their description in ≥ \(Self.count(report.rule.minSessions, "session")) on ≥ \(Self.count(report.rule.minDistinctDays, "day")), summed over this Mac and the other Macs' summaries. Making one manual takes its description out of every request; /name still runs it.")
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

    /// Rows the Skills table shows before Show All.
    static let shortTable = 15
    /// Changes shown before Show All.
    static let shortChanges = 8

    /// `akit stats --details`: every skill listed in the window, by ≈ context space.
    private func skills(_ stats: StatsReport) -> some View {
        let summary = stats.summary
        let rows = allSkills ? stats.skills : Array(stats.skills.prefix(Self.shortTable))
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(Self.statsLine(stats)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let dropped = stats.droppedDescriptions.text {
                    Label(dropped, systemImage: "text.badge.minus").font(.callout)
                        .foregroundStyle(stats.droppedDescriptions.withNameOnly > 0 ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Some skills were listed by name only, usually because Claude Code's skill listing was over its budget (1% of the context window by default), or because of a user override (name-only). Such a skill can't be picked by its description, so the session doesn't count in Listed. Making unused skills manual gives the others their descriptions back.")
                }
                if stats.skills.isEmpty {
                    Text("No skill listings in this window.").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                        GridRow {
                            Text("Skill")
                            Text("Owner")
                            Text("Listed").gridColumnAlignment(.trailing)
                            Text("Model calls").gridColumnAlignment(.trailing)
                            Text("User calls").gridColumnAlignment(.trailing)
                            Text("≈ Tokens").gridColumnAlignment(.trailing)
                            Text("≈ Context space").gridColumnAlignment(.trailing)
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(rows, id: \.name) { skill in
                            GridRow {
                                Text(skill.name).lineLimit(1).truncationMode(.middle)
                                    .help("Counted since \(Self.day(skill.windowStart)), the start of its current description or of the window")
                                Text([Self.ownerTitle(skill.owner.kind), skill.owner.name].compactMap { $0 }.joined(separator: " "))
                                    .lineLimit(1).foregroundStyle(.secondary)
                                Text("\(skill.listedSessions) · \(Self.count(skill.listedDays, "day"))")
                                    .help("Sessions where it was listed with its description, on how many days")
                                Text(Self.modelCalls(skill))
                                    .help("Model calls in every session that listed it, by name only too: they protect it. The % is the share of the sessions in Listed with a model call.")
                                Text("\(skill.userCalls)")
                                Text("≈ \(ContextSize.short(skill.approxTokens))")
                                    .help("Its description in every request where it is listed")
                                Text("≈ \(ContextSize.short(skill.approxContextSpace))")
                                    .help("≈ description tokens × requests, summed over the sessions where it was listed")
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                    if stats.skills.count > Self.shortTable {
                        Button(allSkills ? "Show Fewer" : "Show All \(stats.skills.count) Skills") { allSkills.toggle() }
                            .buttonStyle(.link)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text("Skills, Last \(stats.window.days) Days").font(.headline)
        }
        .help(summary.sessions == 0 ? "" : "The same numbers as akit stats --details")
    }

    /// `akit stats changes`: what each apply or mark did to the recorded first-request context.
    private func changes(_ report: ChangesReport) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("First-request context (recorded tokens) of the sessions within \(Int(BeforeAfter.window / 86_400)) days before and after each change, with the same harness version and model. Applies are recorded by themselves; Add Mark… records a change made by hand, such as a plugin turned off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if report.changes.isEmpty {
                    Text("No changes yet.").foregroundStyle(.secondary)
                }
                let newest = Array(report.changes.reversed())
                ForEach(allChanges ? newest : Array(newest.prefix(Self.shortChanges)), id: \.key) { changeRow($0) }
                if newest.count > Self.shortChanges {
                    Button(allChanges ? "Show Fewer" : "Show All \(newest.count) Changes") { allChanges.toggle() }
                        .buttonStyle(.link)
                }
                ForEach(report.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                Text(Self.calibrationText(report.calibration)).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            HStack {
                Text("Changes").font(.headline)
                Spacer()
                Button("Add Mark…") { addingMark = true }
                    .help("Record a change made by hand, so its before/after is measured (akit stats mark)")
            }
        }
    }

    private func changeRow(_ change: ChangesReport.Change) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(change.date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit().foregroundStyle(.secondary)
                Text(change.anchor == "mark" ? "Mark “\(change.note ?? "")”" : "Apply \(change.project ?? "")").bold()
                Text(change.scope.project.map { "sessions of \($0)" } ?? "all sessions on this Mac")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(Self.changeText(change)).font(.callout).foregroundStyle(change.isMeasured ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
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
        let days: Int
        let scan: Date?
    }

    private struct CaptureKey: Equatable {
        let brain: URL?
        let checks: Int
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
            let result = try await Recommender.load(env: env, brain: model.brain, project: project, days: days,
                                                    projectsRoot: model.projectsRoot)
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

    /// Sessions, requests, the recorded first-request context and the listing's share of each request.
    static func statsLine(_ stats: StatsReport) -> String {
        let summary = stats.summary
        var parts = ["\(count(summary.sessions, "session")), \(count(summary.requests, "request"))"]
        if summary.sessions > 0 {
            parts.append("first-request context median \(ContextSize.short(summary.firstRequestContext.median)), "
                         + "p90 \(ContextSize.short(summary.firstRequestContext.p90)) tokens (recorded)")
            parts.append("skill listing ≈ \(ContextSize.short(summary.approxListingTokensPerRequest)) tokens per request")
        }
        return parts.joined(separator: " · ")
    }

    /// The measured change, or why there is none.
    static func changeText(_ change: ChangesReport.Change) -> String {
        guard change.isMeasured, let group = change.group, let before = change.before, let after = change.after else {
            return "Not enough data: \(change.reason ?? "")"
        }
        let short = ContextSize.short
        func signed(_ n: Int) -> String { n > 0 ? "+" + short(n) : short(n) }
        var text = "\(group.harness) \(group.harnessVersion ?? "?"), \(group.model ?? "unknown model"): median \(short(before.median)) → "
            + "\(short(after.median)) tokens (\(signed(change.deltaTokens ?? 0))), \(count(before.sessions, "session")) before, "
            + "\(after.sessions) after."
        let left = change.left ?? [], joined = change.joined ?? []
        if left.isEmpty, joined.isEmpty {
            text += " Skill listing unchanged."
        } else {
            var parts: [String] = []
            if !left.isEmpty { parts.append("\(count(left.count, "skill")) left") }
            if !joined.isEmpty { parts.append("\(count(joined.count, "skill")) joined") }
            text += " Skill listing: \(parts.joined(separator: ", ")), \(signed(change.deltaChars ?? 0)) description characters"
                + (change.k.map { "; k ≈ \(String(format: "%.1f", $0)) characters per token" } ?? "") + "."
        }
        return text
    }

    /// The k in use per script and where it comes from.
    static func calibrationText(_ calibration: ChangesReport.Calibration) -> String {
        func k(_ value: Double, _ script: String, _ pairs: Int) -> String {
            let source = pairs >= ContextSize.minimumPairs ? "calibrated from \(count(pairs, "pair"))"
                : "default; \(count(pairs, "measured pair")) of \(ContextSize.minimumPairs) needed"
            return "\(String(format: "%.1f", value)) \(script) (\(source))"
        }
        return "≈ sizes use k = characters per token: " + k(calibration.latin, "Latin", calibration.latinPairs) + ", "
            + k(calibration.cyrillic, "Cyrillic", calibration.cyrillicPairs) + "."
    }

    /// `3 (12%)`, with Pi's reads of the skill after it.
    static func modelCalls(_ skill: StatsReport.SkillStats) -> String {
        var text = "\(skill.modelCalls) (\(Int((skill.callRate * 100).rounded()))%)"
        if skill.piModelCalls > 0 { text += " + Pi \(skill.piModelCalls)" }
        return text
    }

    /// The local day of an ISO 8601 time.
    static func day(_ iso: String) -> String {
        (try? Date(iso, strategy: .iso8601)).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? iso
    }

    /// `3 sessions`, `1 day`, `10,980 requests`.
    static func count(_ n: Int, _ noun: String) -> String { "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")" }

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
        return "≈ \(ContextSize.short(evidence.approxContextSpace)) context space · listed with its description in \(count(evidence.sessions, "session")) on "
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
    /// The commit's message, and the projects to set up again (none for keep_auto).
    let onDone: (String, [String]) -> Void
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
                Text("It takes effect after these are set up again: \(projects.joined(separator: ", ")). After Commit, the screen lists them; Plan… opens a project's setup.")
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
                await model.refresh()
                onDone("Committed “\(patch.change.message(skill: patch.item.skill, layer: patch.layer))”.", isManual ? projects : [])
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Install Capture…: what `akit insights install` would write and run, one part at a time, and
/// only the checked parts are set up. A part said no to in `akit setup` starts unchecked.
struct CaptureInstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onDone: (String) -> Void
    @State private var plans: [CaptureInstaller.PartPlan]?
    /// The parts on this Mac now.
    @State private var installed: [CaptureInstaller.Part] = []
    @State private var checked: Set<CaptureInstaller.Part> = []
    @State private var busy = false
    /// What went wrong while installing; the sheet stays open to show it.
    @State private var failures: [String] = []
    /// Set when the plans changed since they were shown (say, akit setup ran meanwhile).
    @State private var changed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install Session Capture").font(.title2.bold())
            Text("Records each new Claude Code and Pi session as it starts (its folder, log path and git state, never message text) and imports the logs every hour, so sessions are counted before their folders or logs are gone. Nothing changes until you click Install.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let plans {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(plans) { part($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                .frame(height: 320)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            } else {
                ProgressView("Checking Claude Code, Pi and launchd…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            if changed {
                Label("Something changed on this Mac since the list was made. Check it again, then Install.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(failures, id: \.self) { failure in
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(failures.isEmpty ? "Cancel" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                if failures.isEmpty {
                    Button("Install", action: install)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || plans == nil || checked.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 640)
        // The Claude plugin lives in the brain: planned again once it is loaded.
        .task(id: model.brain?.root) {
            let brain = model.brain?.root
            let (plans, status) = await Task.detached {
                let installer = Self.installer(brain: brain)
                return (await installer.partPlans(), await installer.status())
            }.value
            checked = Set(plans.filter { $0.suggested && !$0.plan.isEmpty }.map(\.part))
            installed = CaptureInstaller.installedParts(status)
            self.plans = plans
        }
    }

    @ViewBuilder
    private func part(_ item: CaptureInstaller.PartPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if item.plan.isEmpty {
                let on = installed.contains(item.part)
                Label(Self.title(item.part) + (on ? "" : ": not set up"), systemImage: on ? "checkmark.circle" : "minus.circle")
                    .foregroundStyle(item.plan.refused.isEmpty ? .secondary : Color.orange)
                    .font(.headline)
            } else {
                Toggle(Self.title(item.part), isOn: Binding(
                    get: { checked.contains(item.part) },
                    set: { if $0 { checked.insert(item.part) } else { checked.remove(item.part) } }))
                    .font(.headline)
                    .disabled(busy)
            }
            Text(item.plan.isEmpty ? (item.plan.notes + item.plan.refused).joined(separator: "\n") : item.plan.text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The app is not the akit command: the hourly import runs ~/.local/bin/akit, or is refused without it.
    nonisolated static func installer(brain: URL?) -> CaptureInstaller {
        CaptureInstaller(env: .current, brainRoot: brain, akitExecutable: nil)
    }

    nonisolated static func title(_ part: CaptureInstaller.Part) -> String {
        switch part {
        case .claude: "Claude Code plugin"
        case .pi: "Pi extension"
        case .launchd: "Hourly import"
        }
    }

    private func install() {
        guard let plans else { return }
        let chosen = plans.filter { checked.contains($0.part) && !$0.plan.isEmpty }
        let leftOut = plans.filter { !checked.contains($0.part) && !$0.plan.isEmpty }.map(\.part)
        let brain = model.brain?.root
        busy = true
        changed = false
        Task {
            let result: InstallResult? = await Task.detached {
                let installer = Self.installer(brain: brain)
                // Runs only what the sheet shows: plans made again now must say the same.
                let now = await installer.partPlans()
                guard now.map(\.plan.text) == plans.map(\.plan.text) else { return nil }
                var result = InstallResult()
                // Each part's plan as shown; a part that stops doesn't keep the next from running.
                for item in chosen {
                    do {
                        let problems = try await installer.execute(item.plan, trash: Trash.move)
                        result.problems += problems
                        if problems.isEmpty { result.done.append(item.part) }
                    } catch {
                        result.problems.append("\(Self.title(item.part)): \(error.localizedDescription)")
                    }
                }
                do {
                    try installer.saveInstalled(result.done, leftOut: leftOut)
                } catch {
                    result.problems.append("Couldn't save the answer in ~/.akit: \(error.localizedDescription)")
                }
                return result
            }.value
            guard let result else {
                busy = false
                changed = true
                self.plans = nil
                let brain = model.brain?.root
                let (plans, status) = await Task.detached {
                    let installer = Self.installer(brain: brain)
                    return (await installer.partPlans(), await installer.status())
                }.value
                checked = Set(plans.filter { $0.suggested && !$0.plan.isEmpty }.map(\.part))
                installed = CaptureInstaller.installedParts(status)
                self.plans = plans
                return
            }
            // The Claude plugin is committed in the brain: the rescan shows it there.
            await model.refresh()
            busy = false
            let names = result.done.map(Self.title).joined(separator: ", ")
            if result.problems.isEmpty {
                onDone("Session capture is set up: \(names).")
                dismiss()
            } else {
                failures = result.problems
                if !result.done.isEmpty { onDone("Session capture is set up for \(names); the rest had problems.") }
            }
        }
    }

    private struct InstallResult: Sendable {
        var done: [CaptureInstaller.Part] = []
        var problems: [String] = []
    }
}

/// Add Mark…: a change made by hand (a plugin turned off, settings edited), so Changes measures
/// the sessions before and after it. Writes one spool line, as `akit stats mark`.
struct AddMarkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onDone: (String) -> Void
    @State private var note = ""
    @State private var date = Date()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Mark").font(.title2.bold())
            Text("Describe a change you made outside AKit. Changes compares the first-request context of the sessions before and after this time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Note", text: $note, prompt: Text("Disabled the marketing plugin"))
            DatePicker("When", selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Mark", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func add() {
        do {
            let text = try Spool.mark(note, at: date, home: HarnessEnvironment.current.homeDirectory)
            onDone("Marked \(date.formatted(date: .abbreviated, time: .shortened)): \(text).")
            dismiss()
        } catch {
            self.error = error.message
        }
    }
}

extension ChangesReport.Change {
    /// One change in the list: its time, kind and project or note.
    var key: String { "\(date.timeIntervalSince1970)|\(anchor)|\(project ?? note ?? "")" }
}
