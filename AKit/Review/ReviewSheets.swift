import AKitFoundation
import AKitReview
import AppKit
import SwiftUI

/// New Review…: the merge request, the scenario and roles, models and the cap for this run.
struct NewReviewSheet: View {
    @Environment(ReviewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let brain: URL
    @State private var address = DebugSnapshot.options?.query ?? ""
    @State private var workItems = ""
    @State private var scenario = ""
    @State private var rolesOn: Set<String> = []
    @State private var rolesOff: Set<String> = []
    @State private var passesModel = ""
    @State private var verifierModel = ""
    @State private var cap = ""
    @State private var catalog: ReviewCatalog?

    private var mr: MergeRequestRef? { MergeRequestRef.parse(address) }
    private var profile: ReviewProfile? { catalog?.profile(for: mr) }
    private var scenarios: [ReviewScenario] { catalog?.scenarios(for: profile) ?? [] }
    private var chosen: ReviewScenario? { scenarios.first { $0.id == scenario } }
    private var roles: [ReviewRole] { catalog?.roles(for: profile) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
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
                Section("This run only") {
                    TextField("Model for the brief and roles", text: $passesModel, prompt: Text("provider/model, e.g. github-copilot/… (empty: from the configuration)"))
                    TextField("Verifier model", text: $verifierModel, prompt: Text("a strong model (empty: from the configuration)"))
                    TextField("Credit cap", text: $cap, prompt: Text("empty: from the configuration"))
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("Pi reads the merge request and its work items through its MCP servers, only with reading tools. Nothing is written to GitLab here.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start Review") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mr == nil || model.isBusy)
            }
            .padding()
        }
        .frame(width: 620, height: 640)
        .task {
            catalog = model.catalog(brain: brain)
            scenario = scenario.isEmpty ? (profile?.defaultScenario ?? "feature") : scenario
        }
        .onChange(of: address) {
            if let preset = profile?.defaultScenario { scenario = preset }
        }
    }

    private func start() {
        guard let mr else { return }
        var choices = ReviewRunChoices(scenario: scenario.isEmpty ? nil : scenario, rolesOn: Array(rolesOn), rolesOff: Array(rolesOff))
        choices.workItems = workItems.split(whereSeparator: { ", #".contains($0) }).compactMap { Int($0) }
        if !passesModel.isEmpty { choices.settings.passes = ReviewModelChoice(model: passesModel) }
        if !verifierModel.isEmpty { choices.settings.verifier = ReviewModelChoice(model: verifierModel) }
        if let value = Int(cap), value > 0 { choices.settings.capCredits = value }
        model.start(mr: mr, project: profile?.slug, choices: choices, brain: brain)
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

    private var access: ReviewMCPAccess { catalog?.profiles.first { $0.slug == rules }?.mcp ?? ReviewMCPAccess() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    HStack {
                        Picker("Rules of", selection: $rules) {
                            Text("Default").tag("")
                            ForEach(catalog?.profiles ?? [], id: \.slug) { Text($0.project).tag($0.slug) }
                        }
                        Button(model.checkingMCP ? "Checking…" : "Check Servers") { model.checkMCP(access: access) }
                            .disabled(model.checkingMCP)
                    }
                    if let report = model.mcpReport {
                        if report.servers.isEmpty {
                            Text("Pi has no MCP servers. Add your GitLab and tracker servers to Pi (pi mcp add …, or the MCP screen).")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        ForEach(report.servers) { server in
                            let used = access.servers.isEmpty
                                || access.servers.map(ReviewMCPPolicy.normalized).contains(ReviewMCPPolicy.normalized(server.name))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Image(systemName: server.state == "connected" && server.enabled ? "circle.fill" : "circle")
                                        .foregroundStyle(server.state == "connected" && server.enabled ? .green : .secondary).font(.caption2)
                                    Text(server.name)
                                    Text(server.enabled ? server.state : "disabled").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if used {
                                        Text("\(server.count(.read)) read · \(server.count(.write)) write drafts · \(server.count(.blocked)) blocked")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("not used by this project").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                let writes = server.tools.filter { $0.kind == .write }.map(\.name)
                                if used, !writes.isEmpty {
                                    Text("Send Drafts may call: " + writes.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        ForEach(report.errors, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    }
                    if let problem = model.mcpProblem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Pi's MCP servers")
                } footer: {
                    Text("Pi connects to GitLab, Azure DevOps and your other trackers with the MCP servers in its own settings; AKit keeps no tokens. A review reads with their reading tools, writes only the drafts you approved, word for word, and never publishes, approves, merges or resolves. A profile's mcp: names the servers and tools it may use.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(catalog?.profiles ?? [], id: \.slug) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.project)
                                Text("\(profile.gitlabHost)/\(profile.gitlabProjectPath)"
                                     + (profile.mcp.servers.isEmpty ? "" : " · MCP: " + profile.mcp.servers.joined(separator: ", ")))
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
    # mcp:                                 # Pi's MCP servers review may use (pi mcp list); none = every server
    #   servers: [gitlab, azure-devops]
    #   read: []                           # more reading tools, e.g. ["wit_get_*"]; get_/list_/search_… read anyway
    #   write: ["*draft_note*"]            # the tools Send Drafts may call; only approved text passes
    #   in_passes: true                    # the brief, roles and verifier may read through MCP too
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
