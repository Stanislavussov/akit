import AKitFoundation
import AKitMCP
import AKitModel
import AppKit
import SwiftUI

/// MCP screen: every MCP server the installed harnesses have configured, grouped by where
/// it lives. Values of env variables and headers are never shown, only `${VAR}` references.
struct MCPView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: MCPServer.ID?
    @State private var query = DebugSnapshot.options?.add == true ? "" : DebugSnapshot.options?.query ?? ""
    @State private var editor: EditorRequest? = DebugSnapshot.options?.add == true
        ? EditorRequest(mode: .add(project: nil, catalog: DebugSnapshot.options?.tab == "catalog")) : nil

    var body: some View {
        @Bindable var model = model
        HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
            Group {
                if let server = model.mcpServers.first(where: { $0.id == selection }) {
                    MCPServerDetailView(server: server,
                                        onEdit: { editor = EditorRequest(mode: .edit(server)) },
                                        onDelete: { editor = EditorRequest(mode: .remove(server)) })
                } else {
                    ContentUnavailableView("Select a server", systemImage: "server.rack")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("MCP Servers")
        .navigationSubtitle(subtitle)
        .searchable(text: $query, placement: .toolbar, prompt: "Name, command or URL")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Picker("Show", selection: $model.mcpFilter) {
                        Text("All Servers").tag(SkillsFilter.all)
                        Text("Global Only").tag(SkillsFilter.global)
                    }
                    .pickerStyle(.inline)
                    if !projects.isEmpty {
                        Picker("Project", selection: $model.mcpFilter) {
                            ForEach(projects, id: \.url) { project in
                                Text("\(project.url.lastPathComponent)  (\(project.count))").tag(SkillsFilter.project(project.url))
                            }
                        }
                        .pickerStyle(.inline)
                    }
                } label: {
                    Label(filterTitle, systemImage: filterIcon)
                        .labelStyle(.titleAndIcon)
                }
                .fixedSize()
                .help(filterHelp)
            }
            ToolbarItem(placement: .navigation) {
                Menu {
                    Picker("Harness", selection: $model.mcpHarness) {
                        Text("All Harnesses").tag(String?.none)
                        Divider()
                        ForEach(model.installations) { harness in
                            Text(harness.displayName).tag(Optional(harness.id.rawValue))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(harnessTitle, systemImage: "cpu")
                        .labelStyle(.titleAndIcon)
                }
                .fixedSize()
                .help(model.mcpHarness == nil ? "Showing servers of every harness" : "Showing only servers \(harnessTitle) reads")
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.isScanning)
                    .help("Rescan config files (⌘R)")
            }
            ToolbarItem {
                Button("Catalog…", systemImage: "books.vertical") {
                    editor = EditorRequest(mode: .add(project: chosenProject, catalog: true))
                }
                .help("Find a server in the public MCP catalogs and fill the Add Server form from it")
            }
            ToolbarItem {
                Button("Add Server…", systemImage: "plus") { editor = EditorRequest(mode: .add(project: chosenProject)) }
                    .help("Add an MCP server from a form, pasted JSON or the catalog")
            }
        }
        .sheet(item: $editor) { request in
            MCPServerEditor(mode: request.mode)
        }
        .onAppear {
            if case .project(let chosen) = model.mcpFilter,
               let match = projects.first(where: { $0.url.standardizedFileURL.path == chosen.standardizedFileURL.path }) {
                model.mcpFilter = .project(match.url)
            }
            selection = selection ?? filtered.first?.id
        }
        .onChange(of: model.mcpHarness) { keepSelectionVisible() }
        .onChange(of: model.mcpFilter) { keepSelectionVisible() }
        .onChange(of: model.mcpServers) {
            keepSelectionVisible()
            // Snapshot mode: `--tab edit` / `--tab delete` opens the editor on the first listed server.
            if let tab = DebugSnapshot.options?.tab, editor == nil, let server = filtered.first {
                if tab == "edit" { editor = EditorRequest(mode: .edit(server)) }
                if tab == "delete" { editor = EditorRequest(mode: .remove(server)) }
            }
        }
    }

    private var chosenProject: URL? {
        if case .project(let url) = model.mcpFilter { return url }
        return nil
    }

    private func keepSelectionVisible() {
        if selection.flatMap({ id in filtered.first { $0.id == id } }) == nil { selection = filtered.first?.id }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.scope) { group in
                Section {
                    ForEach(group.servers) { server in
                        MCPServerRow(server: server)
                            .tag(server.id)
                            .contextMenu {
                                if ExternalEditor.appURL != nil {
                                    Button("Open \(server.file.lastPathComponent) in \(ExternalEditor.name)") {
                                        ExternalEditor.open(server.file)
                                    }
                                }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([server.file]) }
                                Divider()
                                Button("Edit…") { editor = EditorRequest(mode: .edit(server)) }
                                    .disabled(!model.canEdit(server))
                                Button("Delete…", role: .destructive) { editor = EditorRequest(mode: .remove(server)) }
                                    .disabled(!model.canEdit(server))
                            }
                    }
                } header: {
                    Text(group.scope.title)
                        .help(projectPath(group.scope) ?? "")
                }
            }
            if !model.mcpProblems.isEmpty {
                Section("Couldn't read") {
                    ForEach(model.mcpProblems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .overlay {
            if !query.isEmpty && filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if model.mcpServers.isEmpty && !model.isScanning {
                ContentUnavailableView("No MCP servers found", systemImage: "server.rack",
                                       description: Text("None of the installed harnesses has an MCP server configured."))
            }
        }
    }

    private var subtitle: String {
        let shown = scoped.count
        let base = shown == model.mcpServers.count ? "\(shown) servers" : "\(shown) of \(model.mcpServers.count) servers"
        return filtered.count == shown ? base : "\(filtered.count) found · " + base
    }

    /// Servers for the chosen project and harness, before the search text.
    private var scoped: [MCPServer] {
        model.mcpServers.filter { server in
            model.mcpFilter.includes(server.scope)
                && (model.mcpHarness.map { id in server.usedBy.contains { $0.rawValue == id } } ?? true)
        }
    }

    private var filtered: [MCPServer] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return scoped }
        return scoped.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || ($0.command ?? "").localizedCaseInsensitiveContains(q)
                || ($0.url ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    private var groups: [(scope: SkillScope, servers: [MCPServer])] {
        Dictionary(grouping: filtered, by: \.scope)
            .map { (scope: $0.key, servers: $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { (rank($0.scope), $0.scope.title) < (rank($1.scope), $1.scope.title) }
    }

    private func rank(_ scope: SkillScope) -> Int {
        if case .project = model.mcpFilter, case .project = scope { return -1 }
        return scope.sortRank
    }

    private func projectPath(_ scope: SkillScope) -> String? {
        if case .project(let url) = scope { return url.tildePath }
        return nil
    }

    /// Known projects plus any that have servers, with their own server count.
    private var projects: [(url: URL, count: Int)] {
        var urls: [String: URL] = [:]
        var counts: [String: Int] = [:]
        for url in model.projects {
            urls[url.standardizedFileURL.path] = url
            counts[url.standardizedFileURL.path, default: 0] += 0
        }
        for server in model.mcpServers {
            guard case .project(let url) = server.scope else { continue }
            let key = url.standardizedFileURL.path
            urls[key] = urls[key] ?? url
            counts[key, default: 0] += 1
        }
        return counts.compactMap { key, count in urls[key].map { (url: $0, count: count) } }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    private var harnessTitle: String {
        guard let id = model.mcpHarness else { return "All Harnesses" }
        return model.installations.first { $0.id.rawValue == id }?.displayName ?? id
    }

    private var filterTitle: String {
        switch model.mcpFilter {
        case .all: "All Servers"
        case .global: "Global Only"
        case .project(let url): "Project · \(url.lastPathComponent)"
        }
    }

    private var filterIcon: String {
        switch model.mcpFilter {
        case .all: "square.stack.3d.up"
        case .global: "globe"
        case .project: "folder"
        }
    }

    private var filterHelp: String {
        switch model.mcpFilter {
        case .all: "Showing every server, from all projects"
        case .global: "Showing only servers every project gets"
        case .project(let url): "Showing what a session in \(url.tildePath) gets: its own servers plus global ones"
        }
    }
}

private struct MCPServerRow: View {
    @Environment(AppModel.self) private var model
    let server: MCPServer

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(server.name).fontWeight(.medium)
                if !model.warnings(of: server).isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Spacer()
                ForEach(server.uses, id: \.harness) { use in
                    HarnessBadge(harness: use.harness)
                        .opacity(use.state.isActive ? 1 : 0.4)
                        .help("\(use.harness.displayName): \(use.state.title)")
                }
            }
            Text(server.summary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}

/// One open editor sheet.
private struct EditorRequest: Identifiable {
    let id = UUID()
    let mode: MCPServerEditor.Mode
}

private struct MCPServerDetailView: View {
    @Environment(AppModel.self) private var model
    let server: MCPServer
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var secretFor: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                info
                if !model.warnings(of: server).isEmpty { warnings }
                harnesses
                if !server.environment.isEmpty { settings("Environment", server.environment) }
                if !server.headers.isEmpty { settings("Headers", server.headers) }
                if !server.variables.isEmpty { variables }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(server.name).font(.title2.bold()).textSelection(.enabled)
            Text(server.transport.title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            if server.isReadOnly {
                Label("Read-only", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.canEdit(server) {
                Button("Edit…", systemImage: "pencil", action: onEdit)
                    .help("Change this server; values in the file stay hidden")
                Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
                    .labelStyle(.iconOnly)
                    .help("Remove this server from \(server.file.tildePath)")
            }
            if ExternalEditor.appURL != nil {
                Button("Open in \(ExternalEditor.name)", systemImage: "arrow.up.forward.app") { ExternalEditor.open(server.file) }
                    .labelStyle(.iconOnly)
                    .help("Open \(server.file.tildePath) in \(ExternalEditor.name)")
            }
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([server.file])
            }
            .labelStyle(.iconOnly)
            .help("Show in Finder")
        }
    }

    private var info: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                label("Defined in")
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.file.tildePath).monospaced()
                    if server.keyPath.count > 1 {
                        Text(server.keyPath.joined(separator: " → ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let command = server.command {
                GridRow {
                    label("Command")
                    Text(([command] + server.arguments).joined(separator: " ")).monospaced()
                }
            }
            if let url = server.url {
                GridRow {
                    label("URL")
                    Text(url).monospaced()
                }
            }
            if let cwd = server.workingDirectory {
                GridRow {
                    label("Folder")
                    Text(cwd).monospaced()
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private var harnesses: some View {
        GroupBox("Used by") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(server.uses, id: \.harness) { use in
                    GridRow {
                        HarnessBadge(harness: use.harness)
                        Text(use.layer).foregroundStyle(.secondary)
                        Label(use.state.title, systemImage: use.state.icon)
                            .foregroundStyle(use.state.isActive ? Color.green : use.state == .disabled ? .secondary : .orange)
                    }
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func settings(_ title: String, _ items: [MCPSetting]) -> some View {
        GroupBox(title) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(items, id: \.key) { item in
                    GridRow {
                        Text(item.key).monospaced().gridColumnAlignment(.leading)
                        switch item.value {
                        case .reference(let text):
                            Text(text).monospaced().foregroundStyle(.secondary)
                        case .command(let command):
                            Text("runs: \(command)").monospaced().foregroundStyle(.secondary)
                        case .hidden:
                            Label("Value is written in the file (hidden)", systemImage: "eye.slash")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var variables: some View {
        GroupBox("Needs variables") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(server.variables, id: \.self) { name in
                    HStack {
                        Text(name).monospaced().textSelection(.enabled)
                        Spacer()
                        if model.isInKeychain(name) {
                            Label("In Keychain", systemImage: "key.fill").foregroundStyle(.green)
                            Button("Replace…") { secretFor = name }
                        } else {
                            Label("Not in AKit's Keychain", systemImage: "key").foregroundStyle(.secondary)
                            Button("Set in Keychain…") { secretFor = name }
                        }
                    }
                }
                if model.envFileSourced {
                    Text("~/.akit/env.sh exports them from the Keychain and ~/.zshrc sources it: harnesses started from a terminal get them. Started from the Dock, they don't; Edit… → “Read from the Keychain by the config” works everywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text("The harness takes them from the environment it was started in. Keychain values reach a terminal once ~/.zshrc has: \(MCPWriter.sourceLine)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Copy Line") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(MCPWriter.sourceLine, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .sheet(item: Binding(get: { secretFor.map(SecretRequest.init) }, set: { secretFor = $0?.name })) { request in
            KeychainSecretSheet(name: request.name)
        }
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.warnings(of: server), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}

extension AppModel {
    /// The scan's warnings plus variables an active server needs that AKit doesn't provide:
    /// not in its Keychain, or in it but ~/.akit/env.sh isn't sourced from ~/.zshrc.
    func warnings(of server: MCPServer) -> [String] {
        guard server.uses.contains(where: \.state.isActive) else { return server.warnings }
        let missing = server.variables.filter { !isInKeychain($0) }
        let unexported = envFileSourced ? [] : server.variables.filter { !missing.contains($0) }
        var result = server.warnings
        if !missing.isEmpty {
            result.append("Needs \(missing.joined(separator: ", ")): not in AKit's Keychain, so the harness must get it from its environment")
        }
        if !unexported.isEmpty {
            result.append("\(unexported.joined(separator: ", ")) is in the Keychain, but ~/.zshrc doesn't source ~/.akit/env.sh yet")
        }
        return result
    }
}

extension MCPServer {
    /// One line for the list: command with arguments, or the URL.
    var summary: String {
        if let url { return url }
        return ([command ?? ""] + arguments).joined(separator: " ")
    }
}

extension MCPState {
    var icon: String {
        switch self {
        case .active: "checkmark.circle.fill"
        case .disabled: "pause.circle"
        case .needsApproval: "questionmark.circle"
        case .rejected: "xmark.circle"
        case .shadowed: "arrow.triangle.branch"
        case .inactive: "minus.circle"
        }
    }
}

private struct SecretRequest: Identifiable {
    let name: String
    var id: String { name }
}

/// Asks for one secret value and stores it in the Keychain (service "AKit MCP").
private struct KeychainSecretSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var value = ""
    @State private var error: String?
    @State private var notes: [String]?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keychain: \(name)").font(.title3.bold())
            if let notes {
                Label("Saved in the Keychain (service “\(KeychainSecretStore.service)”).", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                ForEach(notes, id: \.self) { Label($0, systemImage: "info.circle").textSelection(.enabled) }
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("The value goes to your login Keychain through /usr/bin/security (never as a command argument) and is not shown again; ~/.akit/env.sh exports it as \(name). It stays out of files and git, but programs running as you can read it with /usr/bin/security — the same as a token in ~/.zshrc.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                SecureField("Value", text: $value, prompt: Text("paste the token"))
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    if isSaving { ProgressView().controlSize(.small) }
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(value.isEmpty || isSaving)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                notes = try await model.storeSecret(value, for: name)
                value = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
