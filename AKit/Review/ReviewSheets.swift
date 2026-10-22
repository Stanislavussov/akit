import AKitFoundation
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
    @State private var notes = ""
    @State private var links = ""
    @State private var extraServers: Set<String> = []
    @State private var catalog: ReviewCatalog?

    private var mr: MergeRequestRef? { MergeRequestRef.parse(address) }
    private var profile: ReviewProfile? {
        switch source {
        case .mergeRequest: catalog?.profile(for: mr)
        case .local: inspection.flatMap { inspection in catalog.flatMap { ReviewLocal.profile(for: inspection, in: $0, env: model.env) } }
        }
    }
    /// The links as a run takes them, or why not.
    private var checkedLinks: Result<[String], Error> { Result { try ReviewContext.links([links]) } }
    /// The project's MCP rules (or the defaults): its own servers and its context servers.
    private var access: ReviewMCPAccess { profile?.mcp ?? ReviewMCPAccess() }
    private var canStart: Bool {
        guard !model.isBusy, (try? checkedLinks.get()) != nil else { return false }
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
                    TextField("Merge request", text: $address, prompt: Text("https://gitlab.example.com/group/project/-/merge_requests/12"))
                    if !address.isEmpty, mr == nil {
                        Text("Paste the merge request's address from GitLab.").font(.caption).foregroundStyle(.red)
                    } else if let mr {
                        Text(profile.map { "Project profile: \($0.project) (\($0.slug).yaml)" }
                             ?? "No project profile for \(mr.projectPath): no checkout, tracker or project rules. Review Settings… adds one.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Work items", text: $workItems, prompt: Text("e.g. 4512, 4513 (else found in the title, description and branch)"))
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
                Section("This run only") {
                    TextField("Model for the brief and roles", text: $passesModel, prompt: Text("provider/model, e.g. github-copilot/… (empty: from the configuration)"))
                    TextField("Verifier model", text: $verifierModel, prompt: Text("a strong model (empty: from the configuration)"))
                    TextField("Credit cap", text: $cap, prompt: Text("empty: from the configuration"))
                }
            }
            .formStyle(.grouped)
            HStack {
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
        .task(id: "\(source.rawValue)|\(workspace)|\(baseRef)") { await inspect() }
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
                TextField("Workspace", text: $workspace, prompt: Text("a git worktree of Orca or herdr, or any clone"))
                Button("Choose…") { chooseWorkspace() }
            }
            TextField("Base", text: $baseRef, prompt: Text("empty: the default branch (origin/HEAD, main or master)"))
            if let problem = inspectionProblem {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if let inspection {
                Text("\(inspection.branch) at \(inspection.head.prefix(10)) · base \(inspection.baseRef ?? "none")").font(.caption.monospaced())
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
            Text("In a terminal of the workspace: akit review local . (--what commits | uncommitted, --base REF).")
                .font(.caption).foregroundStyle(.secondary)
        }
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
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        let base = baseRef.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let found = try await ReviewLocal.inspect(path: model.env.expand(path), baseRef: base.isEmpty ? nil : base, env: model.env)
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
        if !verifierModel.isEmpty { choices.settings.verifier = ReviewModelChoice(model: verifierModel) }
        if let value = Int(cap), value > 0 { choices.settings.capCredits = value }
        choices.notes = notes
        choices.links = (try? checkedLinks.get()) ?? []
        choices.extraServers = extraServers.sorted()
        if source == .local, let inspection {
            model.startLocal(inspection, mode: mode, project: profile?.slug, choices: choices, brain: brain)
        } else if let mr {
            model.start(mr: mr, project: profile?.slug, choices: choices, brain: brain)
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
                } header: {
                    Text("Pi's MCP servers")
                } footer: {
                    Text("Pi connects to GitLab, Azure DevOps and your other trackers with the MCP servers in its own settings; AKit keeps no tokens. A review reads with their reading tools, writes only the drafts you approved, word for word, and never publishes, approves, merges or resolves. A profile's mcp: names the servers and tools it may use; a Context server (Figma, Confluence, a wiki) is added on top and only reads.")
                        .font(.caption).foregroundStyle(.secondary)
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
        .task { catalog = model.catalog(brain: brain) }
        .onChange(of: rules) { extras = access.extraServers }
        .sheet(item: Binding(get: { save.map(SaveBox.init) }, set: { save = $0?.save })) { box in
            ReviewSaveSheet(save: box.save, brain: brain) { saved in
                save = nil
                if saved {
                    catalog = model.catalog(brain: brain)
                    extras = access.extraServers
                    message = "Saved the context servers in \(box.save.file.lastPathComponent)."
                }
            }
        }
    }

    private struct SaveBox: Identifiable {
        let save: ReviewConfigEditor.Save
        var id: String { save.file.path }
    }

    /// One of Pi's servers as this profile's review sees it; a server that isn't GitLab or the
    /// tracker can be ticked as a context server.
    @ViewBuilder private func serverRow(_ server: ReviewMCPCheck.Server) -> some View {
        let kinds = server.tools.map { (name: $0.name, kind: ReviewMCPPolicy.kind(server: server.name, tool: $0.name, access: effective)) }
        let base = effective.isBase(server: server.name)
        let context = effective.isExtra(server: server.name)
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
                } else {
                    Text("not used by this project").font(.caption).foregroundStyle(.secondary)
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
    # tracker: { kind: azure-devops, org: my-org, project: MyProject, wi_ref_regex: "(?:AB#|WI-)(\\\\d+)" }
    # mcp:                                 # Pi's MCP servers review may use (pi mcp list); none = those named gitlab, azure, devops, ado
    #   servers: [gitlab, azure-devops]
    #   read: []                           # more reading tools, e.g. ["wit_get_*"]; get_/list_/search_… read anyway
    #   write: ["*draft_note*"]            # the tools Send Drafts may call; only approved text passes
    #   in_passes: true                    # the brief, roles and verifier may read through MCP too
    #   extra_servers: [figma]             # context servers on top (Figma, Confluence, a wiki): read only, in every run
    default_scenario: feature              # feature, bugfix, dependency-upgrade
    knowledge: []                          # markdown folders, e.g. [~/notes/my-service]
    gather: []                             # e.g. - { name: tests, run: "npm test", timeout_s: 600 }; runs the MR's own code
    constraints: []                        # e.g. - "Public DTOs change only in backward-compatible ways"
    path_instructions: []                  # e.g. - { paths: ["**/*.generated.ts"], ignore: true }
    roles: { off: [], add: [] }            # project roles live in projects/<id>/skills/review-<role>/SKILL.md
    review: {}                             # e.g. { max_inline: 5, confidence_threshold: 0.85 }

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
    @State private var file = ""
    @State private var line = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What did the reviewer miss?").font(.title3.weight(.semibold))
            Text("It stays in AKit: it counts against the roles and helps to fix them. It never goes to GitLab.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("File", text: $file, prompt: Text("src/…"))
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
