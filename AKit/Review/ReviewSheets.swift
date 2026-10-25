import AKitFoundation
import AKitKnowledge
import AKitLab
import AKitReview
import AppKit
import SwiftUI

/// New Review…: a merge request or a local workspace, the scenario and roles, models and the
/// cap for this run.
struct NewReviewSheet: View {
    enum Source: String, CaseIterable, Identifiable {
        case mergeRequest = "Merge Request"
        case local = "Local Workspace"
        var id: Self { self }
    }

    @Environment(ReviewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let brain: URL
    @State private var source: Source = DebugSnapshot.options?.query?.hasPrefix("/") == true ? .local : .mergeRequest
    @State private var address = DebugSnapshot.options?.query.flatMap { $0.hasPrefix("/") ? nil : $0 } ?? ""
    @State private var workspace = DebugSnapshot.options?.query.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? ""
    @State private var baseRef = ""
    @State private var headRef = ""
    @State private var inspection: ReviewLocal.Inspection?
    @State private var inspectionProblem: String?
    @State private var mode: ReviewLocalTarget.Mode = .all
    @State private var workItems = ""
    @State private var scenario = ""
    @State private var rolesOn: Set<String> = []
    @State private var rolesOff: Set<String> = []
    @State private var passesModel = ""
    @State private var verifierModel = ""
    @State private var cap = ""
    @State private var maxChangedLines = ""
    @State private var fullReview = false
    /// nil: from the configuration.
    @State private var impact: ReviewImpact?
    @State private var summaryLanguage: LabLanguage?
    @State private var notes = ""
    @State private var links = ""
    @State private var extraServers: Set<String> = []
    @State private var catalog: ReviewCatalog?
    @State private var steps: [String] = []
    @State private var newStep = ""
    @State private var piFlags = ""
    @State private var piLibrary = ReviewPiLibrary()
    @State private var flagSuggestions: [(flag: String, help: String)] = []
    /// Models Pi has credentials for (`pi --list-models`).
    @State private var piModels: [String] = []

    /// `again`: Review Again… on a run fills in its change, scenario, context and models, and
    /// reads the whole change again (a rerun on the same commit would only carry the findings).
    init(brain: URL, again: ReviewRunSpec? = nil) {
        self.brain = brain
        guard let again else { return }
        if let local = again.local {
            _source = State(initialValue: .local)
            _workspace = State(initialValue: local.path)
            _baseRef = State(initialValue: local.baseRef)
            _headRef = State(initialValue: local.headRef ?? "")
            _mode = State(initialValue: local.mode)
        } else {
            let first = again.mergeRequest.url + (again.fromCommit.map { " " + $0 } ?? "")
            let linked = (again.linked ?? []).map { $0.mergeRequest.url + ($0.fromCommit.map { " " + $0 } ?? "") }
            _address = State(initialValue: ([first] + linked).joined(separator: "\n"))
        }
        _scenario = State(initialValue: again.scenario.value)
        _notes = State(initialValue: again.notes ?? "")
        _links = State(initialValue: (again.links ?? []).joined(separator: "\n"))
        _extraServers = State(initialValue: Set((again.mcpServers ?? []).filter { $0.source == .run }.map(\.name)))
        if again.passes.source == .run { _passesModel = State(initialValue: again.passes.value.model) }
        if again.verifier.source == .run { _verifierModel = State(initialValue: again.verifier.value.model) }
        if again.impact?.source == .run { _impact = State(initialValue: again.impact?.value) }
        if again.summaryLanguage?.source == .run { _summaryLanguage = State(initialValue: again.summaryLanguage?.value) }
        _fullReview = State(initialValue: true)
    }

    /// The Merge requests field: one per line, an optional commit after each.
    private var entries: Result<[ReviewMergeRequestEntry], Error> { Result { try ReviewLinked.entries(address) } }
    private var mr: MergeRequestRef? { (try? entries.get())?.first?.mergeRequest }
    private var profile: ReviewProfile? {
        switch source {
        case .mergeRequest: catalog?.profile(for: mr)
        case .local: inspection.flatMap { inspection in catalog.flatMap { ReviewLocal.profile(for: inspection, in: $0, env: model.env) } }
        }
    }
    /// The Pi flags of this run, or why not.
    private var flagsProblem: String? { ReviewPiFlags.problem(ReviewPiFlags.split(piFlags)) }
    /// The links as a run takes them, or why not.
    private var checkedLinks: Result<[String], Error> { Result { try ReviewContext.links([links]) } }
    /// The project's MCP rules (or the defaults): its own servers and its context servers.
    private var access: ReviewMCPAccess { profile?.mcp ?? ReviewMCPAccess() }
    /// The verifier's model from the configuration (brain, then the project profile); empty when none.
    private var configuredVerifier: String {
        [profile?.settings.verifier?.model, catalog?.brainDefaults.verifier?.model, catalog?.builtInDefaults.verifier?.model]
            .compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }
    /// The passes' model from the configuration; empty = Pi's default.
    private var configuredPasses: String {
        [profile?.settings.passes?.model, catalog?.brainDefaults.passes?.model, catalog?.builtInDefaults.passes?.model]
            .compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }
    /// `impact` from the configuration: the profile, the brain, the built-in default.
    private var configuredImpact: ReviewImpact {
        profile?.settings.impact ?? catalog?.brainDefaults.impact ?? catalog?.builtInDefaults.impact ?? .auto
    }
    /// `summary_language` from the configuration, else the Mac's preferred language.
    private var configuredLanguage: LabLanguage {
        profile?.settings.summaryLanguage ?? catalog?.brainDefaults.summaryLanguage ?? catalog?.builtInDefaults.summaryLanguage
            ?? ReviewResolver.preferredLanguage(Locale.preferredLanguages)
    }
    private var canStart: Bool {
        guard !model.isBusy, (try? checkedLinks.get()) != nil, flagsProblem == nil else { return false }
        // The verifier's model is the user's choice (R25).
        guard !verifierModel.trimmingCharacters(in: .whitespaces).isEmpty || !configuredVerifier.isEmpty else { return false }
        return switch source {
        case .mergeRequest: mr != nil
        case .local: inspection?.has(mode) == true
        }
    }
    private var scenarios: [ReviewScenario] { catalog?.scenarios(for: profile) ?? [] }
    private var chosen: ReviewScenario? { scenarios.first { $0.id == scenario } }
    private var roles: [ReviewRole] { catalog?.roles(for: profile) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Review", selection: $source) {
                    ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if source == .local {
                    localSection
                } else {
                Section {
                    mergeRequestsField
                    TextField("Work items", text: $workItems, prompt: Text("e.g. 4512 (else the number in the branch: COL-4512)"))
                }
                }
                contextSection
                Section("Scenario and roles") {
                    Picker("Scenario", selection: $scenario) {
                        ForEach(scenarios) { Text($0.title).tag($0.id) }
                    }
                    if let chosen {
                        ForEach(roles) { role in
                            let required = chosen.required.contains(role.id) || (profile?.rolesAdd.contains(role.id) ?? false)
                            let defaultOn = required && !(profile?.rolesOff.contains(role.id) ?? false)
                            Toggle(isOn: Binding(get: { (defaultOn || rolesOn.contains(role.id)) && !rolesOff.contains(role.id) },
                                                 set: { on in
                                                     if on { rolesOff.remove(role.id); if !defaultOn { rolesOn.insert(role.id) } }
                                                     else { rolesOn.remove(role.id); if defaultOn { rolesOff.insert(role.id) } }
                                                 })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(role.id + (required ? "" : chosen.optional.contains(role.id) ? " (optional)" : " (not in this scenario)"))
                                    Text(role.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        if !chosen.checks.isEmpty {
                            Text(chosen.checks.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                extraServersSection
                piSection
                Section("This run only") {
                    PiModelPicker(selection: $passesModel, models: piModels,
                                  empty: "From the configuration (\(configuredPasses.isEmpty ? "Pi's default" : configuredPasses))") {
                        Text("Model for the brief and roles")
                    }
                    PiModelPicker(selection: $verifierModel, models: piModels,
                                  empty: configuredVerifier.isEmpty ? "Choose a model…" : "From the configuration (\(configuredVerifier))") {
                        if configuredVerifier.isEmpty { RequiredLabel("Verifier model") } else { Text("Verifier model") }
                    }
                    if verifierModel.trimmingCharacters(in: .whitespaces).isEmpty, configuredVerifier.isEmpty {
                        Text("Required: no verifier model is configured. Choose one here, or set it in Review Settings… (models: verifier). A model of "
                             + "another family than the roles' checks their findings best.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if piModels.isEmpty {
                        Text("Pi lists no models (pi --list-models): log in to a provider in Pi first.").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Credit cap", text: $cap, prompt: Text("empty: from the configuration"))
                    TextField("Max changed lines", text: $maxChangedLines, prompt: Text("over it the review asks first (empty: from the configuration)"))
                    ReviewImpactPicker(selection: $impact, empty: "From the configuration (\(configuredImpact.title))")
                    ReviewLanguagePicker(selection: $summaryLanguage, empty: "From the configuration (\(configuredLanguage.name))")
                    if source == .mergeRequest {
                        Toggle("Full review", isOn: $fullReview)
                            .help("A rerun after a push reviews only what changed since the last review and carries the earlier findings. "
                                  + "On: read the whole merge request again.")
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("* Required.").font(.caption).foregroundStyle(.red)
                Text(source == .local ? "Pi reads a copy of the workspace at the reviewed commit, never the workspace itself. The findings stay in AKit."
                     : "Pi reads the merge request and its work items through its MCP servers, only with reading tools. Nothing is written to GitLab here.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start Review") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
            .padding()
        }
        .frame(width: 620, height: 720)
        .task {
            catalog = model.catalog(brain: brain)
            scenario = scenario.isEmpty ? (profile?.defaultScenario ?? "feature") : scenario
        }
        .onChange(of: address) {
            if let preset = profile?.defaultScenario { scenario = preset }
        }
        .task(id: "\(source.rawValue)|\(workspace)|\(baseRef)|\(headRef)") { await inspect() }
        .task { await loadPi() }
        .task { piModels = await LabRuns.models(for: .pi, env: model.env) }
    }

    /// One merge request per line; the first is the main one, the others are linked.
    @ViewBuilder private var mergeRequestsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            RequiredLabel("Merge requests")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $address)
                    .font(.callout.monospaced())
                    .frame(height: 64)
                if address.isEmpty {
                    Text("https://gitlab.example.com/group/project/-/merge_requests/12")
                        .font(.callout.monospaced()).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            switch entries {
            case .failure(let error):
                Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
            case .success(let list) where list.isEmpty:
                EmptyView()
            case .success(let list):
                ForEach(Array(list.enumerated()), id: \.offset) { index, entry in
                    Text(caption(entry, linked: index > 0)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("One per line. The first sets the profile, scenario and roles; the others are linked merge requests of the same change "
                 + "(another repository): the roles read them all, and each finding goes to drafts in its own merge request. After an "
                 + "address, a commit (a1b2c3d) reviews only what changed after it; without one the review starts at the merge base, "
                 + "where the branch left its target.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// `Linked: team/api!12, from the merge base · profile api.yaml`.
    private func caption(_ entry: ReviewMergeRequestEntry, linked: Bool) -> String {
        var text = linked ? "Linked: " : ""
        text += entry.mergeRequest.label
        text += entry.fromCommit.map { ", from commit \($0)" } ?? ", from the merge base"
        if let found = catalog?.profile(for: entry.mergeRequest) {
            text += " · profile \(found.slug).yaml"
        } else {
            text += " · no project profile: no checkout, tracker or rules (Review Settings… adds one)"
        }
        return text
    }

    /// Pi steps after the roles and extra Pi flags: suggested from the user's Pi set-up, or typed.
    @ViewBuilder private var piSection: some View {
        Section {
            let configured = (catalog?.brainPi.steps ?? []) + (profile?.pi.steps ?? [])
            if !configured.isEmpty {
                Text("From the configuration: " + configured.map(\.command).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack {
                    Text(step).font(.callout.monospaced()).lineLimit(2)
                    Spacer()
                    Button { steps.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove this step")
                }
            }
            HStack {
                TextField("Step", text: $newStep, prompt: Text("/run agent task, /template, /skill:name or text"))
                    .font(.callout.monospaced())
                    .onSubmit(addStep)
                Menu("Suggest") {
                    ForEach([ReviewPiLibrary.Item.Kind.agent, .template, .skill], id: \.self) { kind in
                        let items = piLibrary.items.filter { $0.kind == kind }
                        if !items.isEmpty {
                            Section(kind == .agent ? "Subagents" : kind == .template ? "Prompt templates" : "Skills") {
                                ForEach(items) { item in
                                    Button("\(item.command) — \(item.description.prefix(70))") { newStep = item.command + " " }
                                }
                            }
                        }
                    }
                }
                .fixedSize()
                .disabled(piLibrary.items.isEmpty)
                Button("Add", action: addStep).disabled(newStep.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            let matches = stepMatches
            if !matches.isEmpty {
                ForEach(matches) { item in
                    Button { newStep = item.command + " " } label: {
                        HStack {
                            Text(item.command + (item.argumentHint.map { " " + $0 } ?? "")).font(.caption.monospaced())
                            Text(item.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Pi flags", text: $piFlags, prompt: Text("e.g. --exclude-tools find"))
                    .font(.callout.monospaced())
                Menu("Suggest") {
                    ForEach(flagSuggestions, id: \.flag) { suggestion in
                        Button("\(suggestion.flag) — \(suggestion.help.prefix(70))") {
                            let flag = suggestion.flag.split(separator: " ").first.map(String.init) ?? suggestion.flag
                            piFlags += (piFlags.isEmpty || piFlags.hasSuffix(" ") ? "" : " ") + flag + " "
                        }
                    }
                }
                .fixedSize()
                .disabled(flagSuggestions.isEmpty)
            }
            if let flagsProblem {
                Text(flagsProblem).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Pi steps")
        } footer: {
            Text("Steps run after the roles, each as its own pass: your subagent's prompt and model, a prompt template or a skill. They get only the review's reading tools, so an agent's bash, edit or write tools are left out, and their findings go through the verifier. Extension commands don't run here. The flags go to every pass but the fetch and send ones.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Items whose command starts with what is typed (after a /), at most six.
    private var stepMatches: [ReviewPiLibrary.Item] {
        let typed = newStep.trimmingCharacters(in: .whitespaces).lowercased()
        guard typed.hasPrefix("/"), !typed.contains(" ") else { return [] }
        return Array(piLibrary.items.filter { $0.command.lowercased().hasPrefix(typed) || $0.command.lowercased().contains(" " + typed.dropFirst()) }
            .filter { $0.command.lowercased() != typed }.prefix(6))
    }

    private func addStep() {
        let step = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !step.isEmpty, !steps.contains(step) else { return }
        steps.append(step)
        newStep = ""
    }

    private func loadPi() async {
        let env = model.env
        piLibrary = await Task.detached { ReviewPiLibrary.load(env: env) }.value
        if let pi = env.findExecutable("pi"), let help = await ReviewPiCommands.help(pi: pi, env: env) {
            flagSuggestions = ReviewPiFlags.suggestions(help: help)
        }
    }

    /// The developer's own context: notes every pass reads, links the fetch pass reads.
    @ViewBuilder private var contextSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Context for this review")
                TextEditor(text: $notes)
                    .font(.callout)
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                Text("What the change is for, what to focus on, decisions already made. Every pass reads it as your instructions for focus; the model still only returns findings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Links")
                TextEditor(text: $links)
                    .font(.callout.monospaced())
                    .frame(height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                if case .failure(let error) = checkedLinks {
                    Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
                } else {
                    Text("One https link per line: Figma frames, Azure DevOps wiki pages or work items, Confluence pages. Pi reads each with a matching MCP server's reading tools; what it can't read becomes a context gap.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Context")
        }
    }

    /// Pi's other MCP servers, to add as read-only context servers for this run.
    @ViewBuilder private var extraServersSection: some View {
        Section {
            HStack {
                Text(access.extraServers.isEmpty ? "Add context servers for this run" : "Context servers of the profile: " + access.extraServers.joined(separator: ", "))
                    .font(.callout)
                Spacer()
                Button(model.checkingMCP ? "Listing…" : "List Servers") { model.checkMCP(access: access) }
                    .disabled(model.checkingMCP)
            }
            if let report = model.mcpReport {
                let others = report.servers.filter { !access.isBase(server: $0.name) }
                if others.isEmpty {
                    Text("Pi has no other MCP servers.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(others) { server in
                    let fromProfile = access.isExtra(server: server.name)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: Binding(get: { fromProfile || extraServers.contains(server.name) },
                                             set: { on in if on { extraServers.insert(server.name) } else { extraServers.remove(server.name) } })) {
                            HStack {
                                Text(server.name)
                                Text(fromProfile ? "from the profile" : server.enabled ? server.state : "disabled")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(fromProfile)
                        if let warning = ReviewMCPAccess.warning(forServer: server.name), fromProfile || extraServers.contains(server.name) {
                            Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            if let problem = model.mcpProblem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Extra servers")
        } footer: {
            Text("Context servers only read, in every pass: their tools never write, not even in Send Drafts. GitLab and the tracker are always there. The profile's mcp: extra_servers are on for every run.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Local Workspace: the folder, the base, and what is there to review before anything starts.
    @ViewBuilder private var localSection: some View {
        Section {
            HStack {
                TextField(text: $workspace, prompt: Text("a git worktree of Orca or herdr, or any clone")) { RequiredLabel("Workspace") }
                Button("Choose…") { chooseWorkspace() }
            }
            ReviewPointField(title: "Base", text: $baseRef, prompt: "empty: the default branch (origin/HEAD, main or master)",
                             workspace: workspaceURL, env: model.env)
            ReviewPointField(title: "Head", text: $headRef, prompt: "empty: HEAD of the workspace, with its uncommitted changes",
                             workspace: workspaceURL, env: model.env)
            if let problem = inspectionProblem {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if let inspection {
                Text((inspection.headRef == nil ? "" : "up to ") + "\(inspection.branch) at \(inspection.head.prefix(10)) · base \(inspection.baseRef ?? "none")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(inspection.summary).font(.callout)
                if inspection.baseRef == nil {
                    Text("No base branch found: enter one in Base to count the commits.").font(.caption).foregroundStyle(.orange)
                }
                if inspection.suggestedMode != nil {
                    Picker("What to review", selection: $mode) {
                        ForEach(modes(inspection)) { Text($0.title).tag($0) }
                    }
                }
                if !inspection.commits.isEmpty {
                    DisclosureGroup("Commits (\(inspection.commits.count))") {
                        ForEach(inspection.commits.prefix(50)) { commit in
                            Text("\(commit.sha.prefix(10))  \(commit.author): \(commit.subject)").font(.caption.monospaced()).lineLimit(1)
                        }
                    }
                }
                if !inspection.uncommitted.isEmpty {
                    DisclosureGroup("Uncommitted files (\(inspection.uncommitted.count))") {
                        ForEach(inspection.uncommitted.prefix(50), id: \.self) { Text($0).font(.caption.monospaced()).lineLimit(1) }
                    }
                }
                Text(profile.map { "Project profile: \($0.project) (\($0.slug).yaml)" } ?? "No project profile for this repository: no project rules.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Text("In a terminal of the workspace: akit review local . (--what commits | uncommitted, --base REF, --head REF); akit review points . --find TEXT finds a ref.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The workspace Find… searches: the typed folder, once it is there.
    private var workspaceURL: URL? {
        let path = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let url = model.env.expand(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The choices that differ: all three with commits and uncommitted changes, else the one there is.
    private func modes(_ inspection: ReviewLocal.Inspection) -> [ReviewLocalTarget.Mode] {
        inspection.suggestedMode == .all ? ReviewLocalTarget.Mode.allCases : inspection.suggestedMode.map { [$0] } ?? []
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { workspace = url.path }
    }

    /// Reads the workspace when its path or base changes (after a short pause while typing).
    private func inspect() async {
        guard source == .local else { return }
        let path = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            inspection = nil
            inspectionProblem = nil
            return
        }
        // The old range must not start while the new one is read (a Return right after Find…).
        inspection = nil
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        let base = baseRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = headRef.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let found = try await ReviewLocal.inspect(path: model.env.expand(path), baseRef: base.isEmpty ? nil : base,
                                                      headRef: head.isEmpty ? nil : head, env: model.env)
            guard !Task.isCancelled else { return }
            inspection = found
            inspectionProblem = nil
            if !modes(found).contains(mode), let suggested = found.suggestedMode { mode = suggested }
            if let preset = profile?.defaultScenario { scenario = preset }
        } catch {
            guard !Task.isCancelled else { return }
            inspection = nil
            inspectionProblem = error.localizedDescription
        }
    }

    private func start() {
        var choices = ReviewRunChoices(scenario: scenario.isEmpty ? nil : scenario, rolesOn: Array(rolesOn), rolesOff: Array(rolesOff))
        choices.workItems = workItems.split(whereSeparator: { ", #".contains($0) }).compactMap { Int($0) }
        if !passesModel.isEmpty { choices.settings.passes = ReviewModelChoice(model: passesModel) }
        let verifier = verifierModel.trimmingCharacters(in: .whitespaces)
        if !verifier.isEmpty { choices.settings.verifier = ReviewModelChoice(model: verifier) }
        if let value = Int(cap), value > 0 { choices.settings.capCredits = value }
        if let value = Int(maxChangedLines), value > 0 { choices.settings.maxChangedLines = value }
        choices.fullReview = fullReview
        choices.settings.impact = impact
        choices.settings.summaryLanguage = summaryLanguage
        choices.notes = notes
        choices.links = (try? checkedLinks.get()) ?? []
        choices.extraServers = extraServers.sorted()
        choices.pi = ReviewPiExtras(flags: ReviewPiFlags.split(piFlags), steps: steps.map { ReviewStepConfig(command: $0) })
        if source == .local, let inspection {
            model.startLocal(inspection, mode: mode, project: profile?.slug, choices: choices, brain: brain)
        } else if let list = try? entries.get(), let first = list.first {
            choices.fromCommit = first.fromCommit
            choices.linked = Array(list.dropFirst())
            model.start(mr: first.mergeRequest, project: profile?.slug, choices: choices, brain: brain)
        } else {
            return
        }
        dismiss()
    }
}

/// Review Settings…: Pi's MCP servers as review uses them, and the project profiles. AKit keeps
/// no GitLab or Azure DevOps token: Pi connects with the servers in its own settings.
struct ReviewSettingsSheet: View {
    @Environment(ReviewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let brain: URL
    @State private var rules = ""
    @State private var message: String?
    @State private var catalog: ReviewCatalog?

    /// The profile's context servers as ticked here, saved with Save Extra Servers….
    @State private var extras: [String] = []
    @State private var save: ReviewConfigEditor.Save?
    /// The profile's knowledge_base and knowledge_budget as set here ("" = none), saved with Save Knowledge….
    @State private var knowledgeBase = ""
    @State private var knowledgeBudget = ReviewKnowledgeCard.defaultBudget
    @State private var bases: [KnowledgeBase] = []

    private var profile: ReviewProfile? { catalog?.profiles.first { $0.slug == rules } }
    private var access: ReviewMCPAccess { profile?.mcp ?? ReviewMCPAccess() }
    /// The rules with the ticked context servers: what a run of this project would use.
    private var effective: ReviewMCPAccess {
        var access = access
        access.extraServers = extras
        return access
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    HStack {
                        Picker("Rules of", selection: $rules) {
                            Text("Default").tag("")
                            ForEach(catalog?.profiles ?? [], id: \.slug) { Text($0.project).tag($0.slug) }
                        }
                        Button(model.checkingMCP ? "Checking…" : "Check Servers") { model.checkMCP(access: effective) }
                            .disabled(model.checkingMCP)
                    }
                    if let report = model.mcpReport {
                        if report.servers.isEmpty {
                            Text("Pi has no MCP servers. Add your GitLab and tracker servers to Pi (pi mcp add …, or the MCP screen).")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        ForEach(report.servers) { server in
                            serverRow(server)
                        }
                        ForEach(report.errors, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    }
                    if let problem = model.mcpProblem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    if profile == nil {
                        Text("Pick a project profile in Rules of to add context servers to it (mcp: extra_servers).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if extras != access.extraServers {
                        HStack {
                            Text("Context servers: " + (extras.isEmpty ? "none" : extras.joined(separator: ", "))).font(.caption)
                            Spacer()
                            Button("Save Extra Servers…") { planExtras() }
                        }
                    }
                    if profile != nil {
                        Toggle("Every Pi server in the review passes", isOn: Binding(get: { access.allServers }, set: { on in
                            do {
                                save = try ReviewConfigEditor.allServers(on, profile: rules, home: model.home, brain: brain)
                            } catch {
                                message = error.localizedDescription
                            }
                        }))
                        .help("mcp: all_servers. On: the brief, roles and verifier also read through your other Pi servers (context7 for docs, a wiki), "
                              + "only with tools named or marked as reading and only short queries; browser, file, fetch, secret and database servers "
                              + "only when ticked as Context server. Off: only GitLab, the tracker and context servers.")
                    }
                } header: {
                    Text("Pi's MCP servers")
                } footer: {
                    Text("Pi connects to GitLab, Azure DevOps and your other trackers with the MCP servers in its own settings; AKit keeps no tokens. A review reads with their reading tools, writes only the drafts you approved, word for word, and never publishes, approves, merges or resolves. A profile's mcp: names the servers and tools it may use; a Context server (Figma, Confluence, a wiki) is added on top and only reads.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                overviewSection
                if let profile {
                    knowledgeSection(profile)
                }
                Section {
                    ForEach(catalog?.profiles ?? [], id: \.slug) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.project)
                                Text("\(profile.gitlabHost)/\(profile.gitlabProjectPath)"
                                     + (profile.mcp.servers.isEmpty ? "" : " · MCP: " + profile.mcp.servers.joined(separator: ", "))
                                     + (profile.mcp.extraServers.isEmpty ? "" : " · context: " + profile.mcp.extraServers.joined(separator: ", ")))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let file = profile.file {
                                Button("Edit…") { NSWorkspace.shared.open(file) }
                            }
                        }
                    }
                    ForEach(catalog?.problems ?? [], id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("New Profile…") { newProfile() }
                        Button("Show Folder") {
                            let folder = ReviewPaths(home: model.home).projects
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(folder)
                        }
                    }
                } header: {
                    Text("Project profiles")
                } footer: {
                    Text("One YAML file per GitLab project in ~/.akit/local/review/projects: the checkout, the tracker, the MCP servers and tools, rules, knowledge folders, gather commands and overrides. Only on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 600, height: 640)
        .task {
            catalog = model.catalog(brain: brain)
            bases = KnowledgeBase.all(home: model.home)
        }
        .onChange(of: rules) {
            extras = access.extraServers
            loadKnowledge()
        }
        .sheet(item: Binding(get: { save.map(SaveBox.init) }, set: { save = $0?.save })) { box in
            ReviewSaveSheet(save: box.save, brain: brain) { saved in
                save = nil
                if saved {
                    catalog = model.catalog(brain: brain)
                    extras = access.extraServers
                    loadKnowledge()
                    message = "Saved \(box.save.file.lastPathComponent)."
                }
            }
        }
    }

    /// Other repositories and Summary language of the level picked in Rules of: the brain's
    /// review.yaml (Default) or the profile's review: block. Each change shows its diff first.
    @ViewBuilder private var overviewSection: some View {
        let brainImpact = catalog?.brainDefaults.impact ?? catalog?.builtInDefaults.impact ?? .auto
        let brainLanguage = catalog?.brainDefaults.summaryLanguage ?? catalog?.builtInDefaults.summaryLanguage
        let preferred = ReviewResolver.preferredLanguage(Locale.preferredLanguages)
        Section {
            ReviewImpactPicker(selection: Binding(get: { profile == nil ? catalog?.brainDefaults.impact : profile?.settings.impact },
                                                  set: { value in plan { try ReviewConfigEditor.reviewSetting(impact: value, profile: profile?.slug, home: model.home, brain: brain) } }),
                               empty: profile == nil ? "Built-in (\(brainImpact.title))" : "From the brain (\(brainImpact.title))")
            ReviewLanguagePicker(selection: Binding(get: { profile == nil ? catalog?.brainDefaults.summaryLanguage : profile?.settings.summaryLanguage },
                                                    set: { value in plan { try ReviewConfigEditor.reviewSetting(summaryLanguage: value, profile: profile?.slug,
                                                                                                                  home: model.home, brain: brain) } }),
                                 empty: profile == nil ? "The Mac's language (\(preferred.name))"
                                     : "From the brain (\((brainLanguage ?? preferred).name))")
        } header: {
            Text("Overview and other repositories")
        } footer: {
            Text(profile == nil
                 ? "Default: the brain's review.yaml (impact, summary_language). A project profile's review: block and New Review… can change them."
                 : "This project's profile (review: impact, summary_language). New Review… can change them for one run.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func plan(_ make: () throws -> ReviewConfigEditor.Save) {
        do {
            save = try make()
        } catch {
            message = error.localizedDescription
        }
    }

    private struct SaveBox: Identifiable {
        let save: ReviewConfigEditor.Save
        var id: String { save.file.path }
    }

    /// One of Pi's servers as this profile's review sees it; a server that isn't GitLab or the
    /// tracker can be ticked as a context server.
    @ViewBuilder private func serverRow(_ server: ReviewMCPCheck.Server) -> some View {
        let kinds = server.tools.map { (name: $0.name, kind: ReviewMCPPolicy.kind(server: server.name, tool: $0.name, access: effective,
                                                                                  inPasses: effective.inPasses)) }
        let base = effective.isBase(server: server.name)
        let context = effective.isExtra(server: server.name)
        let open = !base && !context && effective.allows(server: server.name, inPasses: effective.inPasses)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: server.state == "connected" && server.enabled ? "circle.fill" : "circle")
                    .foregroundStyle(server.state == "connected" && server.enabled ? .green : .secondary).font(.caption2)
                Text(server.name)
                Text(server.enabled ? server.state : "disabled").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if base || context {
                    Text((context ? "context · " : "") + "\(kinds.filter { $0.kind == .read }.count) read"
                         + (context ? "" : " · \(kinds.filter { $0.kind == .write }.count) write drafts")
                         + " · \(kinds.filter { $0.kind == .blocked }.count) blocked")
                        .font(.caption).foregroundStyle(.secondary)
                } else if open {
                    Text("read in the brief, roles and verifier · \(kinds.filter { $0.kind == .read }.count) read · "
                         + "\(kinds.filter { $0.kind == .blocked }.count) blocked")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Every server of your Pi reads in the review passes (all_servers), only with tools named or marked as reading, and only short queries.")
                } else {
                    Text(ReviewMCPAccess.isRisky(server: server.name) ? "not used: tick Context server to use it" : "not used by this project")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if profile != nil, !base {
                    Toggle("Context server", isOn: Binding(get: { context }, set: { on in
                        if on { extras.append(server.name) } else { extras.removeAll { $0.lowercased() == server.name.lowercased() } }
                    }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
            }
            let writes = kinds.filter { $0.kind == .write }.map(\.name)
            if base, !writes.isEmpty {
                Text("Send Drafts may call: " + writes.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            if context, let warning = ReviewMCPAccess.warning(forServer: server.name) {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// The profile's knowledge base (K18): the card Gather writes, and its size.
    @ViewBuilder private func knowledgeSection(_ profile: ReviewProfile) -> some View {
        let budget: Int? = knowledgeBudget == ReviewKnowledgeCard.defaultBudget && profile.knowledgeBudget == nil ? nil : knowledgeBudget
        let base: String? = knowledgeBase.isEmpty ? nil : knowledgeBase
        Section {
            Picker("Knowledge base", selection: $knowledgeBase) {
                Text("None").tag("")
                ForEach(bases, id: \.root) { base in
                    Text("\(base.name) (\(FileWalk.tilde(base.root, home: model.home)))").tag(base.world ?? base.root.path)
                }
                if let current = profile.knowledgeBase, !bases.contains(where: { ($0.world ?? $0.root.path) == current }) {
                    Text("\(current) (not a base on this Mac)").tag(current)
                }
            }
            TextField("Knowledge budget (tokens)", value: $knowledgeBudget, format: .number)
                .help("knowledge_budget: the card's size in tokens, 8000 by default (about 4 bytes a token).")
            if base != profile.knowledgeBase || budget != profile.knowledgeBudget {
                HStack {
                    Spacer()
                    Button("Save Knowledge…") { planKnowledge(base: base, budget: budget) }
                        .disabled(knowledgeBudget <= 0)
                }
            }
        } header: {
            Text("Knowledge base")
        } footer: {
            Text("knowledge_base: and knowledge_budget: of the profile. Gather refreshes the base's index and writes context/knowledge-card.md: "
                 + "the systems the change touches (a note's files:), the others of the repository's areas (area.yaml projects:, "
                 + "a note's repo:), their relations and neighbours, one line each, within the budget. Only the card goes in, never the notes "
                 + "or the inbox. --knowledge-base and --knowledge-budget set them for one run.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadKnowledge() {
        knowledgeBase = profile?.knowledgeBase ?? ""
        knowledgeBudget = profile?.knowledgeBudget ?? ReviewKnowledgeCard.defaultBudget
    }

    /// Save Knowledge…: the profile's knowledge_base and knowledge_budget, shown as a diff first.
    private func planKnowledge(base: String?, budget: Int?) {
        do {
            save = try ReviewConfigEditor.knowledge(base: base, budget: budget, profile: rules, home: model.home, brain: brain)
        } catch {
            message = error.localizedDescription
        }
    }

    /// Save Extra Servers…: the profile's mcp: extra_servers, shown as a diff first.
    private func planExtras() {
        do {
            save = try ReviewConfigEditor.extraServers(extras, profile: rules, home: model.home, brain: brain)
        } catch {
            message = error.localizedDescription
        }
    }

    /// A commented template, opened in the editor.
    private func newProfile() {
        let folder = ReviewPaths(home: model.home).projects
        var index = 1
        var file = folder.appending(path: "new-project.yaml")
        while FileManager.default.fileExists(atPath: file.path) {
            index += 1
            file = folder.appending(path: "new-project-\(index).yaml")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(ReviewProfileTemplate.text.utf8).write(to: file)
            NSWorkspace.shared.open(file)
            catalog = model.catalog(brain: brain)
        } catch {
            message = error.localizedDescription
        }
    }
}

enum ReviewProfileTemplate {
    static let text = """
    # AKit review project profile. The file name (a-z, 0-9, -) is the profile's id.
    project: my-service
    gitlab: { host: https://gitlab.example.com, project_path: group/my-service }
    checkout: ~/work/my-service            # your clone: the worktree at the reviewed commit comes from it
    # tracker: { kind: azure-devops, org: my-org, project: MyProject, wi_ref_regex: "(?i)(?:COL-|AB#|WI-)(\\\\d+)" }
    # mcp:                                 # Pi's MCP servers review may use (pi mcp list); none = those named gitlab, azure, devops, ado
    #   servers: [gitlab, azure-devops]
    #   read: []                           # more reading tools, e.g. ["wit_get_*"]; get_/list_/search_… read anyway
    #   write: ["*draft_note*"]            # the tools Send Drafts may call; only approved text passes
    #   in_passes: true                    # the brief, roles and verifier may read through MCP too
    #   all_servers: true                  # …through every server of your Pi (browser, file and fetch servers only when named)
    #   extra_servers: [figma]             # context servers on top (Figma, Confluence, a wiki): read only, in every run
    default_scenario: feature              # feature, bugfix, dependency-upgrade
    knowledge: []                          # markdown folders, e.g. [~/notes/my-service]
    # knowledge_base: work                 # a knowledge base (world or folder): Gather adds its card of the touched systems
    # knowledge_budget: 8000               # the card's size in tokens
    gather: []                             # e.g. - { name: tests, run: "npm test", timeout_s: 600 }; runs the MR's own code
    constraints: []                        # e.g. - "Public DTOs change only in backward-compatible ways"
    path_instructions: []                  # e.g. - { paths: ["**/*.generated.ts"], ignore: true }
    roles: { off: [], add: [] }            # project roles live in projects/<id>/skills/review-<role>/SKILL.md
    review: {}                             # e.g. { max_inline: 5, max_inline_medium: 3, models: { verifier: provider/model } }
    # pi:                                  # your Pi set-up in every run of this project (akit review pi lists it)
    #   flags: ["--exclude-tools", "find"]
    #   steps: ["/run reviewer", { run: "/skill:security-audit", max_findings: 3 }]

    """
}

/// Send Drafts…: what goes to GitLab, then what GitLab answered.
struct SendDraftsSheet: View {
    @Environment(ReviewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let run: ReviewWorkflow.Run
    let approved: [ReviewRequest]
    @State private var sending = false
    @State private var report: ReviewWorkflow.SendReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report == nil ? "Send \(approved.count) drafts to GitLab?" : "Sent").font(.title3.weight(.semibold))
            if sending {
                ProgressView("Pi writes the drafts through your GitLab MCP server…").controlSize(.small)
            }
            if let report {
                if !report.sent.isEmpty {
                    Label("\(report.sent.count) added to your pending review as drafts.", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                ForEach(report.failed, id: \.id) { failure in
                    Label("\(failure.id): \(failure.message)", systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled)
                }
                Text("Open the merge request in GitLab, check the drafts beside your own comments, and publish them with Submit review.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Pi adds them to your own pending review as draft notes, with your GitLab MCP server. AKit lets through only these texts, word for word. Nobody sees them until you press Submit review in GitLab; nothing is published.")
                    .foregroundStyle(.secondary)
                List(approved) { request in
                    HStack {
                        Text(request.kind.rawValue).font(.caption.weight(.semibold)).frame(width: 60, alignment: .leading)
                        Text(request.file.map { "\($0)\(request.line.map { ":\($0)" } ?? "")" } ?? "the merge request").font(.callout.monospaced())
                        Spacer()
                        if request.edited != nil { Text("edited").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .frame(minHeight: 160)
            }
            HStack {
                if let url = URL(string: run.spec.mergeRequest.url), report != nil {
                    Link("Open in GitLab", destination: url)
                }
                Spacer()
                if report == nil {
                    Button("Cancel") { dismiss() }
                    Button("Send Drafts") {
                        sending = true
                        Task {
                            report = await model.send(approved)
                            sending = false
                            if report == nil { dismiss() }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// Add Missed…: a finding the reviewer should have made (label `missed`).
struct AddMissedSheet: View {
    @Environment(ReviewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The files the change touched: the file to choose from.
    var files: [String] = []
    @State private var file = ""
    @State private var otherFile = false
    @State private var line = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What did the reviewer miss?").font(.title3.weight(.semibold))
            Text("It stays in AKit: it counts against the roles and helps to fix them. It never goes to GitLab.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("File", selection: Binding(get: { otherFile || (!file.isEmpty && !files.contains(file)) ? "\u{1}other" : file },
                                                  set: { value in
                                                      otherFile = value == "\u{1}other"
                                                      if !otherFile { file = value }
                                                  })) {
                    Text("The whole change").tag("")
                    ForEach(Array(Set(files)).sorted(), id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("Other…").tag("\u{1}other")
                }
                if otherFile || (!file.isEmpty && !files.contains(file)) {
                    TextField("Path", text: $file, prompt: Text("src/…"))
                }
                TextField("Line", text: $line).frame(width: 70)
            }
            TextEditor(text: $text).frame(minHeight: 100).overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    model.addMissed(file: file, line: Int(line), text: text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// Log…: what the run did, for analysis (`ReviewRunLog`, `akit review log`): each pass's model,
/// thinking, time, tokens and credits, what each role's findings became, the MCP calls and the
/// calls AKit blocked. Copy for Analysis puts it on the clipboard as Markdown.
struct ReviewRunLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let folder: URL
    @State private var log: ReviewRunLog?
    @State private var problem: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run Log").font(.title3.weight(.semibold))
            if let log {
                content(log)
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    .help("The run folder: passes.json, the Pi sessions, mcp/calls, prompts and the context pack")
                Button(copied ? "Copied" : "Copy for Analysis") {
                    guard let log else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.markdown, forType: .string)
                    copied = true
                }
                .disabled(log == nil)
                .help("The log as Markdown, without secrets, MCP arguments or the servers' answers: paste it to a model or a note")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 1000, idealWidth: 1080, minHeight: 560, idealHeight: 680)
        .task {
            // Every saved MCP answer is decoded: off the main thread.
            let folder = folder
            let result = await Task.detached { Result { try ReviewRunLog.load(folder) } }.value
            switch result {
            case .success(let loaded): log = loaded
            case .failure(let error): problem = error.localizedDescription
            }
        }
    }

    @ViewBuilder private func content(_ log: ReviewRunLog) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(log.target + (log.head.map { " at \($0.prefix(10))" } ?? "") + " · scenario \(log.scenario)")
            Text("Passes: " + model(log.passesModel, log.passesThinking) + " · verifier: " + model(log.verifierModel, log.verifierThinking))
            Text(totals(log))
        }
        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        Table(log.passes) {
            TableColumn("Pass") { pass in
                Label(pass.name, systemImage: pass.error == nil ? (pass.seconds == nil ? "circle.dotted" : "checkmark.circle") : "xmark.circle")
                    .foregroundStyle(pass.error == nil ? Color.primary : Color.red)
                    .help(pass.error ?? pass.name)
            }
            .width(min: 110, ideal: 140)
            TableColumn("Model") { pass in Text(pass.model.isEmpty ? "Pi's default" : pass.model).help(pass.model) }.width(min: 120, ideal: 180)
            TableColumn("Thinking") { pass in Text(pass.thinking.isEmpty ? "—" : pass.thinking) }.width(60)
            TableColumn("Time") { pass in Text(ReviewRunLog.duration(pass.seconds)).monospacedDigit() }.width(60)
            TableColumn("In / cached / out") { pass in
                Text("\(ReviewRunLog.tokens(pass.usage.input)) / \(ReviewRunLog.tokens(pass.usage.cached)) / \(ReviewRunLog.tokens(pass.usage.output))")
                    .monospacedDigit()
            }
            .width(min: 110, ideal: 125)
            TableColumn("Credits") { pass in Text(String(format: "%.1f", pass.credits)).monospacedDigit() }.width(55)
            TableColumn("Files") { pass in Text("\(pass.filesRead)").monospacedDigit() }.width(40)
            TableColumn("MCP") { pass in
                Text("\(pass.mcpCalls)" + (pass.mcpErrors > 0 ? " (\(pass.mcpErrors) failed)" : "") + (pass.blocked > 0 ? " · \(pass.blocked) blocked" : ""))
                    .foregroundStyle(pass.mcpErrors + pass.blocked > 0 ? Color.orange : Color.primary)
            }
            .width(min: 50, ideal: 90)
            TableColumn("Session") { pass in
                if let session = pass.session {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([folder.appending(path: session)]) }
                        .buttonStyle(.link)
                        .help("The Pi session file of this pass: every prompt, answer and tool call")
                }
            }
            .width(60)
        }
        .frame(minHeight: 200)
        HStack(alignment: .top, spacing: 16) {
            if !log.roles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Findings by role").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                        GridRow {
                            ForEach(["Role", "Found", "Confirmed", "Rejected", "Questions", "Merged", "Before MR", "Inline"], id: \.self) {
                                Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(log.roles, id: \.role) { role in
                            GridRow {
                                Text(role.role)
                                Text("\(role.found)")
                                Text("\(role.confirmed)")
                                Text("\(role.rejected)")
                                Text("\(role.questions)")
                                Text("\(role.merged)")
                                Text("\(role.preExisting)")
                                Text("\(role.inline)")
                            }
                        }
                    }
                    .font(.callout.monospacedDigit())
                }
            }
            Spacer(minLength: 0)
        }
        if !log.calls.isEmpty || !log.blocked.isEmpty {
            List {
                if !log.blocked.isEmpty {
                    Section("Blocked by AKit (\(log.blocked.count))") {
                        ForEach(Array(log.blocked.enumerated()), id: \.offset) { _, item in
                            Text("\(item.pass) · \(item.tool): \(item.reason)").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }
                }
                if !log.calls.isEmpty {
                    Section("MCP calls (\(log.calls.count))") {
                        ForEach(Array(log.calls.enumerated()), id: \.offset) { _, call in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(call.pass) · \(call.tool)" + (call.isError ? " · failed" : "") + " · answer \(call.answer) chars")
                                    .foregroundStyle(call.isError ? Color.red : Color.primary)
                                Text(call.input).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .font(.callout)
                            .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(minHeight: 140)
        }
    }

    private func totals(_ log: ReviewRunLog) -> String {
        var parts = [String(format: "%.1f of %d credits", log.credits, log.cap)]
        if let estimate = log.estimate { parts[0] += String(format: " (estimated %.0f)", estimate) }
        parts.append("\(log.passes.count) passes")
        parts.append(ReviewRunLog.duration(log.seconds))
        parts.append("MCP: \(log.calls.count) calls" + (log.calls.isEmpty ? "" : " (\(log.callsByServer))"))
        if !log.blocked.isEmpty { parts.append("\(log.blocked.count) blocked") }
        return parts.joined(separator: " · ")
    }

    private func model(_ model: String, _ thinking: String) -> String {
        (model.isEmpty ? "Pi's default model" : model) + (thinking.isEmpty ? "" : ", thinking \(thinking)")
    }
}

/// A field's label with a red asterisk: the form can't go on without it.
extension ReviewImpact {
    var title: String {
        switch self {
        case .auto: "Auto"
        case .off: "Off"
        case .always: "Always"
        }
    }
}

/// Other repositories (`impact`, R42): whether the review looks for uses of the change in other
/// GitLab repositories. nil: the level above decides.
struct ReviewImpactPicker: View {
    @Binding var selection: ReviewImpact?
    let empty: String

    var body: some View {
        Picker(selection: $selection) {
            Text(empty).tag(ReviewImpact?.none)
            ForEach(ReviewImpact.allCases, id: \.self) { Text($0.title).tag(ReviewImpact?.some($0)) }
        } label: {
            Text("Other repositories")
        }
        .help("Auto: when the change has a boundary (an API, a micro-frontend, a shared package, an event, a config key), Pi searches GitLab through its MCP server "
              + "for the other repositories that use it, first in the group, then in the whole GitLab. Always: also when the brief found no boundary. "
              + "Off: never. Only reading tools; nothing is written to other repositories.")
    }
}

/// Summary language (`summary_language`, R46): the language of the overview in AKit. GitLab
/// comments keep the posting language.
struct ReviewLanguagePicker: View {
    @Binding var selection: LabLanguage?
    let empty: String

    var body: some View {
        Picker(selection: $selection) {
            Text(empty).tag(LabLanguage?.none)
            ForEach(LabLanguage.allCases, id: \.self) { Text($0.name).tag(LabLanguage?.some($0)) }
        } label: {
            Text("Summary language")
        }
        .help("The language of the run's Overview and the flow's labels. It stays in AKit: comments for GitLab keep the posting language.")
    }
}

struct RequiredLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        (Text(title) + Text(" *").foregroundColor(.red))
            .help("Required")
    }
}

/// One of Pi's models to choose (`pi --list-models`), with what an empty choice means first. A
/// model not in Pi's list (the list failed, an offline provider) is typed under **Other…**,
/// unless `allowsOther` is off: then only the listed models can be picked.
struct PiModelPicker<Label: View>: View {
    @Binding var selection: String
    let models: [String]
    let empty: String
    var help = "Models Pi has credentials for (pi --list-models); Other… to type one"
    var allowsOther = true
    @ViewBuilder let label: () -> Label
    @State private var other = false

    private static var otherTag: String { "\u{1}other" }

    var body: some View {
        Picker(selection: Binding(get: { !allowsOther && !models.contains(selection) ? ""
                                      : other || (!selection.isEmpty && !models.contains(selection)) ? Self.otherTag : selection },
                                  set: { value in
                                      other = value == Self.otherTag
                                      if !other { selection = value }
                                  })) {
            Text(empty).tag("")
            ForEach(models, id: \.self) { Text($0).tag($0) }
            if allowsOther {
                Divider()
                Text("Other…").tag(Self.otherTag)
            }
        } label: {
            label()
        }
        .help(help)
        if allowsOther, other || (!selection.isEmpty && !models.contains(selection)) {
            TextField("Model", text: $selection, prompt: Text("provider/model"))
        }
    }
}
