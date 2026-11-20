import AKitFoundation
import AKitLab
import AKitModel
import AKitSessions
import AppKit
import SwiftUI

/// Error Analysis → Agent Reports (docs/design/agent-reports.md): the sections an agent writes at
/// the end of each task (Pi's Agent decisions, Autonomy improvements, Unknown unknowns), gathered
/// from every session of a period on this Mac; Summarize sends only those sections to a Pi model
/// under the sending policy and keeps its report in `~/.akit/lab/agent-reports`.
@MainActor
@Observable
final class AgentReportsModel {
    enum Source: String, CaseIterable {
        case pi = "Pi", claude = "Claude Code", both = "Both"

        var harnesses: Set<HarnessID> {
            switch self {
            case .pi: [.pi]
            case .claude: [.claudeCode]
            case .both: [.pi, .claudeCode]
            }
        }
    }

    enum Pane: String, CaseIterable { case found = "Found", report = "Report", saved = "Saved" }

    enum Period: String, CaseIterable {
        case today = "Today", yesterday = "Yesterday", week = "Last 7 Days", twoWeeks = "Last 14 Days", month = "Last 30 Days"
        case thisMonth = "This Month", custom = "Custom"
    }

    /// A usual period sets From and To; Custom shows them.
    var period = Period.week {
        didSet {
            switch period {
            case .today: setPeriod(days: 0)
            case .yesterday: setPeriod(days: nil, yesterday: true)
            case .week: setPeriod(days: 7)
            case .twoWeeks: setPeriod(days: 14)
            case .month: setPeriod(days: 30)
            case .thisMonth: setPeriod(days: nil, startOfMonth: true)
            case .custom: break
            }
        }
    }
    var from = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: .now)) ?? .now
    var to = Date.now
    var source = Source.pi
    /// One section per line, other spellings after `|`; remembered between launches.
    var sectionsText = UserDefaults.standard.string(forKey: "agentReportsSections") ?? AgentReports.text(of: AgentReports.defaultSections) {
        didSet { UserDefaults.standard.set(sectionsText, forKey: "agentReportsSections") }
    }
    var language = LabLanguage(rawValue: UserDefaults.standard.string(forKey: "agentReportsLanguage") ?? "") ?? .english {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "agentReportsLanguage") }
    }
    var thinking = UserDefaults.standard.string(forKey: "agentReportsThinking") ?? AgentReports.defaultThinking {
        didSet { UserDefaults.standard.set(thinking, forKey: "agentReportsThinking") }
    }
    /// "" is the default model.
    var model = UserDefaults.standard.string(forKey: "agentReportsModel") ?? "" {
        didSet { UserDefaults.standard.set(model, forKey: "agentReportsModel") }
    }
    /// Optional: what the summary should look at first ("flaky tests and CI").
    var focus = ""
    var pane = Pane.allCases.first { $0.rawValue.lowercased() == DebugSnapshot.options?.select?.lowercased() } ?? .found
    var filter = ""

    private(set) var availableModels: [String] = []
    private(set) var collection: AgentReports.Collection?
    private(set) var reading = false
    private(set) var summarizing = false
    private(set) var progress: String?
    private(set) var saved: [AgentReportStore.Saved] = []
    /// The report on the Report pane: the last summary or a saved one.
    private(set) var shown: (file: URL, markdown: String)?

    var sections: [AgentReports.Section] { AgentReports.sections(fromText: sectionsText) }
    var readKey: String { "\(from.timeIntervalSince1970) \(to.timeIntervalSince1970) \(source.rawValue) \(sectionsText)" }
    var defaultModel: String? { AgentReports.defaultModel(available: availableModels) }
    var plan: AgentReports.Plan? { collection.map(AgentReports.plan) }

    private var store: AgentReportStore { AgentReportStore(env: .current) }

    func loadModels() async {
        guard availableModels.isEmpty else { return }
        availableModels = await LabRuns.models(for: .pi, env: .current)
    }

    /// A preset period, up to now.
    func setPeriod(days: Int?, startOfMonth: Bool = false, yesterday: Bool = false) {
        let calendar = Calendar.current, today = calendar.startOfDay(for: .now)
        if yesterday {
            from = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            to = today.addingTimeInterval(-60)
        } else if startOfMonth {
            from = calendar.dateInterval(of: .month, for: .now)?.start ?? today
            to = .now
        } else {
            from = calendar.date(byAdding: .day, value: -(days ?? 0), to: today) ?? today
            to = .now
        }
    }

    /// Reads the period's sessions on this Mac (nothing is sent).
    func read(_ all: [SessionSummary]) async {
        let key = readKey, from = from, to = to, harnesses = source.harnesses, sections = sections
        guard from < to, !sections.isEmpty else {
            collection = nil
            return
        }
        reading = true
        let found = await Task.detached {
            AgentReports.collect(AgentReports.sessions(all, from: from, to: to, harnesses: harnesses), from: from, to: to, sections: sections)
        }.value
        // The period changed while reading: a newer read follows.
        guard key == readKey else { return }
        (collection, reading) = (found, false)
    }

    /// Summarize: the reports with items go to the model; the report is saved and shown.
    func summarize() async throws(AgentReports.Failure) -> String {
        guard let collection, !summarizing else { return "" }
        summarizing = true
        defer { (summarizing, progress) = (false, nil) }
        let note: @Sendable (String) -> Void = { text in Task { @MainActor in self.progress = text } }
        let summary = try await AgentReports.summarize(collection, model: model, thinking: thinking, language: language,
                                                       focus: focus, env: .current, progress: note)
        let file: URL
        do { file = try store.save(summary) } catch {
            throw AgentReports.Failure(message: "The report came back but couldn't be saved: \(error.localizedDescription)")
        }
        loadSaved()
        shown = (file, summary.markdown)
        pane = .report
        return "Report of \(collection.withItems.count) reports by \(summary.model) in \(summary.calls) call\(summary.calls == 1 ? "" : "s"), saved as \(file.lastPathComponent)."
    }

    /// Reads the saved reports; the newest is on the Report pane until another one is opened.
    func loadSaved() {
        saved = store.list()
        if shown == nil, let newest = saved.first, let text = try? String(contentsOf: newest.file, encoding: .utf8) {
            shown = (newest.file, text)
        }
    }

    func open(_ report: AgentReportStore.Saved) {
        guard let text = try? String(contentsOf: report.file, encoding: .utf8) else { return }
        shown = (report.file, text)
        pane = .report
    }

    /// The Markdown of what was found, as `akit reports --markdown` prints it.
    var foundMarkdown: String { collection.map(AgentReports.markdown) ?? "" }
}

struct AgentReportsTab: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = analysis.agentReports
        @Bindable var bound = model
        HSplitView {
            AgentReportsSettings(model: model)
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            VStack(spacing: 0) {
                HStack {
                    Picker("Show", selection: $bound.pane) {
                        ForEach(AgentReportsModel.Pane.allCases, id: \.self) { pane in
                            Text(title(pane, model)).tag(pane)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    if model.pane == .found {
                        TextField("Filter", text: $bound.filter)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                        Button("Copy as Markdown", systemImage: "doc.on.doc") { copy(model.foundMarkdown) }
                            .disabled(model.collection?.reports.isEmpty ?? true)
                            .help("Every item by section with its time, project and session, as Markdown; nothing is sent")
                    } else if model.pane == .report, let shown = model.shown {
                        Button("Copy", systemImage: "doc.on.doc") { copy(shown.markdown) }
                            .help("The report's Markdown")
                        Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([shown.file]) }
                    }
                }
                .padding(10)
                Divider()
                switch model.pane {
                case .found: AgentReportsFound(model: model)
                case .report: report(model)
                case .saved: savedList(model)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.loadModels() }
        .task { model.loadSaved() }
        // A short pause first: dragging through a date picker reads once, at the end.
        .task(id: "\(model.readKey) \(app.sessions.count)") {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await model.read(app.sessions)
        }
    }

    private func title(_ pane: AgentReportsModel.Pane, _ model: AgentReportsModel) -> String {
        switch pane {
        case .found: model.collection.map { "Found (\($0.reports.count))" } ?? "Found"
        case .report: "Report"
        case .saved: model.saved.isEmpty ? "Saved" : "Saved (\(model.saved.count))"
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder
    private func report(_ model: AgentReportsModel) -> some View {
        if let shown = model.shown {
            ScrollView {
                MarkdownText(text: AgentReportsTab.body(of: shown.markdown), large: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No report yet", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Summarize writes one report of the period's sections with a Pi model; Saved lists the earlier ones."))
        }
    }

    /// The report without its front matter.
    static func body(of markdown: String) -> String {
        guard markdown.hasPrefix("---\n"), let end = markdown.range(of: "\n---\n", range: markdown.index(markdown.startIndex, offsetBy: 4)..<markdown.endIndex) else {
            return markdown
        }
        return String(markdown[end.upperBound...]).trimmingCharacters(in: .newlines)
    }

    @ViewBuilder
    private func savedList(_ model: AgentReportsModel) -> some View {
        if model.saved.isEmpty {
            ContentUnavailableView("No saved reports", systemImage: "tray",
                                   description: Text("Each Summarize keeps its report in ~/.akit/lab/agent-reports."))
        } else {
            List(model.saved) { saved in
                Button { model.open(saved) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(saved.from) – \(saved.to)").font(.headline).monospacedDigit()
                        Text("\(saved.reports) reports · \(saved.model) · written \(saved.created)").font(.caption).foregroundStyle(.secondary)
                        if !saved.focus.isEmpty {
                            Text("Focus: \(saved.focus)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved.file]) }
                }
            }
        }
    }
}

/// The left column, kept simple: the period, an optional focus and Summarize; whose sessions,
/// which sections and the model wait under More Options.
private struct AgentReportsSettings: View {
    let model: AgentReportsModel
    @Environment(AnalysisModel.self) private var analysis
    @State private var more = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Period", selection: $model.period) {
                    ForEach(AgentReportsModel.Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .help("Which days to read, up to now; Custom sets From and To with day and time")
                if model.period == .custom {
                    DatePicker("From", selection: $model.from, in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("To", selection: $model.to, in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                }
            } footer: {
                Text(found).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                TextField("Focus", text: $model.focus, prompt: Text("Optional: what to look at first"), axis: .vertical)
                    .lineLimit(1...4)
                    .help("Optional, as “where the agent lacked access”: the report opens with a Focus section and puts what bears on it first")
                HStack {
                    Button {
                        Task {
                            do { analysis.message = try await model.summarize() } catch { analysis.error = error.localizedDescription }
                        }
                    } label: {
                        Text("Summarize").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled((model.plan?.reports ?? 0) == 0 || model.summarizing || model.reading)
                    .help("One short report of these reports by a Pi model; it is kept under Saved")
                    if model.summarizing { ProgressView().controlSize(.small) }
                }
                if model.summarizing, let progress = model.progress {
                    Text(progress).font(.callout).foregroundStyle(.secondary)
                }
            } footer: {
                Text(sending).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                DisclosureGroup("More Options", isExpanded: $more) {
                    Picker("Sessions", selection: $model.source) {
                        ForEach(AgentReportsModel.Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .help("Whose saved sessions to read: Pi's (it writes these sections), Claude Code's or both")
                    Picker("Language", selection: $model.language) {
                        ForEach(LabLanguage.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .help("The report's language; English unless you choose another")
                    Picker("Thinking", selection: $model.thinking) {
                        ForEach(LabHarness.pi.efforts, id: \.self) { Text($0).tag($0) }
                    }
                    .help("Pi's thinking level for the model (default low)")
                    PiModelPicker(selection: $model.model, models: WorkLogFill.offered(model.availableModels),
                                  empty: "Default (\(model.defaultModel ?? (model.availableModels.isEmpty ? "reading the list…" : "none")))",
                                  help: "Pi's models (pi --list-models); GitHub Copilot's when Pi has them", allowsOther: false) {
                        Text("Model")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sections")
                        TextEditor(text: $model.sectionsText)
                            .font(.callout.monospaced())
                            .frame(minHeight: 70, maxHeight: 110)
                            .help("One heading per line; other spellings of it after |, as “Unknown unknowns | Неизвестные факторы”. A heading counts when it is bold, a Markdown heading or starts a line with a colon")
                        Button("Reset to Pi's Sections") { model.sectionsText = AgentReports.text(of: AgentReports.defaultSections) }
                            .disabled(model.sectionsText == AgentReports.text(of: AgentReports.defaultSections))
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Snapshots: `--add` opens More Options.
        .onAppear { if DebugSnapshot.options?.add == true { more = true } }
    }

    private var found: String {
        if model.from >= model.to { return "From must be before To." }
        if model.sections.isEmpty { return "Name at least one section under More Options." }
        guard let collection = model.collection, !model.reading else { return "Reading the sessions…" }
        let count = { (n: Int, noun: String) in "\(n) \(noun)\(n == 1 ? "" : "s")" }
        return "\(count(collection.reports.count, "report")) in \(collection.sessionsWithReports) of \(count(collection.sessionsRead, "session"))."
    }

    private var sending: String {
        guard let plan = model.plan, plan.reports > 0 else { return "Nothing to summarize: no report with more than “none”." }
        let target = model.model.isEmpty ? (model.defaultModel ?? "Pi's default model") : model.model
        let cost = SendLog.estimate(characters: plan.characters, purpose: AgentReports.purpose, calls: plan.calls, harness: .pi,
                                    model: target, records: SendLog.records(env: .current))
            .flatMap { $0 >= 0.005 ? String(format: " (≈ $%.2f)", $0) : nil } ?? ""
        return "Sends only what the agent wrote in these sections, never a whole session, to \(target)\(cost)."
    }
}

/// The Found pane: each section's items with when, where and in which session; a click opens the session.
private struct AgentReportsFound: View {
    let model: AgentReportsModel
    @Environment(AppModel.self) private var app

    var body: some View {
        if let collection = model.collection, !model.reading {
            if collection.reports.isEmpty {
                ContentUnavailableView("No reports in this period", systemImage: "doc.text.magnifyingglass",
                                       description: Text("\(collection.sessionsRead) sessions read; none has a message with these sections. Choose a longer period, other sessions or other sections."))
            } else {
                List {
                    ForEach(collection.sections, id: \.name) { section in
                        let items = collection.items(of: section.name).filter { matches($0.item, $0.report) }
                        let count = collection.count(section.name)
                        Section {
                            if items.isEmpty {
                                Text(model.filter.isEmpty ? "none" : "nothing matches").foregroundStyle(.secondary)
                            }
                            // Ids unique across sections: List reuses rows by id, and offsets repeat.
                            ForEach(items.indices.map { "\(section.name)#\($0)" }, id: \.self) { id in
                                let found = items[Int(id.split(separator: "#").last ?? "") ?? 0]
                                row(found.item, found.report)
                            }
                        } header: {
                            Text("\(section.name) · \(count.items) in \(count.withItems) of \(count.reports) reports")
                        }
                    }
                }
            }
        } else {
            ProgressView("Reading the period's sessions…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func matches(_ item: String, _ report: AgentReports.Report) -> Bool {
        let filter = model.filter.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty else { return true }
        return [item, report.project, report.title].contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    private func row(_ item: String, _ report: AgentReports.Report) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("\(AgentReports.stamp(report.time)) · \(report.project) · \(report.title)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(report.task.map { "Task: \($0)" } ?? report.session)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Show Session") {
                app.revealSession = SessionReveal(path: report.session, step: 0)
                app.section = .sessions
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item, forType: .string)
            }
        }
    }
}
