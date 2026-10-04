import AKitFoundation
import AKitMCP
import AKitMCPCatalog
import AKitModel
import SwiftUI

/// Sheet for adding, editing or deleting an MCP server: fill the form, paste JSON or pick a
/// server from the catalog, choose where it goes, check the diff, Apply. Secret values go to the Keychain, never into the file.
struct MCPServerEditor: View {
    enum Mode {
        /// New server; the project preselects where it goes (the MCP screen's filter).
        /// `catalog` opens the sheet on the catalog search.
        case add(project: URL?, catalog: Bool = false)
        case edit(MCPServer)
        case remove(MCPServer)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    init(mode: Mode) {
        self.mode = mode
        // The sheet is made once per request, so this seeds the tab once.
        if case .add(_, true) = mode { _input = State(initialValue: .catalog) } else { _input = State(initialValue: .form) }
    }

    private enum Input: String, CaseIterable { case form = "Form", json = "JSON", catalog = "Catalog" }

    @State private var input: Input
    @State private var catalogQuery = DebugSnapshot.options?.tab == "catalog" ? DebugSnapshot.options?.query ?? "" : ""
    @State private var draft = MCPDraft()
    @State private var argumentLine = ""
    @State private var json = ""
    @State private var jsonError: String?
    @State private var pasted: [MCPDraft] = []
    /// The form was filled from the catalog: what each value is for, shown above the form.
    @State private var catalogNotes: [String] = []
    /// The form came from the catalog: its `{placeholders}` must be replaced before Preview.
    @State private var fromCatalog = false
    @State private var targets: [MCPWriteTarget] = []
    @State private var targetID: MCPWriteTarget.ID?
    @State private var secretMode: MCPSecretMode = .keychainLookup
    @State private var plan: MCPWritePlan?
    @State private var error: String?
    @State private var isApplying = false
    @State private var done: MCPWriter.Outcome?
    /// Editing: the file text the form was filled from.
    @State private var openedText: String?

    var body: some View {
        VStack(spacing: 0) {
            if let done {
                finished(done)
            } else if let plan {
                preview(plan)
            } else if case .remove = mode {
                VStack(spacing: 12) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        ProgressView()
                    }
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                editor
            }
        }
        .frame(width: 680, height: 640)
        .onAppear(perform: loadTargets)
        // Opened before the first scan finished: fill the places once it has.
        .onChange(of: model.lastScan) { if targets.isEmpty { loadTargets() } }
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editing == nil ? "Add MCP Server" : "Edit “\(editing!.name)”").font(.title2.bold())
                Spacer()
                if editing == nil {
                    Picker("Input", selection: $input) {
                        ForEach(Input.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                }
            }
            .padding([.horizontal, .top], 20)

            switch input {
            case .form: form
            case .json: jsonInput
            case .catalog: MCPCatalogPane(onUse: useCatalog, query: $catalogQuery)
            }
            Divider()
            footer
        }
    }

    private var form: some View {
        Form {
            if !catalogNotes.isEmpty {
                Section("From the Catalog") {
                    ForEach(catalogNotes, id: \.self) { note in
                        Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Section {
                TextField("Name", text: $draft.name, prompt: Text("grafana"))
                Picker("Transport", selection: $draft.transport) {
                    Text("Local command (stdio)").tag(MCPDraft.Transport.stdio)
                    Text("Remote (HTTP)").tag(MCPDraft.Transport.http)
                    Text("Remote (SSE)").tag(MCPDraft.Transport.sse)
                }
                if draft.transport == .stdio {
                    TextField("Command", text: $draft.command, prompt: Text("npx"))
                    TextField("Arguments", text: $argumentLine, prompt: Text("-y @scope/server --flag"))
                        .onChange(of: argumentLine) { draft.arguments = MCPDraft.splitArguments(argumentLine) }
                } else {
                    TextField("URL", text: $draft.url, prompt: Text("https://example.com/mcp"))
                }
            }
            if draft.transport == .stdio {
                values("Environment", $draft.environment, keyPrompt: "NAME")
            } else {
                values("Headers", $draft.headers, keyPrompt: "Authorization")
            }
            Section("Where") {
                if editing == nil {
                Picker("Add to", selection: $targetID) {
                    ForEach(targetGroups, id: \.scope) { group in
                        Section(group.title) {
                            ForEach(group.targets) { target in
                                Text(targetTitle(target)).tag(Optional(target.id))
                            }
                        }
                    }
                }
                } else if let target = selectedTarget {
                    LabeledContent("File", value: targetTitle(target))
                }
                if let target = selectedTarget {
                    Text(target.file.tildePath + (target.claudeScope.map { " · written by claude mcp add-json --scope \($0)" } ?? ""))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let reason = target.blockedReason {
                        Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    if let reason = target.inactiveReason {
                        Label("Not loaded now: \(reason)", systemImage: "info.circle").foregroundStyle(.secondary)
                    }
                }
                if hasSecrets {
                    Picker("Secrets", selection: $secretMode) {
                        Text("Read from the Keychain by the config (this Mac)").tag(MCPSecretMode.keychainLookup)
                        Text("${VAR} reference, exported by ~/.akit/env.sh").tag(MCPSecretMode.environment)
                    }
                    Text((secretMode == .keychainLookup
                         ? "Works however the harness is started. The file names a Keychain item that exists only on this Mac."
                         : "Keeps the file portable for a team. The harness sees the value only when started from a shell that sources ~/.akit/env.sh.")
                         + " Keeps secrets out of files and git; programs running as you can still read them with /usr/bin/security.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: targetID) { secretMode = selectedTarget?.isShared == true ? .environment : .keychainLookup }
    }

    private func values(_ title: String, _ list: Binding<[MCPDraft.Value]>, keyPrompt: String) -> some View {
        Section {
            ForEach(list) { $value in
                HStack {
                    TextField("Name", text: $value.key, prompt: Text(keyPrompt))
                        .font(.body.monospaced())
                        .frame(minWidth: 160, idealWidth: 270, maxWidth: 300)
                    Group {
                        if let account = value.keychainAccount {
                            SecureField("Value", text: $value.value, prompt: Text("Keychain: \(account) (unchanged)"))
                        } else if value.hasHiddenValue {
                            SecureField("Value", text: $value.value, prompt: Text("unchanged (hidden)"))
                        } else if value.isSecret {
                            SecureField("Value", text: $value.value, prompt: Text("secret"))
                        } else {
                            TextField("Value", text: $value.value, prompt: Text("value or ${VAR}"))
                        }
                    }
                    .font(.body.monospaced())
                    Toggle("Secret", isOn: $value.isSecret)
                        .toggleStyle(.checkbox)
                        .help(value.hasHiddenValue && value.value.isEmpty
                              ? "Move the value written in the file into the Keychain"
                              : "Store the value in the Keychain instead of the file")
                    Button("Remove", systemImage: "minus.circle") {
                        list.wrappedValue.removeAll { $0.id == value.id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
                .labelsHidden()
            }
            Button("Add", systemImage: "plus") { list.wrappedValue.append(MCPDraft.Value()) }
                .buttonStyle(.borderless)
        } header: {
            Text(title)
        }
    }

    private var jsonInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste a config from a README: `{\"mcpServers\": {…}}`, `\"name\": {…}` or one server object.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $json)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            if let jsonError {
                Label(jsonError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if pasted.count > 1 {
                HStack {
                    Text("Several servers found. Fill the form with:")
                    ForEach(pasted, id: \.name) { server in
                        Button(server.name) { use(server) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Fill the Form") { readJSON() }
                    .disabled(json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Preview…") { makePlan() }
                .keyboardShortcut(.defaultAction)
                .disabled(input != .form || selectedTarget == nil)
        }
        .padding(16)
    }

    // MARK: - Preview

    private func preview(_ plan: MCPWritePlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(planTitle(plan)).font(.title2.bold())
            Text("\(targetTitle(plan.target)) · \(plan.target.file.tildePath)")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            if !plan.secretNames.isEmpty {
                Label("Keychain (service “\(KeychainSecretStore.service)”): \(plan.secretNames.joined(separator: ", "))",
                      systemImage: "key.fill")
            }
            ForEach(plan.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            ForEach(plan.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if plan.diff.isEmpty {
                        Text(plan.entryJSON).padding(.horizontal, 4)
                    } else {
                        DiffPreview(diff: plan.diff)
                    }
                }
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3)
                }
                Spacer()
                if case .remove = mode {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Back") { self.plan = nil; error = nil }
                        .keyboardShortcut(.cancelAction)
                }
                Button(plan.isRemoval ? "Delete" : plan.replaces ? "Save" : "Apply", role: plan.isRemoval ? .destructive : nil) {
                    apply(plan)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying)
            }
        }
        .padding(16)
    }

    private func finished(_ outcome: MCPWriter.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(doneTitle, systemImage: "checkmark.circle.fill")
                .font(.title2.bold())
                .foregroundStyle(.green)
            if let backup = outcome.backup {
                Text("Backup: \(backup.tildePath)").font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ForEach(outcome.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle").textSelection(.enabled)
            }
            Text("Restart the harness (or reload its MCP servers) to pick the change up.")
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: - Actions

    private func loadTargets() {
        targets = model.mcpTargets()
        switch mode {
        case .add(let project, _): preselect(project)
        case .edit(let server):
            guard let target = MCPWriter.target(of: server, in: targets) else {
                if model.lastScan != nil { error = "AKit can't edit this file." }
                return
            }
            targetID = target.id
            if let raw = MCPWriter.rawEntry(of: server, target: target) {
                openedText = raw.fileText
                draft = MCPDraft.editing(name: server.name, entry: raw.entry, dialect: target.dialect, keychain: KeychainSecretStore())
                argumentLine = MCPDraft.joinArguments(draft.arguments)
                let lookups = raw.entry.description.contains("find-generic-password -s '\(KeychainSecretStore.service)'")
                secretMode = lookups ? .keychainLookup : target.isShared ? .environment : .keychainLookup
            } else {
                error = "“\(server.name)” is no longer in \(target.file.tildePath)."
            }
        case .remove(let server):
            guard let target = MCPWriter.target(of: server, in: targets) else {
                if model.lastScan != nil { error = "AKit can't edit this file." }
                return
            }
            targetID = target.id
            do {
                plan = try MCPWriter.removalPlan(server.name, from: target, home: HarnessEnvironment.current.homeDirectory)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func preselect(_ project: URL?) {
        let projectTarget = project.flatMap { project in
            targets.first { target in
                guard case .project(let url) = target.scope else { return false }
                return target.isShared && url.standardizedFileURL.path == project.standardizedFileURL.path
            }
        }
        targetID = (projectTarget ?? targets.first { $0.blockedReason == nil })?.id
        secretMode = selectedTarget?.isShared == true ? .environment : .keychainLookup
        // Snapshot mode: `--query <json>` fills the form, `--tab preview` shows the plan.
        if let options = DebugSnapshot.options, !targets.isEmpty, options.tab != "catalog", let text = options.query {
            json = text
            readJSON()
            if options.tab == "preview" { makePlan() }
        }
    }

    private func readJSON() {
        do {
            pasted = try MCPDraft.parse(json: json)
            jsonError = nil
            if pasted.count == 1 { use(pasted[0]) }
        } catch {
            pasted = []
            jsonError = error.localizedDescription
        }
    }

    private func use(_ server: MCPDraft) {
        draft = server
        argumentLine = MCPDraft.joinArguments(server.arguments)
        catalogNotes = []
        fromCatalog = false
        error = nil
        input = .form
    }

    private func useCatalog(_ server: MCPDraft, notes: [String]) {
        use(server)
        catalogNotes = notes
        fromCatalog = true
    }

    private func makePlan() {
        guard let target = selectedTarget else { return }
        // A catalog entry's `{parts}` are for the user to fill; written as they are, the server wouldn't start.
        if fromCatalog, let open = CatalogDraft.problems(in: draft).first {
            error = open
            return
        }
        do {
            plan = try MCPWriter.plan(draft, into: target, secretMode: secretMode, replacing: editing?.name,
                                      openedText: openedText, keychain: KeychainSecretStore(),
                                      home: HarnessEnvironment.current.homeDirectory)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ plan: MCPWritePlan) {
        isApplying = true
        Task {
            defer { isApplying = false }
            do {
                done = try await model.applyMCP(plan)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    private var selectedTarget: MCPWriteTarget? { targets.first { $0.id == targetID } }

    private var editing: MCPServer? {
        if case .edit(let server) = mode { return server }
        return nil
    }

    private func planTitle(_ plan: MCPWritePlan) -> String {
        if plan.isRemoval { return "Delete “\(plan.name)”" }
        if let original = plan.originalName, original != plan.name { return "Rename “\(original)” to “\(plan.name)”" }
        return plan.replaces ? "Save “\(plan.name)”" : "Add “\(plan.name)”"
    }

    private var doneTitle: String {
        guard let plan else { return "Done" }
        if plan.isRemoval { return "Deleted “\(plan.name)”" }
        return plan.replaces || plan.originalName != nil ? "Saved “\(plan.name)”" : "Added “\(plan.name)”"
    }

    private var hasSecrets: Bool {
        draft.activeValues.contains(where: \.isSecret)
    }

    /// Global first, then projects by name; the folder path tells same-named projects apart.
    private var targetGroups: [(scope: SkillScope, title: String, targets: [MCPWriteTarget])] {
        Dictionary(grouping: targets, by: \.scope)
            .map { scope, targets in
                var title = scope.title
                if case .project(let url) = scope { title += "  (\(url.deletingLastPathComponent().tildePath))" }
                return (scope: scope, title: title, targets: targets)
            }
            .sorted { ($0.scope == .global ? 0 : 1, $0.title) < ($1.scope == .global ? 0 : 1, $1.title) }
    }

    private func targetTitle(_ target: MCPWriteTarget) -> String {
        let who = target.harnesses.map(\.displayName).joined(separator: ", ")
        return "\(who) · \(target.layer) (\(target.file.lastPathComponent))" + (target.inactiveReason == nil ? "" : " – not loaded")
    }
}
