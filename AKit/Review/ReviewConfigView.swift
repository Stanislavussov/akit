import AKitFoundation
import AKitLab
import AKitReview
import SwiftUI

/// Review → Roles and Scenarios: every role or scenario with its source (built-in, brain,
/// project), Edit…, Duplicate to Project…, Reset to Brain, Delete…, Write with AI… and the
/// skills it links (`docs/design/review.md`, R9–R10, R17).
struct ReviewConfigView: View {
    @Environment(ReviewModel.self) private var model
    let kind: ReviewConfigEditor.Kind
    let brain: URL
    @State private var catalog: ReviewCatalog?
    /// nil = the brain; else a project profile's slug.
    @State private var project: String? = DebugSnapshot.options?.project
    @State private var selection: String? = DebugSnapshot.options?.select
    @State private var text = ""
    @State private var save: ReviewConfigEditor.Save?
    @State private var showNew = false
    /// Snapshots: `--tab roles --add` opens Write with AI….
    @State private var showWriter = DebugSnapshot.options?.add == true && (DebugSnapshot.options?.tab == "roles" || DebugSnapshot.options?.tab == "scenarios")
    @State private var removal: ReviewConfigEditor.Removal?
    /// Snapshots: `--tab roles|scenarios --select ID --capture` opens Delete… for it.
    @State private var snapshotDelete = DebugSnapshot.options?.capture == true
    @State private var message: String?

    struct Item: Identifiable, Hashable {
        let id: String
        let title: String
        let detail: String
        let source: ReviewSource
        let text: String
    }

    private var profile: ReviewProfile? { project.flatMap { slug in catalog?.profiles.first { $0.slug == slug } } }

    private var items: [Item] {
        guard let catalog else { return [] }
        switch kind {
        case .role:
            return catalog.roles(for: profile).map { Item(id: $0.id, title: $0.id, detail: $0.description, source: $0.source, text: $0.text) }
        case .scenario, .defaults:
            var list = catalog.scenarios(for: profile).map {
                Item(id: $0.id, title: $0.title, detail: "Roles: " + ($0.required + $0.optional.map { "\($0)?" }).joined(separator: ", "),
                     source: $0.source, text: $0.text)
            }
            if project == nil {
                let file = ReviewConfigEditor.file(.defaults, id: "", level: .brain, home: model.home, brain: brain)
                let brainText = try? String(contentsOf: file, encoding: .utf8)
                list.append(Item(id: "review.yaml", title: "Defaults (review.yaml)", detail: "Models, thresholds, the inline cap, the credit cap",
                                 source: brainText == nil ? .builtIn : .brain, text: brainText ?? ReviewBuiltIns.defaultsYAML + "\n"))
            }
            return list
        case .profile:
            return []
        }
    }

    private var selected: Item? { items.first { $0.id == selection } }
    private var hasBuiltIns: Bool { (catalog?.roles ?? []).contains { $0.source == .builtIn } || (catalog?.scenarios ?? []).contains { $0.source == .builtIn } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("Level", selection: $project) {
                    Text("Brain").tag(String?.none)
                    ForEach(catalog?.profiles ?? [], id: \.slug) { Text("Project: \($0.project)").tag(Optional($0.slug)) }
                }
                .padding(8)
                .help("Brain: the generic \(kind == .role ? "roles" : "scenarios") of every project. A project: what that project sees, its own copies on top")
                List(items, selection: $selection) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.title).fontWeight(.medium)
                            Spacer()
                            ReviewSourceBadge(source: item.source)
                        }
                        Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .tag(item.id)
                }
                HStack {
                    Button("New \(kind == .role ? "Role" : "Scenario")…") { showNew = true }
                    Button("Write with AI…") { showWriter = true }
                        .help(kind == .role ? "Describe the role; Pi writes it with a writing skill you pick. You see the diff before it is saved"
                              : "Describe the problem the scenario solves; Pi picks the roles and skills and writes it. You see the diff before it is saved")
                    Spacer()
                    if hasBuiltIns, project == nil {
                        Button("Add to Brain") { addBuiltIns() }
                            .help("Write the built-in roles, scenarios and defaults into the brain layer review, so you can edit them there (committed)")
                    }
                }
                .padding(8)
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)
            editor
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { reload() }
        .onChange(of: selection) { text = selected?.text ?? "" }
        .onChange(of: project) {
            reload()
            text = selected?.text ?? ""
        }
        .sheet(item: Binding(get: { save.map { SaveBox(save: $0) } }, set: { save = $0?.save })) { box in
            ReviewSaveSheet(save: box.save, brain: brain) { done in
                save = nil
                if done { reload() }
            }
        }
        .sheet(item: Binding(get: { removal.map { RemovalBox(removal: $0) } }, set: { removal = $0?.removal })) { box in
            ReviewDeleteSheet(removal: box.removal, brain: brain, catalog: catalog) { done in
                removal = nil
                if done {
                    selection = nil
                    reload()
                }
            }
        }
        .sheet(isPresented: $showWriter) {
            ReviewRoleWriterSheet(kind: kind, brain: brain, level: level, roleIDs: items.map(\.id)) { written in
                save = written
                selection = written.id
            }
        }
        .sheet(isPresented: $showNew) {
            ReviewNewItemSheet(kind: kind) { id in
                let template = kind == .role ? ReviewTemplates.role(id) : ReviewTemplates.scenario(id)
                plan(id: id, text: template)
            }
        }
    }

    @ViewBuilder private var editor: some View {
        if let item = selected {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(item.title).font(.title3.weight(.semibold))
                    ReviewSourceBadge(source: item.source)
                    Spacer()
                }
                Text(sourceText(item)).font(.caption).foregroundStyle(.secondary)
                if item.id != "review.yaml" { skillsRow }
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                if let message { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                HStack {
                    if let slug = project {
                        if item.source == .project {
                            Button("Reset to Brain") { reset(item, slug: slug) }
                                .help("Move the project's own copy to the Trash: the brain's applies again")
                        } else if item.id != "review.yaml" {
                            Button("Duplicate to Project…") { duplicate(item, slug: slug) }
                                .help("Make a copy only this project uses; it stays on this Mac (~/.akit/local)")
                        }
                    }
                    if canDelete(item) {
                        Button("Delete…", role: .destructive) { planDelete(item) }
                            .help(project == nil
                                  ? "Move it to the Trash with every project's copy\(kind == .scenario ? " and the roles only it uses" : ""); you see the list first"
                                  : "Move this project's own \(kind.rawValue) to the Trash; you see the list first")
                    }
                    Spacer()
                    Button("Revert") { text = item.text }.disabled(text == item.text)
                    Button("Save…") { plan(id: item.id == "review.yaml" ? "" : item.id, text: text) }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(text == item.text)
                        .help(project == nil ? "Show the change, then save it in the brain (committed)" : "Show the change, then save the project's copy")
                }
            }
            .padding(16)
        } else {
            ContentUnavailableView("Pick a \(kind == .role ? "role" : "scenario")", systemImage: kind == .role ? "person.2" : "list.bullet.rectangle",
                                   description: Text(kind == .role
                                                     ? "A role is a SKILL.md with an akit-review: block: its checklist, what not to comment on, how many findings, from which severity."
                                                     : "A scenario names the roles a review runs and what it checks. The defaults set models, thresholds and the caps."))
        }
    }

    /// The skills the text links now (`skills:`), with Link Skill and a × per skill. Both change
    /// the text only; Save… shows the diff.
    @ViewBuilder private var skillsRow: some View {
        let linked = linkedSkills
        HStack(spacing: 6) {
            Text("Skills:").font(.callout).foregroundStyle(.secondary)
            if linked.isEmpty { Text("none").font(.callout).foregroundStyle(.tertiary) }
            ForEach(linked, id: \.self) { name in
                let known = catalog?.skills.contains { $0.name == name } ?? false
                HStack(spacing: 3) {
                    Text(name).font(.caption.weight(.medium))
                    if !known { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption2) }
                    Button { setSkills(linked.filter { $0 != name }) } label: { Image(systemName: "xmark").font(.caption2) }
                        .buttonStyle(.borderless)
                        .help("Unlink \(name)")
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .help(known ? "Every pass of a run with this \(kind.rawValue) loads \(name)" : "No skill \(name) on this Mac: a run here goes without it")
            }
            Menu("Link Skill") {
                let free = (catalog?.skills ?? []).filter { !linked.contains($0.name) }
                if free.isEmpty { Text("No other skill on this Mac") }
                ForEach(free) { skill in
                    Button(skill.name + "  (" + skill.place + ")") { setSkills(linked + [skill.name]) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Link a skill from the brain, ~/.claude/skills, ~/.pi/agent/skills or ~/.agents/skills: the review passes load it with this \(kind.rawValue)")
            Spacer()
        }
    }

    private var linkedSkills: [String] {
        switch kind {
        case .role: (try? ReviewRole.parse(text, source: .brain))?.skills ?? []
        case .scenario: (try? ReviewScenario.parse(text, source: .brain))?.skills ?? []
        default: []
        }
    }

    private func setSkills(_ names: [String]) {
        do {
            text = try ReviewSkillLinks.setting(names, kind: kind, in: text)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    /// The brain deletes any role or scenario; a project only its own ones the brain lacks.
    private func canDelete(_ item: Item) -> Bool {
        guard item.id != "review.yaml", let catalog else { return false }
        guard project != nil else { return true }
        let inBrain = kind == .role ? catalog.roles.contains { $0.id == item.id } : catalog.scenarios.contains { $0.id == item.id }
        return item.source == .project && !inBrain
    }

    private func planDelete(_ item: Item) {
        guard let catalog else { return }
        do {
            removal = try ReviewConfigEditor.planDelete(kind, id: item.id, level: level, catalog: catalog, home: model.home, brain: brain)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func sourceText(_ item: Item) -> String {
        switch item.source {
        case .builtIn: "Built into AKit. Edit it to save it into the brain, or Add to Brain first."
        case .brain: "From the brain layer review: every project on every Mac uses it."
        case .project: "This project's own copy, only on this Mac."
        case .run: "Set for one run."
        }
    }

    private var level: ReviewConfigEditor.Level { project.map { .project($0) } ?? .brain }

    private func reload() {
        catalog = model.catalog(brain: brain)
        message = catalog?.problems.first
        if selection == nil { selection = items.first?.id }
        text = selected?.text ?? ""
        if snapshotDelete, let item = selected {
            snapshotDelete = false
            planDelete(item)
        }
    }

    private func plan(id: String, text: String) {
        do {
            let itemKind: ReviewConfigEditor.Kind = id.isEmpty ? .defaults : kind
            save = try ReviewConfigEditor.plan(itemKind, id: id, text: text, level: level, home: model.home, brain: brain)
            message = nil
            selection = id.isEmpty ? "review.yaml" : id
        } catch {
            message = error.localizedDescription
        }
    }

    private func duplicate(_ item: Item, slug: String) {
        guard let catalog else { return }
        do {
            save = try ReviewConfigEditor.duplicate(kind, id: item.id, toProject: slug, catalog: catalog, home: model.home, brain: brain)
        } catch {
            message = error.localizedDescription
        }
    }

    private func reset(_ item: Item, slug: String) {
        do {
            try ReviewConfigEditor.resetToBrain(kind, id: item.id, project: slug, home: model.home, brain: brain)
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func addBuiltIns() {
        Task {
            do {
                let written = try await ReviewConfigEditor.addBuiltIns(brain: brain, env: model.env)
                message = written.isEmpty ? "The brain has them all already." : nil
                reload()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private struct SaveBox: Identifiable {
        let save: ReviewConfigEditor.Save
        var id: String { save.file.path }
    }

    private struct RemovalBox: Identifiable {
        let removal: ReviewConfigEditor.Removal
        var id: String { removal.kind.rawValue + removal.id }
    }
}

/// Delete…: what goes to the Trash and what changes, before anything does.
struct ReviewDeleteSheet: View {
    @Environment(ReviewModel.self) private var model
    @State var removal: ReviewConfigEditor.Removal
    let brain: URL
    let catalog: ReviewCatalog?
    let done: (Bool) -> Void
    @State private var withRoles = true
    @State private var problem: String?
    @State private var deleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete \(removal.kind.rawValue) \(removal.id) in \(removal.level.title)?").font(.title3.weight(.semibold))
            if removal.kind == .scenario, !(removal.roles.isEmpty && removal.kept.isEmpty && withRoles) {
                Toggle("Also delete the roles only this scenario uses", isOn: $withRoles)
                    .onChange(of: withRoles) { replan() }
                    .help("Roles that no other scenario or project profile names go to the Trash with it")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ReviewConfigEditor.describe(removal), id: \.self) { line in
                        Text(line).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(removal.edits, id: \.file) { edit in
                        Text(edit.file.lastPathComponent).font(.caption.weight(.semibold)).padding(.top, 6)
                        ForEach(Array(edit.diff.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced())
                                .foregroundStyle(line.hasPrefix("+") ? .green : line.hasPrefix("-") ? .red : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 360)
            .padding(6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            if let problem { Text(problem).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { done(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    deleting = true
                    Task {
                        do {
                            try await ReviewConfigEditor.applyDelete(removal, brain: brain, env: model.env)
                            done(true)
                        } catch {
                            problem = error.localizedDescription
                        }
                        deleting = false
                    }
                }
                .disabled(deleting)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private func replan() {
        guard let catalog else { return }
        do {
            removal = try ReviewConfigEditor.planDelete(removal.kind, id: removal.id, level: removal.level, withRoles: withRoles,
                                                        catalog: catalog, home: model.home, brain: brain)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

struct ReviewSourceBadge: View {
    let source: ReviewSource

    var body: some View {
        let color: Color = switch source {
        case .builtIn: .secondary
        case .brain: .purple
        case .project: .blue
        case .run: .orange
        }
        Text(source.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// The diff of a save, with the work words a brain save from a work Mac holds (R17).
struct ReviewSaveSheet: View {
    @Environment(ReviewModel.self) private var model
    let save: ReviewConfigEditor.Save
    let brain: URL
    let done: (Bool) -> Void
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save \(save.kind.rawValue) \(save.id.isEmpty ? "review.yaml" : save.id) in \(save.level.title)?").font(.title3.weight(.semibold))
            Text(save.file.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach(save.notes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            if !save.workWords.isEmpty {
                Label("This is a work Mac, and the text names \(save.workWords.joined(separator: ", ")) from your work profiles. The brain may go to your personal GitHub: keep work names in a project copy instead.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(save.diff.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(line.hasPrefix("+") ? .green : line.hasPrefix("-") ? .red : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 360)
            .padding(6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            if let problem { Text(problem).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { done(false) }
                Button(save.workWords.isEmpty ? "Save" : "Save Anyway") {
                    saving = true
                    Task {
                        do {
                            try await ReviewConfigEditor.apply(save, brain: brain, env: model.env)
                            done(true)
                        } catch {
                            problem = error.localizedDescription
                        }
                        saving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

struct ReviewNewItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kind: ReviewConfigEditor.Kind
    let create: (String) -> Void
    @State private var id = ""

    private var valid: Bool { id.range(of: "^[a-z0-9][a-z0-9-]{0,62}$", options: .regularExpression) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New \(kind == .role ? "role" : "scenario")").font(.title3.weight(.semibold))
            TextField("Id", text: $id, prompt: Text(kind == .role ? "e.g. performance (the skill is review-performance)" : "e.g. hotfix"))
            Text("It starts from a template; you see the diff before it is saved at the level picked on the left.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    create(id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Review → Quality: precision from your verdicts at approval (R16).
struct ReviewQualityView: View {
    @Environment(ReviewModel.self) private var model
    @State private var entries: [ReviewQuality.Entry] = []
    @State private var outcomes: [ReviewOutcome] = []
    @State private var evalSet: [ReviewEvalCase] = []
    @State private var evalProblem: String?

    var body: some View {
        let precision = ReviewQuality.precision(entries)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Precision = approved / (approved + rejected), from your verdicts on the Review screen. A finding you moved inline counts as approved: the filter, not the reviewer, was wrong.")
                    .foregroundStyle(.secondary)
                outcomesSection
                evalSection
                if entries.isEmpty {
                    ContentUnavailableView("No verdicts yet", systemImage: "chart.bar",
                                           description: Text("Approve or reject findings on a run; the numbers appear here."))
                } else {
                    table("By role", precision.roles)
                    table("By scenario", precision.scenarios)
                    table("By model", precision.models)
                    let reasons = Dictionary(grouping: entries.compactMap(\.reason), by: { $0 }).mapValues(\.count)
                    if !reasons.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Why findings were rejected").font(.headline)
                            ForEach(reasons.sorted { $0.value > $1.value }, id: \.key) { reason, count in
                                Text("\(reason.title): \(count)")
                            }
                        }
                    }
                    let missed = entries.filter { $0.label == .missed }
                    if !missed.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Missed (added by you): \(missed.count)").font(.headline)
                            ForEach(missed.prefix(20), id: \.self) { Text("\($0.run): \($0.title)").font(.callout).lineLimit(2) }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            entries = ReviewQuality.entries(home: model.home)
            outcomes = ReviewOutcomes.all(home: model.home)
            evalSet = ReviewEvalSet.load(home: model.home)
        }
    }

    /// R32: the merge requests kept to check reviews against.
    @ViewBuilder private var evalSection: some View {
        Group {
            DisclosureGroup("Eval set (\(evalSet.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Merge requests pinned at a commit, with the findings a good review must report, or clean. Add them with Add to Eval Set on a review. Running the set through Lab comes later.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let evalProblem {
                        Label(evalProblem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(evalSet) { item in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.mergeRequest).font(.callout).textSelection(.enabled)
                                Text("\(item.headSHA.prefix(10)) · \(item.scenario) · " + (item.clean ? "clean" : item.expected.map(\.title).joined(separator: "; ")))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("Remove") {
                                do {
                                    try ReviewEvalSet.remove(item.id, home: model.home)
                                    evalProblem = nil
                                } catch {
                                    evalProblem = error.localizedDescription
                                }
                                evalSet = ReviewEvalSet.load(home: model.home)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    /// R31: what became of the published comments in GitLab.
    @ViewBuilder private var outcomesSection: some View {
        if !outcomes.isEmpty {
            let rates = ReviewOutcomes.rates(outcomes)
            VStack(alignment: .leading, spacing: 8) {
                Text("Outcomes in GitLab").font(.headline)
                Text("Accepted = fixed / (fixed + dismissed + ignored), from the 🤖 threads each rerun or Sync Outcomes reads. Below about 40% the comments are noise; 50–65% is good.")
                    .font(.caption).foregroundStyle(.secondary)
                outcomeTable("By role", rates.roles)
                outcomeTable("By model", rates.models)
                let replies = outcomes.filter { !$0.replies.isEmpty }
                if !replies.isEmpty {
                    DisclosureGroup("Authors' replies (\(replies.count))") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(replies, id: \.discussionID) { outcome in
                                Text("\(outcome.kind.rawValue) · \(outcome.role ?? "?") · \(outcome.file ?? "") — " + outcome.replies.joined(separator: " / "))
                                    .font(.callout).lineLimit(3).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }

    private func outcomeTable(_ title: String, _ rows: [ReviewOutcomes.Rate]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                ForEach(rows, id: \.key) { row in
                    GridRow {
                        Text(row.key)
                        Text(row.accepted.map { String(format: "%.0f%%", $0 * 100) } ?? "–").monospacedDigit().fontWeight(.medium)
                        Text("\(row.fixed) fixed, \(row.dismissed) dismissed, \(row.ignored) ignored, \(row.open) open").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func table(_ title: String, _ rows: [ReviewQuality.Precision]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                ForEach(rows, id: \.key) { row in
                    GridRow {
                        Text(row.key)
                        Text(row.value.map { String(format: "%.0f%%", $0 * 100) } ?? "–").monospacedDigit().fontWeight(.medium)
                        Text("\(row.approved) approved, \(row.rejected) rejected").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Write with AI…: the user's words and a writing skill; Pi drafts the role or the scenario,
/// AKit checks it, and the diff opens in the save sheet.
struct ReviewRoleWriterSheet: View {
    @Environment(ReviewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var kind: ReviewConfigEditor.Kind = .role
    let brain: URL
    let level: ReviewConfigEditor.Level
    let roleIDs: [String]
    let written: (ReviewConfigEditor.Save) -> Void
    // Snapshots: `--tab roles --add --select ID --query TEXT` fills them.
    @State private var id = DebugSnapshot.options?.select ?? ""
    @State private var words = DebugSnapshot.options?.query ?? ""
    @State private var skills: [ReviewRoleWriter.Skill]
    @State private var skill: String
    @State private var piModels: [String] = []
    @State private var passesModel = ""
    @State private var thinking = ""
    @State private var running: Task<Void, Never>?
    @State private var status: String?
    @State private var problem: String?
    @State private var draft: String?

    private var validID: Bool { id.range(of: "^[a-z0-9][a-z0-9-]{0,62}$", options: .regularExpression) != nil }
    private var ready: Bool { validID && !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && running == nil }
    /// The passes model and thinking a review at this level uses (loaded once).
    @State private var configured = ReviewModelChoice(model: "")

    init(kind: ReviewConfigEditor.Kind = .role, brain: URL, level: ReviewConfigEditor.Level, roleIDs: [String],
         written: @escaping (ReviewConfigEditor.Save) -> Void) {
        self.kind = kind
        self.brain = brain
        self.level = level
        self.roleIDs = roleIDs
        self.written = written
        let builtIn = ReviewRoleWriter.Skill.builtIn(for: kind)
        _skills = State(initialValue: [builtIn])
        _skill = State(initialValue: builtIn.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Write a \(kind.rawValue) with AI").font(.title3.weight(.semibold))
            Form {
                TextField(text: $id, prompt: Text(kind == .role ? "e.g. i18n (the skill is review-i18n)" : "e.g. payments")) { RequiredLabel("Id") }
                if roleIDs.contains(id) {
                    Text("\(kind == .role ? "Role" : "Scenario") \(id) exists: Pi improves its text.").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent {
                    TextEditor(text: $words)
                        .font(.body)
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                } label: {
                    RequiredLabel(kind == .role ? "What it checks" : "The problem")
                }
                .help(kind == .role ? "In your words: what the role looks for, in which code, what it must leave alone. Pi keeps your terms and limits"
                      : "In your words: what kind of change it is for, what can go wrong, which checks you want. Pi picks the roles and the skills to link")
                Picker("Writing skill", selection: $skill) {
                    ForEach(skills) { item in
                        Text(item.name + "  (" + item.place + ")").tag(item.id)
                    }
                }
                .help("The skill Pi follows to write it. \(ReviewRoleWriter.Skill.builtIn(for: kind).name) is AKit's own; your brain's and harnesses' skills are below it")
                if let picked = skills.first(where: { $0.id == skill }), !picked.description.isEmpty {
                    Text(picked.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                PiModelPicker(selection: $passesModel, models: piModels,
                              empty: "From the configuration (\(configured.model.isEmpty ? "Pi's default" : configured.model))") {
                    Text("Model")
                }
                Picker("Thinking", selection: $thinking) {
                    Text("From the configuration (\(configured.thinking.isEmpty ? "Pi's default" : configured.thinking))").tag("")
                    ForEach(ReviewModelChoice.thinkingLevels, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Saved in", value: level.title)
            }
            .formStyle(.grouped)
            Text("Pi gets your words, AKit's \(kind.rawValue) format, the existing roles, the names and descriptions of the skills it may link (and this \(kind.rawValue)'s text when it exists) and the writing skill, masked: no tools, no MCP, no code. Nothing is saved before you see the diff.")
                .font(.caption).foregroundStyle(.secondary)
            if let status, running != nil {
                HStack { ProgressView().controlSize(.small); Text(status).font(.caption).lineLimit(1) }
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let draft {
                ScrollView { Text(draft).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 160)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Text("* Required.").font(.caption).foregroundStyle(.red)
                Spacer()
                Button("Cancel") {
                    running?.cancel()
                    dismiss()
                }
                Button("Write") { write() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            let home = model.home
            let level = level
            let brain = brain
            let loaded = await Task.detached {
                let catalog = ReviewCatalog.load(home: home, brain: brain)
                let profile = level.slug.flatMap { slug in catalog.profiles.first { $0.slug == slug } }
                return (ReviewRoleWriter.skills(brain: brain, home: home, for: kind), ReviewRoleWriter.configuredModel(catalog: catalog, profile: profile))
            }.value
            skills = loaded.0
            configured = loaded.1
            piModels = await LabRuns.models(for: .pi, env: model.env)
        }
        // Closing the sheet any way stops Pi.
        .onDisappear { running?.cancel() }
    }

    private func write() {
        let chosen = skills.first { $0.id == skill } ?? .builtIn(for: kind)
        let choice: ReviewModelChoice? = passesModel.isEmpty && thinking.isEmpty ? nil : ReviewModelChoice(model: passesModel, thinking: thinking)
        let request = ReviewRoleWriter.Request(kind: kind, id: id, description: words, skill: chosen, level: level, model: choice)
        problem = nil
        draft = nil
        status = "Starting Pi…"
        let env = model.env
        let brain = brain
        running = Task {
            do {
                // Cancel stops the Pi process, not only this task.
                let result = try await Cancellation.followingTask {
                    try await ReviewRoleWriter.write(request, brain: brain, env: env) { line in
                        Task { @MainActor in status = line.trimmingCharacters(in: .whitespaces) }
                    }
                }
                running = nil
                guard !Task.isCancelled else { return }
                dismiss()
                written(result.save)
            } catch is CancellationError {
                running = nil
            } catch let failure as ReviewRoleWriter.Failure {
                problem = failure.message
                draft = failure.draft
                running = nil
            } catch {
                problem = error.localizedDescription
                running = nil
            }
        }
    }
}
