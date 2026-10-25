import AKitFoundation
import AKitReview
import AppKit
import SwiftUI

/// Review screen: AI review of GitLab merge requests (`docs/design/review.md`). AKit gathers
/// the context, Pi proposes findings, and nothing reaches GitLab until you approve it here.
struct ReviewView: View {
    enum Page: String, CaseIterable {
        case runs, roles, scenarios, quality
        var title: String { rawValue.capitalized }
    }

    @Environment(AppModel.self) private var app
    @Environment(ReviewModel.self) private var model
    /// Snapshots: `--tab roles|scenarios|quality|settings`.
    @State private var page = DebugSnapshot.options?.tab.flatMap(Page.init(rawValue:)) ?? .runs
    @State private var showNew = DebugSnapshot.options?.add == true && DebugSnapshot.options?.tab != "settings"
    @State private var showSettings = DebugSnapshot.options?.tab == "settings"
    /// The running review's live log under its status bar.
    @State private var showDetails = false

    var body: some View {
        @Bindable var model = model
        // The bars stand above the page, not in a safe-area inset: the runs page's HSplitView
        // ignores the inset, and the bar covered the top of the run list.
        VStack(spacing: 0) {
            if let activity = model.activity {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text((activity.lines.last ?? activity.title).trimmingCharacters(in: .whitespaces)).lineLimit(1)
                        Spacer()
                        Button(showDetails ? "Hide Details" : "Details") { showDetails.toggle() }
                            .help("Everything the review did so far: each pass, the files it reads, the MCP tools it calls, the model's answers")
                        Button("Stop") { model.stop() }
                            .help("End the running pass. What is done so far stays in the run.")
                    }
                    if showDetails {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 1) {
                                    ForEach(Array(activity.lines.enumerated()), id: \.offset) { offset, line in
                                        let index = activity.dropped + offset
                                        Text(line).font(.caption.monospaced())
                                            .foregroundStyle(line.hasSuffix(" failed") || line.contains(" failed:") || line.contains("model error:")
                                                             ? Color.red
                                                             : line.hasPrefix("  ") ? Color.secondary : Color.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .id(index)
                                    }
                                }
                                .textSelection(.enabled)
                            }
                            .frame(height: 180)
                            .onChange(of: activity.dropped + activity.lines.count) { proxy.scrollTo(activity.dropped + activity.lines.count - 1, anchor: .bottom) }
                            .onAppear { proxy.scrollTo(activity.dropped + activity.lines.count - 1, anchor: .bottom) }
                        }
                    }
                }
                .font(.callout)
                .padding(8)
                .background(.blue.opacity(0.08))
                .overlay(alignment: .bottom) { Divider() }
            }
            ForEach(Array(model.alerts.enumerated()), id: \.offset) { index, alert in
                HStack {
                    Label(alert, systemImage: "exclamationmark.triangle.fill").textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.alerts.remove(at: index) }
                }
                .font(.callout)
                .padding(8)
                .background(.yellow.opacity(0.18))
                .overlay(alignment: .bottom) { Divider() }
            }
            if let problem = model.problem {
                HStack {
                    Label(problem, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.problem = nil }
                }
                .font(.callout)
                .padding(8)
                .background(.orange.opacity(0.15))
                .overlay(alignment: .bottom) { Divider() }
            }
            Group {
                switch page {
                case .runs: runs
                case .roles: ReviewConfigView(kind: .role, brain: app.brainRoot)
                case .scenarios: ReviewConfigView(kind: .scenario, brain: app.brainRoot)
                case .quality: ReviewQualityView()
                }
            }
            .frame(maxHeight: .infinity)
        }
        .alert(model.capQuestion?.title ?? "Review it now?", isPresented: Binding(get: { model.capQuestion != nil }, set: { if !$0 { model.answerCap(false) } }),
               presenting: model.capQuestion) { question in
            Button("Run Anyway") { model.answerCap(true) }
            Button("Stop", role: .cancel) { model.answerCap(false) }
        } message: { question in
            Text(question.message)
        }
        .navigationTitle("Review")
        .navigationSubtitle(page == .runs ? (model.runs.count == 1 ? "1 run" : "\(model.runs.count) runs") : page.title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Show", selection: $page) {
                    ForEach(Page.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Runs: your reviews. Roles and Scenarios: what a review checks, from the brain or a project. Quality: how often you approve what each role finds.")
            }
            ToolbarItem {
                Button("New Review…", systemImage: "plus") { showNew = true }
                    .disabled(model.isBusy)
                    .help("Review a merge request (Pi reads it through its MCP servers, you approve what goes to GitLab) or a local workspace")
            }
            ToolbarItem {
                Button("Review Settings…", systemImage: "gearshape") { showSettings = true }
                    .help("Pi's MCP servers as review uses them, and the project profiles")
            }
            ToolbarItem {
                GuideButton(guide: .review)
            }
        }
        .sheet(isPresented: Binding(get: { showNew || model.again != nil }, set: { if !$0 { showNew = false; model.again = nil } })) {
            NewReviewSheet(brain: app.brainRoot, again: model.again)
        }
        .sheet(isPresented: $showSettings) { ReviewSettingsSheet(brain: app.brainRoot) }
    }

    private var runs: some View {
        @Bindable var model = model
        return HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
            Group {
                if let run = model.run {
                    ReviewRunDetail(run: run).id(run.id)
                } else {
                    ContentUnavailableView {
                        Label("Review", systemImage: "checklist")
                    } description: {
                        Text("An agent reads a GitLab merge request with its work items and proposes comments. You approve each one; only then does AKit add it to your pending review in GitLab, where you publish it with Submit review.")
                    } actions: {
                        Button("New Review…") { showNew = true }
                        Button("Review Settings…") { showSettings = true }
                    }
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { model.reload(select: DebugSnapshot.options?.select) }
    }

    private var list: some View {
        List(model.runs, selection: Binding(get: { model.run?.id }, set: { model.open($0) })) { run in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(run.spec.label).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    ReviewStageBadge(status: run.status)
                }
                Text("\(run.spec.scenario.value.capitalized) · \(run.spec.roles.map(\.id).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(run.spec.created, format: .dateTime.day().month().hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .tag(run.id)
            .contextMenu {
                Button("Review Again…") { model.again = run.spec }
                    .disabled(model.isBusy)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ReviewPaths(home: model.home).run(run.id)]) }
                Button("Move to Trash", role: .destructive) { model.delete(run.id) }
                    .disabled(model.activity?.runID == run.id)
            }
        }
        .overlay {
            if model.runs.isEmpty {
                ContentUnavailableView("No reviews yet", systemImage: "checklist",
                                       description: Text("New Review… with a merge request address or a local workspace, or akit review MR-URL / akit review local . in a terminal."))
            }
        }
    }
}

struct ReviewStageBadge: View {
    let status: ReviewRunStatus?

    var body: some View {
        let (text, color): (String, Color) = switch status?.stage {
        case .gathering: ("Gathering", .blue)
        case .gathered: ("Gathered", .secondary)
        case .estimating, .passes: ("Passes", .blue)
        case .planned: ("Ready", .green)
        case .failed: ("Failed", .red)
        case .stopped: ("Stopped", .orange)
        case nil: ("?", .secondary)
        }
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .help(status?.message ?? text)
    }
}

/// One run: what ran, the requests waiting for you, what stays in AKit, the gaps.
struct ReviewRunDetail: View {
    @Environment(ReviewModel.self) private var model
    let run: ReviewWorkflow.Run
    @State private var showSend = false
    @State private var showMissed = false
    /// Snapshots: `--tab log` opens it.
    @State private var showLog = DebugSnapshot.options?.tab == "log"
    /// Translate of the brief, the overview and the requests; what goes to GitLab stays the original.
    @State private var translator = Translator()
    /// The requests or the map. Snapshots: `--tab map`.
    @State private var tab: Tab = DebugSnapshot.options?.tab == "map" ? .map : .requests
    /// `overview.json` and `map.json`, read (the map maybe built) off the main thread.
    @State private var overview: ReviewOverview?
    @State private var map: ReviewMap?
    @State private var mapLoaded = false
    /// What the review missed in the knowledge base, read with the overview.
    @State private var knowledgeGaps: [ReviewKnowledgeGap] = []

    enum Tab: String, CaseIterable {
        case requests = "Requests", map = "Map"
    }

    /// What the overview and the map show: they are read again when the findings change.
    private var filesKey: String {
        "\(run.id)|\(run.status?.stage.rawValue ?? "")|\(run.findings?.version ?? 0)|\(run.findings?.created.timeIntervalSince1970 ?? 0)"
    }

    private var requests: [ReviewRequest] { run.plan?.requests ?? [] }
    private var approved: [ReviewRequest] { requests.filter { $0.decision == .approved && !$0.isSent } }

    var body: some View {
        // The actions stand under the scroll view, not in a safe-area inset: in the HSplitView the
        // cards scrolled under and below the bar.
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    discussBanner
                    if let message = run.status?.message, run.status?.stage == .failed || run.status?.stage == .stopped {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let brief = run.passes?.brief {
                        DisclosureGroup("Brief") {
                            Text(translator.text(ReviewWorkflow.Run.TranslationKey.brief, brief)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let overview {
                        ReviewOverviewSection(overview: overview, translator: translator) { translate }
                    }
                    Picker("Show", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Requests: what AKit wants to write to GitLab. Map: what the change touches, its boundaries and the other repositories that use them.")
                    switch tab {
                    case .requests:
                        requestsSection
                        onlyInAKit
                        hiddenFindings(.preExisting, title: "Before this MR",
                                       help: "Problems already there before this merge request: not the author's change. Make a task of its own for them.")
                    case .map:
                        mapSection(proxy)
                    }
                    gaps
                    ReviewKnowledgeGapsSection(gaps: knowledgeGaps, run: run.id,
                                               base: run.spec.knowledgeBasePath.map { URL(filePath: $0, directoryHint: .isDirectory) })
                    missed
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                if DebugSnapshot.options != nil { print("review: detail \(Int(width)) wide, content \(Int(width) - 40)") }
            }
            }
            actions
        }
        .sheet(isPresented: $showSend) { SendDraftsSheet(run: run, approved: approved) }
        .sheet(isPresented: $showLog) { ReviewRunLogSheet(folder: run.folder) }
        .task(id: run.id) {
            // Discuss in Pi… writes into the run folder from a terminal: look every few seconds.
            while !Task.isCancelled {
                model.checkDiscuss()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .sheet(isPresented: $showMissed) { AddMissedSheet(files: run.snapshot?.diffs.map(\.newPath) ?? []) }
        .task(id: filesKey) {
            let folder = run.folder
            let found = await Task.detached {
                (ReviewOverview.load(folder: folder), ReviewMap.load(folder: folder), ReviewKnowledgeGaps.read(run: folder))
            }.value
            overview = found.0
            map = found.1
            knowledgeGaps = found.2
            mapLoaded = true
        }
    }

    /// The run's one Translate menu (the brief, the overview, the requests) and its note: on the
    /// overview when there is one, else over the requests.
    @ViewBuilder private var translate: some View {
        let run = run
        HStack(spacing: 8) {
            TranslationNote(translator: translator)
            TranslateMenu(translator: translator, id: run.id) { run.translationSource }
                .controlSize(.small)
        }
    }

    @ViewBuilder private func mapSection(_ proxy: ScrollViewProxy) -> some View {
        if let map {
            ReviewMapView(map: map, run: run) { finding in
                guard let request = requests.first(where: { $0.findingID == finding }) else { return }
                tab = .requests
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    withAnimation { proxy.scrollTo("request:\(request.id)", anchor: .top) }
                }
            }
        } else if mapLoaded {
            VStack(alignment: .leading, spacing: 8) {
                Text("No map for this run").font(.headline)
                Text("A run made before the map, whose worktree is gone, has none. Review Again… makes a new run with one.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Review Again…") { model.again = run.spec }
                    .disabled(model.isBusy)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private var discussBanner: some View {
        if model.pendingDiscuss > 0 {
            HStack {
                Label("Pi sent \(model.pendingDiscuss) change\(model.pendingDiscuss == 1 ? "" : "s") from the discussion.", systemImage: "bubble.left.and.text.bubble.right")
                Spacer()
                Button("Make New Version") { model.applyDiscuss() }
                    .help("Apply them as a new version of the findings; the requests are planned again and wait for your approval")
            }
            .padding(10)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        if let changes = model.discussChanges {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Version \(changes.version) of the findings").fontWeight(.medium)
                    Spacer()
                    Button("Dismiss") { model.discussChanges = nil }
                }
                if changes.isEmpty { Text("Nothing changed.").foregroundStyle(.secondary) }
                ForEach(changes.added, id: \.self) { Text("New: \($0)").font(.callout) }
                ForEach(changes.changed, id: \.self) { Text("Changed: \($0)").font(.callout) }
            }
            .padding(10)
            .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        if let place = model.discussOpenedIn {
            Text("Discuss in Pi… opened in \(place). Changes Pi submits there show up here.").font(.caption).foregroundStyle(.secondary)
        }
        if let notice = model.evalNotice {
            Text(notice).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.snapshot?.mergeRequest.title ?? run.spec.mergeRequest.label).font(.title2.weight(.semibold)).textSelection(.enabled)
                Spacer()
                ReviewStageBadge(status: run.status)
            }
            if let local = run.spec.local {
                Text("\(local.path) · \(local.branch) · \(local.base.prefix(10))..\(local.head.prefix(10))"
                     + (local.uncommitted.isEmpty ? "" : " (the last commit is a snapshot of the uncommitted changes)")).font(.callout.monospaced())
                    .foregroundStyle(.secondary).textSelection(.enabled)
                Text(local.mode.title + ": " + local.summary + ". A local review stays in AKit: nothing goes to GitLab.")
                    .font(.callout).foregroundStyle(.secondary)
                if !local.commits.isEmpty {
                    DisclosureGroup("Commits (\(local.commits.count))") {
                        ForEach(local.commits) { commit in
                            Text("\(commit.sha.prefix(10))  \(commit.date)  \(commit.author): \(commit.subject)").font(.callout.monospaced())
                                .lineLimit(1).textSelection(.enabled)
                        }
                    }
                    .font(.callout)
                }
            } else if let url = URL(string: run.spec.mergeRequest.url) {
                HStack(spacing: 6) {
                    Link(run.spec.mergeRequest.label + (run.spec.headSHA.map { " at \($0.prefix(10))" } ?? ""), destination: url).font(.callout)
                    if let since = run.spec.since {
                        Text("from commit \(since.asked)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                ForEach(run.spec.linked ?? [], id: \.key) { change in
                    HStack(spacing: 6) {
                        Text("Linked").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if let link = URL(string: change.mergeRequest.url) {
                            Link(change.mergeRequest.label + (change.headSHA.map { " at \($0.prefix(10))" } ?? ""), destination: link).font(.callout)
                        }
                        Text(change.headSHA == nil ? "not read: see the gaps"
                             : "files @\(change.key)/…" + (change.since.map { ", from commit \($0.asked)" } ?? ""))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 14) {
                Label(run.spec.scenario.value.capitalized, systemImage: "list.bullet.rectangle")
                    .help("Scenario (from \(run.spec.scenario.source.rawValue))")
                Label(run.spec.roles.map(\.id).joined(separator: ", "), systemImage: "person.2")
                    .help("Roles of this run, each a SKILL.md")
                if let passes = run.passes {
                    Label(String(format: "%.1f of %d credits", passes.credits, run.spec.capCredits.value)
                          + (passes.cost.map { " · " + ReviewRunLog.dollars($0) } ?? ""), systemImage: "gauge")
                        .help(String(format: "Recorded by Pi: 1 credit = 1,000 tokens (cached reads count a tenth). Estimated before the passes: %.0f.",
                                     passes.estimate ?? 0)
                              + " Dollars: what Pi recorded from its model list; on a subscription that may not be what you pay.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            runContext
            if let passes = run.passes, !passes.passes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(passes.passes, id: \.name) { pass in
                        Label(pass.name, systemImage: pass.error == nil ? (pass.ended == nil ? "circle.dotted" : "checkmark.circle") : "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(pass.error == nil ? Color.secondary : Color.red)
                            .help(pass.error ?? String(format: "%@ · %.1f credits · %@ · read %d files", pass.model.isEmpty ? "Pi's default model" : pass.model,
                                                       pass.credits, ReviewRunLog.dollars(pass.usage.cost), pass.paths.count))
                    }
                    Button("Log…") { showLog = true }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("What the run did: each pass's model, thinking, time, tokens and credits, the MCP calls, and what each role's findings became")
                    Button("Review Again…") { model.again = run.spec }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(model.isBusy)
                        .help("Start a new review of the same change with this run's scenario, notes, links and models. It reads the whole change again.")
                }
            }
        }
    }

    /// What the user added to this run: notes, links, context servers.
    @ViewBuilder private var runContext: some View {
        let context = (run.spec.mcpServers ?? []).filter(\.readOnly)
        if !context.isEmpty {
            Label("Context servers (read only): " + context.map { "\($0.name) (\($0.source == .run ? "this run" : "profile"))" }.joined(separator: ", "),
                  systemImage: "server.rack")
                .font(.callout).foregroundStyle(.secondary)
        }
        if let notes = run.spec.notes {
            DisclosureGroup("Context for this review") {
                Text(notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        }
        if let links = run.spec.links, !links.isEmpty {
            let unread = Set(run.spec.linksUnread ?? [])
            DisclosureGroup("Links (\(links.count - unread.count) of \(links.count) read)") {
                ForEach(links, id: \.self) { link in
                    HStack {
                        Image(systemName: unread.contains(link) ? "xmark.circle" : "checkmark.circle")
                            .foregroundStyle(unread.contains(link) ? .orange : .green)
                        if let url = URL(string: link) { Link(link, destination: url).lineLimit(1) } else { Text(link) }
                    }
                }
                Text("What Pi read is in context/links.md; a link it couldn't read is a context gap.").font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    @ViewBuilder private var requestsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Requests").font(.headline)
                Text("Nothing goes to GitLab until you approve it.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if overview == nil { translate }
            }
            if run.plan == nil {
                Text(run.status?.stage == .planned || run.findings != nil ? "No plan yet." : "The requests appear when the passes are done.")
                    .foregroundStyle(.secondary)
            } else if requests.isEmpty {
                Text("No requests: GitLab already has everything AKit would write.").foregroundStyle(.secondary)
            }
            ForEach(requests) { request in
                ReviewRequestCard(run: run, request: request,
                                  shownText: translator.text(ReviewWorkflow.Run.TranslationKey.request(request.id), request.text))
                    .id("request:\(request.id)")
            }
        }
    }

    @ViewBuilder private var onlyInAKit: some View {
        hiddenFindings(.onlyInAKit, title: "Only in AKit", help: nil)
    }

    /// Findings of one place that don't go to GitLab, each with its reason and Move Inline.
    @ViewBuilder private func hiddenFindings(_ place: ReviewPlacement.Place, title: String, help: String?) -> some View {
        let hidden = (run.plan?.placements ?? []).filter { $0.place == place }
        if !hidden.isEmpty {
            DisclosureGroup("\(title) (\(hidden.count))") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(hidden, id: \.findingID) { placement in
                        if let finding = run.finding(placement.findingID) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(finding.title).fontWeight(.medium)
                                    Text("\(finding.file.map { "\($0)\(finding.line.map { ":\($0)" } ?? "")" } ?? "No line") · \(finding.role) · \(finding.finalSeverity.rawValue) · "
                                         + String(format: "%.2f", finding.finalConfidence))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(placement.reason).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if run.spec.local == nil {
                                    Button("Expect in Eval Set") { model.addToEvalSet(findings: [finding.id]) }
                                        .help("Add this run to the eval set with this finding as one a good review must report (the filter missed it here)")
                                }
                                Button("Move Inline") { model.moveInline(finding) }
                                    .help("Make it an inline draft anyway; AKit learns that its filter missed it (missed-by-filter)")
                                    .disabled(finding.file == nil)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .help(help ?? "")
        }
    }

    @ViewBuilder private var gaps: some View {
        if !run.gaps.isEmpty {
            DisclosureGroup("Context gaps (\(run.gaps.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(run.gaps) { gap in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(gap.needed)").fontWeight(.medium)
                            Text("\(gap.why)" + (gap.howToGet.isEmpty ? "" : " — \(gap.howToGet)")).font(.caption).foregroundStyle(.secondary)
                            Text("\(gap.system) · reported by \(gap.reportedBy)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder private var missed: some View {
        if !run.missed.isEmpty {
            DisclosureGroup("Missed by the reviewer (\(run.missed.count))") {
                ForEach(run.missed) { item in
                    Text((item.file.map { "\($0)\(item.line.map { ":\($0)" } ?? ""): " } ?? "") + item.text).font(.callout)
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button("Add Missed…") { showMissed = true }
                .help("Something the reviewer should have found: it improves the roles, never goes to GitLab")
            if run.spec.local == nil, run.findings != nil, run.spec.headSHA != nil {
                let approved = (run.plan?.requests ?? []).filter { $0.decision == .approved && $0.findingID != nil }.count
                Menu("Add to Eval Set") {
                    Button("With the Approved Findings (\(approved))") { model.addToEvalSet() }
                        .disabled(approved == 0)
                    Button("As Clean: Nothing to Find") { model.addToEvalSet(clean: true) }
                }
                .fixedSize()
                .help("Keep this merge request, pinned at its commit, to check later reviews against: the findings a good review must report, or none. Review → Quality lists the set.")
            }
            if run.spec.local == nil, run.snapshot != nil {
                Button("Sync Outcomes") { model.syncOutcomes(run.id) }
                    .disabled(model.isBusy)
                    .help("Read this merge request's threads again (one small pass) and record what became of each 🤖 comment: fixed, dismissed, ignored or open. Review → Quality shows the numbers.")
            }
            Button("Discuss in Pi…") { model.discuss() }
                .help("Open Pi in a terminal with the whole review (a fork of the verifier's session). What it submits becomes a new version here.")
                .disabled(run.passes?.verifierSession == nil && run.passes == nil)
            // A run left mid-way when AKit quit still says gathering or passes: nothing runs it now.
            let interrupted = [.gathering, .estimating, .passes].contains(run.status?.stage) && model.activity?.runID != run.id
            if run.status?.stage == .gathered || run.status?.stage == .failed || run.status?.stage == .stopped || interrupted {
                Button("Run Passes") { model.runPasses(run.id) }
                    .disabled(model.isBusy)
                    .help("Run the brief, the roles and the verifier on the gathered context")
            }
            Spacer()
            Text("\(approved.count) approved").foregroundStyle(.secondary)
            if run.spec.local == nil {
                Button("Send Drafts…") { showSend = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(approved.isEmpty)
                    .help("Add the approved requests to your pending review in GitLab as drafts. You publish them there with Submit review.")
            }
        }
        .padding(10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

/// One request: what AKit wants to write, where, and your decision.
struct ReviewRequestCard: View {
    @Environment(ReviewModel.self) private var model
    let run: ReviewWorkflow.Run
    let request: ReviewRequest
    /// The text as shown: translated or the original. Edit and GitLab use the original.
    var shownText: String? = nil
    @State private var text = ""
    @State private var editing = false
    @State private var reason: ReviewRequest.Reason?
    @State private var comment = ""

    private var finding: ReviewFinding? { run.finding(request.findingID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(kindTitle).font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(kindColor.opacity(0.15), in: Capsule()).foregroundStyle(kindColor)
                if let file = request.file {
                    Text(file + (request.line.map { ":\($0)" } ?? "")).font(.callout.monospaced()).textSelection(.enabled)
                }
                Spacer()
                if let role = request.role { Text(role).font(.caption).foregroundStyle(.secondary) }
                if let severity = request.severity { Text(severity.rawValue).font(.caption.weight(.medium)) }
                if let confidence = request.confidence { Text(String(format: "%.2f", confidence)).font(.caption).foregroundStyle(.secondary) }
                state
            }
            if let file = request.file, let line = request.line, let code = run.code(around: line, in: file) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(code, id: \.number) { row in
                        Text(String(format: "%5d  ", row.number) + row.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(row.number == line ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(row.number == line ? Color.yellow.opacity(0.15) : .clear)
                    }
                }
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            if editing {
                TextEditor(text: $text)
                    .font(.callout)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            } else {
                Text(shownText ?? request.text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let verdict = finding?.verifier {
                Text("Verifier: \(verdict.verdict.rawValue)" + (verdict.note.isEmpty ? "" : " — \(verdict.note)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !request.isSent, request.sent?.error == nil, request.kind != .delete,
               !ReviewLanguage.isCzech(request.text, marker: run.spec.posting.marker.value) {
                Label("Not in Czech: Send won't send it. AKit sends only Czech comments to GitLab; edit it into Czech.",
                      systemImage: "character.bubble").font(.caption).foregroundStyle(.orange)
            }
            if let error = request.sent?.error {
                Label("GitLab: \(error)", systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if !request.isSent { buttons }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(request.decision == .approved ? Color.green.opacity(0.6) : Color.secondary.opacity(0.25)))
    }

    @ViewBuilder private var state: some View {
        if request.isSent {
            Label("Sent", systemImage: "paperplane.fill").font(.caption).foregroundStyle(.green)
        } else if request.decision == .approved {
            Label(request.edited == nil ? "Approved" : "Approved, edited", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        } else if request.decision == .rejected {
            Label("Rejected" + (request.reason.map { ": \($0.title)" } ?? ""), systemImage: "xmark.circle").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            if editing {
                Button("Done") {
                    model.decide(request, request.decision == .rejected ? .pending : request.decision, edited: text)
                    editing = false
                }
                Button("Cancel") { editing = false }
            } else {
                Button("Edit") {
                    text = request.text
                    editing = true
                }
                .disabled(request.kind == .delete)
                .help("Change the text before it goes to GitLab; the change is kept to improve the roles")
            }
            Spacer()
            if request.findingID != nil {
                Menu("Reject") {
                    ForEach(ReviewRequest.Reason.allCases, id: \.self) { reason in
                        Button(reason.title) { model.decide(request, .rejected, reason: reason) }
                    }
                }
                .fixedSize()
                .help("Not worth sending. The reason goes into the quality numbers of the role")
            } else {
                Button("Reject") { model.decide(request, .rejected) }
            }
            Button(request.decision == .approved ? "Undo Approve" : "Approve") {
                model.decide(request, request.decision == .approved ? .pending : .approved)
            }
            .help("Approved requests go to GitLab with Send Drafts…")
        }
    }

    private var kindTitle: String {
        switch request.kind {
        case .create: "New comment"
        case .update: "Update draft"
        case .delete: "Delete draft"
        case .summary: request.draftID == nil ? "Summary" : "Update summary"
        case .reply: "Reply: looks fixed"
        }
    }

    private var kindColor: Color {
        switch request.kind {
        case .create, .summary: .blue
        case .update: .purple
        case .delete: .red
        case .reply: .teal
        }
    }
}
