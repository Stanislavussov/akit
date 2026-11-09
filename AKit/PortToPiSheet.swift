import AKitFoundation
import AKitLab
import AKitSkills
import SwiftUI

/// Port to Pi…: a Claude Code skill rewritten as a Pi skill and checked (docs/design/skill-port.md).
/// Analyze (the skill's questions, extra rules, target and model) → Port → the check and the
/// SKILL.md diff → Install… with a confirmation.
struct PortToPiSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let skill: Skill

    private enum Place: Hashable { case global, project }

    @State private var place = Place.global
    @State private var project: URL?
    @State private var useModel = true
    @State private var harness = LabHarness.claudeCode
    @State private var modelName = ""
    @State private var models: [String] = []
    @State private var running: String?
    @State private var draft: SkillPort.Draft?
    @State private var report: SkillPortCheck.Report?
    @State private var modelLabel: String?
    @State private var confirming = false
    @State private var installedAt: URL?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    private enum Page { case analyze, result }
    @State private var page = Page.analyze
    @State private var questions: [SkillPortQuestion] = []
    @State private var answers: [String: String] = [:]
    @State private var analyzed = false
    @State private var preset = ""
    @State private var rulesText = ""
    @State private var savingPreset = false
    @State private var presetName = ""
    @State private var saved: [String: String] = [:]
    /// The model was asked for more questions (it is, before the first port, whenever a model is on).
    @State private var suggested = false
    /// "Add a change…": changes in plain words the model turns into rules.
    @State private var changes: [String] = []
    @State private var newChange = ""

    /// The extra rules as typed; nil with the parse error in `rulesError`.
    private var extraRules: SkillPortRules? { try? SkillPortRules.parse(rulesText) }
    private var rulesError: String? {
        do { _ = try SkillPortRules.parse(rulesText); return nil } catch { return error.localizedDescription }
    }

    private var env: HarnessEnvironment { .current }

    private var target: SkillPort.Target? {
        switch place {
        case .global: .global
        case .project: project.map { .project($0) }
        }
    }

    private var plan: SkillPort.InstallPlan? {
        guard let draft, let target else { return nil }
        return SkillPort.plan(draft, target: target, env: env)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Port “\(skill.name)” to Pi").font(.title2.bold())
            Text("Rewrites the Claude Code parts (frontmatter, /plugin:x commands, .claude and .omc paths, tool names, subagents, questions, task lists, MCP state) and checks the result. Nothing is written before Install….")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            settings
            Divider()
            Group {
                if page == .analyze { analyzePage } else { result }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            buttons
        }
        .padding(16)
        .frame(width: 800, height: 700)
        .task {
            let agent = SkillPortModel.agent(settings: LabSettings.load(env: env), env: env)
            harness = agent.harness
            modelName = agent.model
            project = model.projects.first
            saved = SkillPortRules.savedPresets(env: env)
            let folder = skill.realFolder
            let name = skill.name
            let found = await Task.detached { (try? SkillPort.read(folder)).map { SkillPortQuestions.analyze($0.texts, skill: name, catalog: (try? SkillPortCatalog.load(env: .current)) ?? .bundled) } ?? [] }.value
            questions = found
            answers = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.recommended) })
            analyzed = true
            // Snapshots: `--tab port-report` runs the port without a model.
            if DebugSnapshot.options?.tab == "port-report" {
                useModel = false
                run()
            }
        }
        .task(id: harness) {
            models = await model.labModels(for: harness)
        }
        .onChange(of: preset) { loadPreset() }
        .alert("Save as Preset", isPresented: $savingPreset) {
            TextField("Name", text: $presetName, prompt: Text("my-rules"))
            Button("Save", action: savePreset)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The rules and this skill's answers, in ~/.akit/port-presets/<name>.rules (a-z, 0-9 and hyphens).")
        }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(plan?.replaces == true ? "Replace" : "Install", role: plan?.replaces == true ? .destructive : nil, action: install)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(plan?.replaces == true ? "The folder there now goes to the Trash." : "Pi loads it in new sessions (/reload in running ones).")
        }
    }

    private var confirmTitle: String {
        guard let plan else { return "Install?" }
        return "\(plan.replaces ? "Replace" : "Install") \(plan.folder.tildePath)?"
    }

    private var settings: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Install to")
                HStack {
                    Picker("Install to", selection: $place) {
                        Text("Global").tag(Place.global)
                        Text("Project").tag(Place.project)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    if place == .project {
                        Picker("Project", selection: $project) {
                            Text("Choose…").tag(URL?.none)
                            ForEach(model.projects, id: \.self) { Text($0.lastPathComponent).tag(Optional($0)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text(target.map { SkillPort.folder(for: $0, name: skill.name, env: env).tildePath } ?? "")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            GridRow {
                Text("Model")
                HStack {
                    Toggle("Rewrite with a model", isOn: $useModel)
                        .help("Off: only the rule-based pass and the check; nothing is sent")
                    if useModel {
                        Picker("Harness", selection: $harness) {
                            ForEach(model.labHarnesses, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Picker("Model", selection: $modelName) {
                            if harness == .pi { Text("Pi's default").tag("") }
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                            if !modelName.isEmpty && !models.contains(modelName) { Text(modelName).tag(modelName) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("The model gets the skill's Markdown files under the sending policy; default: the translation model")
                    }
                }
            }
        }
    }

    private var analyzePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Questions") {
                    VStack(alignment: .leading, spacing: 8) {
                        if !analyzed {
                            ProgressView("Analyzing…")
                        } else if questions.isEmpty {
                            Text("Nothing to decide: the port runs by its rules.").foregroundStyle(.secondary)
                        }
                        ForEach(questions) { question in
                            let answer = answers[question.id] ?? question.recommended
                            let isOther = answer.hasPrefix(SkillPortQuestions.otherPrefix)
                            Picker(selection: Binding(get: { isOther ? SkillPortQuestions.otherPrefix : answer }, set: { answers[question.id] = $0 })) {
                                ForEach(question.options) { option in
                                    Text(option.title + (option.id == question.recommended ? " (recommended)" : "")).tag(option.id)
                                }
                                Divider()
                                Text("Other…").tag(SkillPortQuestions.otherPrefix)
                            } label: {
                                Text(question.question).fixedSize(horizontal: false, vertical: true)
                            }
                            .help(question.evidence == ["model"] ? "Suggested by the model" : "Found in the skill: \(question.evidence.joined(separator: ", "))")
                            if isOther {
                                TextField("Your answer", text: Binding(get: { String(answer.dropFirst(SkillPortQuestions.otherPrefix.count)) },
                                                                       set: { answers[question.id] = SkillPortQuestions.otherPrefix + $0 }),
                                          prompt: Text("In your own words; the model writes the rules"))
                                    .padding(.leading, 20)
                            }
                        }
                        Divider()
                        ForEach(changes, id: \.self) { change in
                            HStack {
                                Label(change, systemImage: "arrow.left.arrow.right")
                                Spacer()
                                Button("Remove", systemImage: "minus.circle") { changes.removeAll { $0 == change } }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            TextField("Add a change…", text: $newChange, prompt: Text("Add a change… e.g. replace axios with fetch"))
                                .onSubmit(addChange)
                            Button("Add", action: addChange).disabled(newChange.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if !useModel && (!changes.isEmpty || answers.values.contains { $0.hasPrefix(SkillPortQuestions.otherPrefix) }) {
                            Label("Your own changes need the model: turn on Rewrite with a model.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange).font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                GroupBox("Extra Rules") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Picker("Preset", selection: $preset) {
                                Text("None").tag("")
                                Section("Built-in") {
                                    ForEach(SkillPortRules.builtIns.keys.sorted(), id: \.self) { Text($0).tag($0) }
                                }
                                if !saved.isEmpty {
                                    Section("Saved") {
                                        ForEach(saved.keys.sorted(), id: \.self) { Text($0).tag($0) }
                                    }
                                }
                            }
                            .fixedSize()
                            Spacer()
                            Button("Save as Preset…") { presetName = preset.isEmpty || SkillPortRules.builtIns[preset] != nil ? "" : preset; savingPreset = true }
                                .disabled(rulesError != nil)
                        }
                        TextEditor(text: $rulesText)
                            .font(.callout.monospaced())
                            .frame(minHeight: 110)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                        Text("One rule per line: FROM => TO, re:PATTERN => TO, forbid: TOKEN, note: text for the model, allow: AskUserQuestion; # comments.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let rulesError { Label(rulesError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption) }
                    }
                    .padding(4)
                }
            }
        }
    }

    private func addChange() {
        let text = newChange.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !changes.contains(text) else { return }
        changes.append(text)
        newChange = ""
    }

    /// Own changes or Other… answers: they need the model.
    private var hasFreeChanges: Bool {
        !changes.isEmpty || answers.values.contains { $0.hasPrefix(SkillPortQuestions.otherPrefix) }
    }

    /// The preset's rules into the editor; its saved answers into the pickers.
    private func loadPreset() {
        guard !preset.isEmpty, let text = SkillPortRules.preset(preset, env: env) else { return }
        rulesText = text
        if let rules = try? SkillPortRules.parse(text) {
            for (id, option) in rules.answers where questions.contains(where: { $0.id == id && $0.options.contains { $0.id == option } }) {
                answers[id] = option
            }
        }
    }

    private func savePreset() {
        guard var rules = extraRules else { return }
        rules.answers = rules.answers.merging(answers) { $1 }
        do {
            try SkillPortRules.save(preset: presetName, text: rules.text, env: env)
            saved = SkillPortRules.savedPresets(env: env)
            preset = presetName
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func suggestQuestions() {
        error = nil
        let folder = skill.realFolder
        let env = env
        let agent = currentAgent
        let known = questions
        running = "Asking \(OutputTranslation.modelLabel(agent)) for more questions…"
        task = Task {
            defer { running = nil }
            do {
                let made = try await Task.detached { try SkillPort.port(folder: folder, env: env) }.value
                let gate = try await SkillPortModel.gate(agent: agent, env: env)
                let more = try await SkillPortModel.suggestQuestions(made, known: known, agent: agent, gate: gate, env: env)
                questions += more
                for question in more { answers[question.id] = question.recommended }
                suggested = true
                if more.isEmpty { error = "The model found nothing more to ask." }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var currentAgent: LabAgent {
        LabAgent(harness: harness, model: modelName, effort: harness.efforts.contains("low") ? "low" : harness.efforts[0], mode: .call)
    }

    @ViewBuilder
    private var result: some View {
        if let running {
            ProgressView(running).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let installedAt {
            ContentUnavailableView("Installed", systemImage: "checkmark.circle.fill",
                                   description: Text("\(installedAt.tildePath). Pi loads it in new sessions; /reload in running ones."))
        } else if let draft, let report {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    verdict(report)
                    if let modelLabel { Text("Model: \(modelLabel)").font(.caption).foregroundStyle(.secondary) }
                    ForEach(report.problems, id: \.self) { Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                    ForEach(report.groups, id: \.title) { group in
                        let hits = group.hits
                        let title = group.title
                        if !hits.isEmpty {
                            Text("\(title) (\(hits.count))").font(.subheadline.bold())
                            ForEach(hits, id: \.self) { hit in
                                Label("\(hit.file):\(hit.line) [\(hit.rule)] \(hit.text)", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    if !draft.rules.answers.isEmpty {
                        Text("Answers: " + draft.rules.answers.keys.sorted().map { "\($0)=\(draft.rules.answers[$0]!)" }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !report.missingNumbers.isEmpty {
                        Label("Numbers of the original missing: \(report.missingNumbers.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    ForEach(report.missingHeadings, id: \.self) { Label("Heading missing: \($0)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    GroupBox("Changes") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(draft.changes, id: \.self) { Text("• \($0)") }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox(plan?.replaces == true ? "SKILL.md: the Pi skill there now → the port" : "SKILL.md: the original → the port") {
                        VStack(alignment: .leading, spacing: 0) {
                            DiffPreview(diff: plan?.replaces == true ? plan!.diff
                                        : TextDiff.lines(from: draft.originals[SkillPort.skillFile] ?? "", to: draft.skillText))
                        }
                        .font(.callout.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Run the port", systemImage: "arrow.triangle.2.circlepath",
                                   description: Text("Run shows the check (pass, warnings or fail) and the new SKILL.md."))
        }
    }

    private func verdict(_ report: SkillPortCheck.Report) -> some View {
        switch report.verdict {
        case .pass: Label("Check passed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
        case .warnings: Label("Check: warnings", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.headline)
        case .fail: Label("Check failed: it can't be installed", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.headline)
        }
    }

    private var buttons: some View {
        HStack {
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3) }
            Spacer()
            if running != nil {
                Button("Stop") { task?.cancel() }
            }
            Button(installedAt == nil ? "Cancel" : "Done") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            if page == .analyze {
                if useModel && !suggested {
                    Button("Port Without Asking", action: run)
                        .disabled(running != nil || !analyzed || rulesError != nil)
                        .help("Port with the questions found so far, without asking the model for more")
                    Button("Find More Questions", action: suggestQuestions)
                        .keyboardShortcut(.defaultAction)
                        .disabled(running != nil || !analyzed)
                        .help("One model call: choice points for any technology, command, path or convention the catalog doesn't know")
                } else {
                    Button("Port", action: run)
                        .keyboardShortcut(.defaultAction)
                        .disabled(running != nil || !analyzed || rulesError != nil || (!useModel && hasFreeChanges))
                }
            } else {
                Button("Back") { page = .analyze }
                    .disabled(running != nil)
                Button("Run Again", action: run)
                    .disabled(running != nil || rulesError != nil)
                Button("Install…") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running != nil || report == nil || report?.verdict == .fail || target == nil || installedAt != nil)
            }
        }
    }

    private func run() {
        error = nil
        installedAt = nil
        let folder = skill.realFolder
        let env = env
        let agent = currentAgent
        let withModel = useModel
        let questions = questions
        let answers = answers
        let extra = extraRules ?? SkillPortRules()
        let ownChanges = changes
        page = .result
        running = "Porting…"
        task = Task {
            defer { running = nil }
            do {
                let answered = try SkillPortQuestions.rules(questions, answers: answers)
                var rules = answered.rules.merged(with: extra)
                let free = answered.others + ownChanges
                if withModel, !free.isEmpty {
                    running = "Writing rules for your changes…"
                    let base = try await Task.detached { try SkillPort.port(folder: folder, env: env) }.value
                    let gate = try await SkillPortModel.gate(agent: agent, env: env)
                    let made = try await SkillPortModel.rules(forChanges: free, draft: base, agent: agent, gate: gate, env: env)
                    rules = rules.merged(with: made.rules)
                    if !made.unchecked.isEmpty { error = "No check for: \(made.unchecked.joined(separator: "; "))" }
                }
                rules.answers = answers
                let ruled = rules
                var made = try await Task.detached { try SkillPort.port(folder: folder, env: env, rules: ruled) }.value
                var checked = SkillPortCheck.check(made)
                if withModel {
                    running = "Asking \(OutputTranslation.modelLabel(agent))…"
                    let gate = try await SkillPortModel.gate(agent: agent, env: env)
                    let outcome = try await SkillPortModel.run(made, agent: agent, gate: gate, env: env)
                    made = outcome.draft
                    checked = outcome.report
                    modelLabel = "\(OutputTranslation.modelLabel(agent)), \(outcome.rounds) round\(outcome.rounds == 1 ? "" : "s")"
                } else {
                    modelLabel = nil
                }
                draft = made
                report = checked
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func install() {
        guard let draft, let plan else { return }
        do {
            try SkillPort.install(draft, plan: plan)
            installedAt = plan.folder
            Task { await model.refresh() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
