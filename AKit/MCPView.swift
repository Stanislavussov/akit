import AKitCore
import AppKit
import SwiftUI

/// MCP screen: every MCP server the installed harnesses have configured, grouped by where
/// it lives. Values of env variables and headers are never shown, only `${VAR}` references.
struct MCPView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: MCPServer.ID?
    @State private var query = DebugSnapshot.options?.query ?? ""

    var body: some View {
        @Bindable var model = model
        HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
            Group {
                if let server = model.mcpServers.first(where: { $0.id == selection }) {
                    MCPServerDetailView(server: server)
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
        .onChange(of: model.mcpServers) { keepSelectionVisible() }
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
    let server: MCPServer

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(server.name).fontWeight(.medium)
                if !server.warnings.isEmpty {
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

private struct MCPServerDetailView: View {
    let server: MCPServer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                info
                if !server.warnings.isEmpty { warnings }
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
            if ExternalEditor.appURL != nil {
                Button("Open in \(ExternalEditor.name)", systemImage: "square.and.pencil") { ExternalEditor.open(server.file) }
                    .help("Open \(server.file.tildePath)")
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
            VStack(alignment: .leading, spacing: 6) {
                ForEach(server.variables, id: \.self) { name in
                    Text(name).monospaced().textSelection(.enabled)
                }
                Text("The harness takes them from the environment it was started in. Variables from ~/.zshrc are only there when the harness is started from a terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(server.warnings, id: \.self) { warning in
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
