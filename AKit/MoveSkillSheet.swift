import AKitBrain
import AKitFoundation
import AKitInsights
import AKitProjectSetup
import AppKit
import SwiftUI

/// Move to Project…: a global skill into the projects that use it, so its description leaves
/// every other session (docs/design/layers.md, "Move a skill to a project"). Projects → checks
/// → preview by place → the outcome of each place.
struct MoveSkillSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The skill's folder name, as the brain and layers call it.
    let name: String

    private enum Page { case choose, check, preview, done }

    /// One project the skill can move to.
    struct Row: Identifiable {
        let id: String
        let folder: URL?
        let isSetUp: Bool
        /// The project's choice now: its saved answer, else this Mac's role; nil for a new project.
        let currentLocalOnly: Bool?
        let calls: Int
        let lastCall: String?
        var ticked: Bool
        var localOnly: Bool
        var keepOwn = false

        var title: String { id.split(separator: "/").last.map(String.init) ?? id }
    }

    @State private var page = Page.choose
    @State private var rows: [Row] = []
    @State private var calls: SkillCallsReport?
    @State private var loaded = false
    @State private var mode = LayerSkill.Mode.auto
    @State private var modeReason = ""
    @State private var keepGlobal = false
    @State private var plan: SkillMove.Plan?
    @State private var outcome: SkillMove.Outcome?
    @State private var failure: String?
    @State private var isWorking = false
    @State private var error: String?
    @State private var selected: String?
    /// Compare / Show Edits: the texts shown under the checks.
    @State private var comparison: (title: String, old: String, new: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch page {
            case .choose: choose
            case .check: check
            case .preview: preview
            case .done: done
            }
        }
        .padding(16)
        .frame(width: 780, height: 640)
        .task { await load() }
    }

    // MARK: - Projects

    private var choose: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move “\(name)” to Projects").font(.title2.bold())
            Text("The skill leaves the core layer and this Mac's home folder, so other sessions stop paying for its description. It goes through the brain into each project's answers; a local-only project gets it in every git worktree, later ones too.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !loaded {
                ProgressView("Reading the skill's calls…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if rows.isEmpty {
                        Text("No projects known on this Mac yet. Add a projects folder in Settings, or set one up on the Brain screen.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($rows) { $row in projectRow($row) }
                }
                .listStyle(.bordered)
                .frame(maxHeight: .infinity)
                chooseWarnings
                HStack(spacing: 16) {
                    Picker("Mode", selection: $mode) {
                        Text("auto").tag(LayerSkill.Mode.auto)
                        Text("manual").tag(LayerSkill.Mode.manual)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("auto: the agent sees it and may use it; manual: only on /\(name)")
                    Text(modeReason).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Keep it global too", isOn: $keepGlobal)
                        .help("Only copy it into the projects: the core layer and the home folder keep it")
                }
            }
            HStack {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isWorking ? "Checking…" : "Check") { Task { await makePlan(then: .check) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!rows.contains(where: \.ticked) || isWorking)
            }
        }
    }

    private func projectRow(_ row: Binding<Row>) -> some View {
        let value = row.wrappedValue
        return HStack(spacing: 10) {
            Toggle(isOn: row.ticked) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(value.title).fontWeight(.medium)
                        if value.folder == nil { Tag(text: "not on this Mac", tint: .secondary) }
                        if value.folder != nil && !value.isSetUp { Tag(text: "not set up", tint: .secondary) }
                    }
                    Text(value.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(callsText(value)).font(.caption).foregroundStyle(value.calls > 0 ? .primary : .secondary)
            Picker("Project files", selection: row.localOnly) {
                Text("Commit").tag(false)
                Text("Local Only").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(!value.ticked || value.folder == nil)
            .help(filesHelp(value))
        }
        .padding(.vertical, 2)
    }

    private func callsText(_ row: Row) -> String {
        guard row.calls > 0 else { return "no calls" }
        return "\(row.calls) call\(row.calls == 1 ? "" : "s")" + (row.lastCall.map { " · last \(Self.day($0))" } ?? "")
    }

    private func filesHelp(_ row: Row) -> String {
        switch row.currentLocalOnly {
        case true?: "Its choice now: Local only (AKit's files hidden from git, linked into its worktrees)"
        case false?: "Its choice now: Commit to git"
        case nil: "A new project: Local only keeps the moved skill out of its git"
        }
    }

    @ViewBuilder
    private var chooseWarnings: some View {
        let missed = rows.filter { !$0.ticked && $0.calls > 0 }
        let unbound = (calls?.unbound?.calls ?? 0) + (calls?.otherMacs.outsideProjects ?? 0)
        let ticked = rows.filter(\.ticked).count
        VStack(alignment: .leading, spacing: 4) {
            ForEach(missed) { row in
                Label("\(row.title) called it \(row.calls) time\(row.calls == 1 ? "" : "s") but is not ticked: it won't have \(name).",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if unbound > 0 {
                Label("\(unbound) call\(unbound == 1 ? "" : "s") in sessions bound to no project: those sessions won't have \(name) after the move.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if ticked >= 3 {
                Label("\(ticked) projects: a layer may suit \(name) better (Brain → New Layer…). Moving still works.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    // MARK: - Checks

    private var check: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Checks").font(.title2.bold())
            if let plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if plan.canApply && plan.warnings.isEmpty {
                            Label("Nothing stops the move.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        ForEach(plan.blockers, id: \.self) { blocker in
                            Label(blocker, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                        ForEach(plan.edits, id: \.path) { edit in
                            Button("Show Edits: \(edit.path)") {
                                comparison = ("The brain's copy → \(edit.path)", edit.brainText ?? "", edit.copyText ?? "")
                            }
                            .buttonStyle(.link)
                        }
                        ForEach(plan.parts) { part in partCheck(part) }
                        ForEach(plan.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        ForEach(plan.notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle").foregroundStyle(.secondary)
                        }
                        if let comparison {
                            GroupBox(comparison.title) {
                                VStack(alignment: .leading, spacing: 0) {
                                    DiffPreview(diff: TextDiff.lines(from: comparison.old, to: comparison.new))
                                }
                                .font(.callout.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(4)
                            }
                        }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3) }
                Spacer()
                Button("Back") { page = .choose; comparison = nil }.keyboardShortcut(.cancelAction)
                Button("Preview") { page = .preview }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(plan?.canApply ?? false) || isWorking)
            }
        }
    }

    @ViewBuilder
    private func partCheck(_ part: SkillMove.Part) -> some View {
        switch part.state {
        case .blocked(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("\(part.id): \(reason)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                if let own = part.ownFolder {
                    HStack(spacing: 12) {
                        Button("Compare") { compare(own: own, part: part) }
                        Button("Keep the Project's") { keepOwn(part.id) }
                            .help("Leave the project's own \(name) as it is and only take \(name) out of core")
                    }
                    .padding(.leading, 24)
                }
            }
        case .answersOnly:
            Label("\(part.id) is not on this Mac: only its answers get \(name).", systemImage: "info.circle").foregroundStyle(.secondary)
        case .keepOwn:
            Label("\(part.id) keeps its own \(name); nothing is written there.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .add:
            EmptyView()
        }
    }

    private func compare(own: URL, part: SkillMove.Part) {
        let mine = (try? String(contentsOf: own.appending(path: "SKILL.md"), encoding: .utf8)) ?? ""
        let global = plan?.source.flatMap { try? String(contentsOf: $0.realFile, encoding: .utf8) }
            ?? model.brain?.skills.first { $0.name == name }.flatMap { try? String(contentsOf: $0.file, encoding: .utf8) } ?? ""
        comparison = ("The global \(name) → \(part.id)'s own", global, mine)
    }

    private func keepOwn(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].keepOwn = true
        comparison = nil
        Task { await makePlan(then: .check) }
    }

    // MARK: - Preview

    /// One line of the preview, with what it shows on the right.
    private struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let tint: Color
        var old = ""
        var new = ""
        var hasDiff = false
    }

    private func sections(_ plan: SkillMove.Plan) -> [(title: String, items: [Item])] {
        let home = HarnessEnvironment.current.homeDirectory
        var sections: [(String, [Item])] = []
        if plan.brainImport != nil, let source = plan.source {
            sections.append(("Brain", [Item(id: "brain", title: "skills/\(name)", detail: "copied from \(SkillMove.shown(source.folder, home: home)), in no layer",
                                            tint: .green)]))
        } else {
            sections.append(("Brain", [Item(id: "brain", title: "skills/\(name)", detail: "already in the brain", tint: .secondary)]))
        }
        for part in plan.parts where part.state == .add || part.state == .keepOwn || part.state == .answersOnly {
            var items: [Item] = []
            if part.state == .answersOnly {
                items.append(Item(id: "\(part.id):answers", title: "answers only", detail: "not on this Mac: Set Up Project on its Mac renders \(name)",
                                  tint: .secondary))
            } else if part.state == .keepOwn {
                items.append(Item(id: "\(part.id):own", title: "keeps its own \(name)", detail: "nothing is written", tint: .secondary))
            } else {
                for change in part.changes where change.kind != .same {
                    items.append(Item(id: "\(part.id):\(change.path)", title: change.path, detail: change.kind == .create ? "new" : "changed",
                                      tint: change.kind == .create ? .green : .blue, old: change.oldText ?? "", new: change.newText ?? "",
                                      hasDiff: change.oldText != nil || change.newText != nil))
                }
                if part.isPresent { items.append(Item(id: "\(part.id):present", title: "already there", detail: "only the answers change", tint: .secondary)) }
                let files = part.localOnly ? "Local only (hidden from git)" : "Commit to git"
                items.append(Item(id: "\(part.id):files", title: files, detail: part.isNew ? "first set up, with only this skill" : "\(name) added to its answers",
                                  tint: .secondary))
                if !part.worktrees.isEmpty {
                    items.append(Item(id: "\(part.id):worktrees", title: "links into \(part.worktrees.count) worktree\(part.worktrees.count == 1 ? "" : "s")",
                                      detail: part.worktrees.map(\.tildePath).joined(separator: ", "), tint: .secondary))
                }
                let waiting = part.plan?.changes.filter { part.excluded.contains($0.path) && $0.kind != .same }.count ?? 0
                if waiting > 0 {
                    items.append(Item(id: "\(part.id):waiting", title: "\(waiting) other pending change\(waiting == 1 ? "" : "s")",
                                      detail: "left for Set Up Project", tint: .secondary))
                }
            }
            sections.append(("Project \(part.id)", items))
        }
        if let edit = plan.coreEdit {
            sections.append(("Core layer", [Item(id: "core", title: "layers/core/layer.yaml", detail: "\(name) taken out, committed after the projects",
                                                 tint: .blue, old: edit.before, new: edit.after, hasDiff: true)]))
        }
        if !plan.keepGlobal {
            var items: [Item] = []
            let homeChanges = plan.home?.changes.filter { plan.homePaths.contains($0.path) } ?? []
            for change in homeChanges {
                items.append(Item(id: "home:\(change.path)", title: "~/\(change.path)", detail: "to the Trash", tint: .red,
                                  old: change.oldText ?? "", new: "", hasDiff: change.oldText != nil))
            }
            for url in plan.trashSource {
                items.append(Item(id: "trash:\(url.path)", title: SkillMove.shown(url, home: home), detail: "to the Trash", tint: .red))
            }
            for copy in plan.extraCopies {
                items.append(Item(id: "extra:\(copy.id)", title: SkillMove.shown(copy.folder, home: home), detail: "another copy, to the Trash", tint: .red))
            }
            if items.isEmpty { items.append(Item(id: "home", title: "nothing to remove", detail: "no global copy on this Mac", tint: .secondary)) }
            sections.append(("Home folder", items))
        } else {
            sections.append(("Home folder", [Item(id: "home", title: "kept", detail: "Keep it global too", tint: .secondary)]))
        }
        return sections.map { (title: $0.0, items: $0.1) }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Move “\(name)”").font(.title2.bold())
            if let plan {
                let sections = sections(plan)
                HSplitView {
                    List(selection: $selected) {
                        ForEach(sections, id: \.title) { section in
                            Section(section.title) {
                                ForEach(section.items) { item in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                        Text(item.detail).font(.caption).foregroundStyle(item.tint).lineLimit(2)
                                    }
                                    .tag(item.id)
                                }
                            }
                        }
                    }
                    .listStyle(.bordered)
                    .frame(minWidth: 300, idealWidth: 340, maxHeight: .infinity)
                    diff(sections.flatMap(\.items).first { $0.id == selected })
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3) }
                Spacer()
                Button("Back") { page = .check }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(isWorking ? "Moving…" : "Move", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(plan?.canApply ?? false) || isWorking)
            }
        }
    }

    @ViewBuilder
    private func diff(_ item: Item?) -> some View {
        if let item, item.hasDiff {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DiffPreview(diff: TextDiff.lines(from: item.old, to: item.new))
                }
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        } else if let item {
            ContentUnavailableView(item.title, systemImage: "info.circle", description: Text(item.detail))
        } else {
            ContentUnavailableView("Select a change", systemImage: "doc.text")
        }
    }

    // MARK: - Done

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure {
                Label("The move stopped", systemImage: "exclamationmark.triangle.fill").font(.title2.bold()).foregroundStyle(.orange)
                Text(failure).textSelection(.enabled)
            } else {
                Label("\(name) is moved", systemImage: "checkmark.circle.fill").font(.title2.bold()).foregroundStyle(.green)
            }
            if let outcome {
                VStack(alignment: .leading, spacing: 6) {
                    Label(outcome.imported ? "Brain: copied into skills/\(name)" : "Brain: skills/\(name) was there", systemImage: "brain")
                    ForEach(outcome.projects, id: \.id) { project in
                        Label("\(project.id): \(project.outcome.written.count) written" + (project.outcome.notes.isEmpty ? "" : ". " + project.outcome.notes.joined(separator: " ")),
                              systemImage: "folder")
                    }
                    if !outcome.answersSaved.isEmpty {
                        Label("Answers only (other Macs): \(outcome.answersSaved.joined(separator: ", "))", systemImage: "doc.text")
                    }
                    if outcome.coreChanged { Label("Core layer: \(name) taken out", systemImage: "square.stack.3d.up") }
                    if let home = outcome.home { Label("Home folder: \(home.removed.count) file\(home.removed.count == 1 ? "" : "s") to the Trash", systemImage: "house") }
                    if !outcome.trashed.isEmpty { Label("To the Trash: \(outcome.trashed.joined(separator: ", "))", systemImage: "trash") }
                    ForEach(outcome.notes, id: \.self) { Label($0, systemImage: "info.circle") }
                }
                .textSelection(.enabled)
            }
            if failure == nil, let plan, !plan.keepGlobal {
                Text("Reload skills in running sessions (e.g. /reload-skills). On your other Macs, Brain → Sync offers Update Home Folder; each project there needs its own Apply.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Work

    private func load() async {
        guard !loaded else { return }
        let report = await model.skillCalls(name)
        let store = model.projectStore
        let folders = model.brainProjectFolders.filter { !$0.key.hasPrefix("home/") }
        var ids = Set(folders.keys)
        ids.formUnion((model.brain?.projects ?? []).filter { !$0.isHome }.map(\.id))
        ids.formUnion(report?.projects.compactMap(\.project) ?? [])
        ids.formUnion(report?.otherMacs.projects.map(\.project) ?? [])
        var made: [Row] = []
        for id in ids {
            let saved = ProjectRecords.savedAnswers(id: id, in: store)
            let here = report?.projects.first { $0.project == id }
            let count = report?.calls(in: id) ?? 0
            let current = saved.map { $0.isLocalOnly(store: store) }
            made.append(Row(id: id, folder: folders[id], isSetUp: saved != nil, currentLocalOnly: current, calls: count,
                            lastCall: here?.lastCall, ticked: count > 0, localOnly: current ?? true))
        }
        rows = made.sorted { ($1.calls, $0.title.lowercased()) < ($0.calls, $1.title.lowercased()) }
        calls = report
        let modelCalls = (report?.projects.reduce(0) { $0 + $1.modelCalls } ?? 0) + (report?.otherMacs.modelCalls ?? 0)
        if modelCalls > 0 {
            mode = .auto
            modeReason = "auto: the model called it \(modelCalls) time\(modelCalls == 1 ? "" : "s") in 30 days"
        } else if let brain = model.brain {
            mode = SkillMove.currentMode(name, brain: brain, installed: model.skills)
            modeReason = "\(mode.rawValue): as it is now (no model calls in 30 days)"
        }
        loaded = true
        // Snapshots: `--tab move-check` and `--tab move-preview` go on by themselves (with every
        // project ticked when none called it).
        if let tab = DebugSnapshot.options?.tab, tab == "move-check" || tab == "move-preview" {
            if !rows.contains(where: \.ticked), !rows.isEmpty {
                for index in rows.indices where rows[index].folder != nil { rows[index].ticked = true; break }
            }
            await makePlan(then: tab == "move-preview" ? .preview : .check)
        }
    }

    private func makePlan(then next: Page) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        let targets = rows.filter(\.ticked).map { row in
            // The project's own choice stays unless it was changed here.
            SkillMove.Target(id: row.id, folder: row.folder, localOnly: row.localOnly == row.currentLocalOnly ? nil : row.localOnly,
                             keepOwn: row.keepOwn)
        }
        guard let made = await model.moveSkillPlan(name: name, targets: targets, mode: mode, keepGlobal: keepGlobal) else {
            error = "The brain is not loaded."
            return
        }
        plan = made
        // The first change with a diff: the first project's skill file, else core's layer.yaml.
        selected = sections(made).flatMap(\.items).first(where: \.hasDiff)?.id
        page = next == .preview && !made.canApply ? .check : next
    }

    private func apply() {
        guard let plan else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                outcome = try await model.moveSkill(plan)
                failure = nil
            } catch let stopped as SkillMove.Failure {
                outcome = stopped.outcome
                failure = stopped.message
            } catch {
                self.error = error.localizedDescription
                return
            }
            page = .done
        }
    }

    /// `2026-10-09` from an ISO 8601 time.
    static func day(_ iso: String) -> String {
        guard let date = try? Date(iso, strategy: .iso8601) else { return iso }
        return date.formatted(.iso8601.year().month().day())
    }
}

private struct Tag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
