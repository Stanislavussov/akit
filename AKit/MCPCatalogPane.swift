import AKitFoundation
import AKitMCP
import AKitMCPCatalog
import AppKit
import SwiftUI

/// Catalog input of the Add Server sheet: search the public MCP catalogs, pick a server and a
/// way to connect, and fill the form from it. Nothing is written here.
struct MCPCatalogPane: View {
    /// The chosen entry as a form, with a line per value the user still has to type.
    let onUse: (MCPDraft, [String]) -> Void
    /// Owned by the sheet, so the search survives a look at the Form tab.
    @Binding var query: String

    @State private var directory: [CatalogServer] = []
    @State private var directoryProblem: String?
    @State private var isLoadingDirectory = true
    @State private var registry: [CatalogServer] = []
    /// The query `registry` answers; results of an older query are not shown.
    @State private var registryQuery: String?
    /// The registry query in flight.
    @State private var searching: String?
    @State private var registryError: String?
    /// Bumped by Try Again: the same query is searched once more.
    @State private var attempt = 0
    @State private var selection: CatalogServer.ID?

    private var home: URL { HarnessEnvironment.current.homeDirectory }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query, prompt: Text("Search MCP servers, e.g. “linear” or “context7”"))
                    .textFieldStyle(.plain)
                if isLoadingDirectory { ProgressView().controlSize(.small) }
                Button("Reload", systemImage: "arrow.clockwise") { Task { await loadDirectory(refresh: true) } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(isLoadingDirectory)
                    .help("Download the Anthropic directory again (AKit keeps it for a day)")
            }
            .padding(8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 10)
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 250)
                Divider()
                Group {
                    if let server = shown.first(where: { $0.id == selection }) {
                        MCPCatalogDetail(server: server, onUse: onUse)
                            .id(server.id)
                    } else {
                        ContentUnavailableView("Select a server", systemImage: "books.vertical",
                                               description: Text("Pick a server to see how it connects and which values it needs."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await loadDirectory(refresh: false) }
        .task(id: "\(attempt) \(key)") { await searchRegistry() }
        .onChange(of: shown.map(\.id)) { keepSelectionVisible() }
    }

    // MARK: - List

    private var list: some View {
        List(selection: $selection) {
            Section(CatalogSource.directory.title) {
                ForEach(shownDirectory) { server in
                    MCPCatalogRow(server: server).tag(server.id)
                }
                if let directoryProblem {
                    status(directory.isEmpty ? "Couldn't download: \(directoryProblem)" : "Showing the saved list: \(directoryProblem)",
                           systemImage: "wifi.exclamationmark")
                } else if !isLoadingDirectory, shownDirectory.isEmpty {
                    status("Nothing matches.", systemImage: "magnifyingglass")
                }
            }
            Section(CatalogSource.registry.title) {
                ForEach(shownRegistry) { server in
                    MCPCatalogRow(server: server).tag(server.id)
                }
                registryStatus
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var registryStatus: some View {
        if key.count < MCPCatalogClient.minimumQueryLength {
            status("Type a name to search the registry too.", systemImage: "magnifyingglass")
        } else if let registryError, registryQuery == key {
            status("Search failed: \(registryError)", systemImage: "wifi.exclamationmark")
            Button("Try Again") { registryQuery = nil; attempt += 1 }
                .buttonStyle(.link)
                .font(.caption)
        } else if searching != nil || registryQuery != key {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Searching. The registry can take a minute.").font(.caption).foregroundStyle(.secondary)
            }
        } else if shownRegistry.isEmpty {
            status("No server name matches.", systemImage: "magnifyingglass")
        }
    }

    private func status(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - Data

    /// The query as the registry and the saved searches see it.
    private var key: String { query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    private var shownDirectory: [CatalogServer] { MCPCatalog.search(directory, query: key) }

    /// Registry answers for the current query, without servers the directory already lists.
    private var shownRegistry: [CatalogServer] {
        guard registryQuery == key else { return [] }
        let listed = Set(directory.map(\.name))
        let found = registry.filter { !listed.contains($0.name) }
        // Best match first; the registry also matches inside the namespace, which the ranking doesn't read.
        let ranked = MCPCatalog.search(found, query: key)
        let rankedIDs = Set(ranked.map(\.id))
        return ranked + MCPCatalog.search(found.filter { !rankedIDs.contains($0.id) }, query: "")
    }

    private var shown: [CatalogServer] { shownDirectory + shownRegistry }

    private func loadDirectory(refresh: Bool) async {
        isLoadingDirectory = true
        let result = await MCPCatalog.directory(home: home, refresh: refresh)
        directory = result.servers
        directoryProblem = result.problem
        isLoadingDirectory = false
        keepSelectionVisible()
    }

    /// Debounced: runs 0.8 s after typing stops; a newer query cancels this one.
    private func searchRegistry() async {
        let q = key
        guard q.count >= MCPCatalogClient.minimumQueryLength else {
            registryQuery = nil
            registryError = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(800))
        guard !Task.isCancelled else { return }
        searching = q
        defer { if searching == q { searching = nil } }
        do {
            let found = try await MCPCatalog.registry(matching: q, home: home)
            guard !Task.isCancelled else { return }
            registry = found
            registryError = nil
            registryQuery = q
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard !Task.isCancelled else { return }
            registry = []
            registryError = error.localizedDescription
            registryQuery = q
        }
    }

    private func keepSelectionVisible() {
        // Snapshots show the server named by `--select` once it is listed, else the first result.
        if let wanted = DebugSnapshot.options?.select, let server = shown.first(where: { $0.name == wanted }) {
            selection = server.id
            return
        }
        if let selection, shown.contains(where: { $0.id == selection }) { return }
        selection = DebugSnapshot.options != nil ? shown.first?.id : nil
    }
}

private struct MCPCatalogRow: View {
    let server: CatalogServer

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(server.title).fontWeight(.medium).lineLimit(1)
                if server.isDeprecated {
                    Text("deprecated").font(.caption2).foregroundStyle(.orange)
                }
            }
            Text(server.summary.isEmpty ? server.name : server.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .help(server.name)
    }
}

/// One catalog server: where it comes from, the ways to connect and the values it takes.
private struct MCPCatalogDetail: View {
    let server: CatalogServer
    let onUse: (MCPDraft, [String]) -> Void

    @State private var optionID: CatalogOption.ID?
    /// Optional values the user wants in the form.
    @State private var included: Set<CatalogParameter.ID> = []
    /// Starts as the catalog's name; the view is rebuilt for every server (`.id`), so this seeds once.
    @State private var name: String

    init(server: CatalogServer, onUse: @escaping (MCPDraft, [String]) -> Void) {
        self.server = server
        self.onUse = onUse
        _name = State(initialValue: server.configName)
    }

    private var option: CatalogOption? { server.options.first { $0.id == optionID } ?? server.options.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let option {
                    connection(option)
                    if !option.parameters.isEmpty { values(option) }
                    use(option)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            // Snapshot mode: `--select <server name> --capture` fills the form from the server's
            // local package (else its first option) with every value.
            guard let options = DebugSnapshot.options, options.capture, options.select == server.name,
                  let option = server.options.first(where: { $0.kind == .package && $0.unsupported == nil }) ?? server.options.first
            else { return }
            optionID = option.id
            included = Set(option.parameters.map(\.id))
            onUse(CatalogDraft.draft(of: option, name: trimmedName, including: included), notes(option))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(server.title).font(.title3.bold()).textSelection(.enabled)
            Text([server.name, server.version].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !server.summary.isEmpty {
                Text(server.summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            switch server.source {
            case .directory:
                Label("Listed in Anthropic's connector directory.", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            case .registry:
                Label("From the open MCP Registry: anyone can publish there and nothing is reviewed. Read the repository before you add it.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if server.isDeprecated {
                Label("The publisher marked this server as deprecated.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if server.listsClaudeCode == false {
                Label("The directory doesn't name Claude Code for this server; it may work only in the Claude apps.",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if let url = server.repositoryURL { Link("Repository", destination: url) }
                if let url = server.documentationURL { Link("Documentation", destination: url) }
                if let url = server.websiteURL { Link("Website", destination: url) }
            }
        }
        .font(.callout)
    }

    private func connection(_ option: CatalogOption) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connection").font(.headline)
            if server.options.count > 1 {
                Picker("Connection", selection: Binding(get: { option.id }, set: { optionID = $0; included = [] })) {
                    ForEach(server.options) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
            } else {
                Text(option.label)
            }
            ForEach(option.cautions, id: \.self) { caution in
                Label(caution, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let reason = option.unsupported {
                Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Text(commandLine(option))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if signsIn(option) {
                Label("Asks you to sign in on first use. In Claude Code: /mcp, then pick the server.", systemImage: "person.badge.key")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func values(_ option: CatalogOption) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Values").font(.headline)
            ForEach(option.parameters) { parameter in
                let fixed = parameter.isRequired || parameter.place == .url
                Toggle(isOn: Binding(
                    get: { fixed || included.contains(parameter.id) },
                    set: { on in if on { included.insert(parameter.id) } else { included.remove(parameter.id) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(parameter.place == .url ? "{\(parameter.name)}" : parameter.name).font(.callout.monospaced())
                            if parameter.isSecret {
                                Image(systemName: "key.fill").font(.caption).foregroundStyle(.secondary)
                                    .help("Secret: stored in the Keychain, not in the file")
                                    .accessibilityLabel("Secret")
                            }
                            Text(fixed ? "required" : "optional").font(.caption).foregroundStyle(.secondary)
                        }
                        if !parameter.details.isEmpty {
                            Text(parameter.details).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let value = CatalogDraft.prefilled(parameter) {
                            Text("Prefilled by the catalog: \(value)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(fixed)
            }
            Text("You type the values in the form. Secrets go to the Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func use(_ option: CatalogOption) -> some View {
        HStack {
            TextField("Name", text: $name, prompt: Text("name in the config"))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .frame(maxWidth: 200)
                .help("The name the server gets in the config file")
            Spacer()
            Button("Fill the Form") {
                onUse(CatalogDraft.draft(of: option, name: trimmedName, including: included), notes(option))
            }
            .buttonStyle(.borderedProminent)
            .disabled(option.unsupported != nil || trimmedName.isEmpty)
        }
        .padding(.top, 4)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private func signsIn(_ option: CatalogOption) -> Bool {
        option.kind == .remote && server.needsSignIn == true && !option.parameters.contains { $0.place == .header }
    }

    private func commandLine(_ option: CatalogOption) -> String {
        let draft = CatalogDraft.draft(of: option, name: trimmedName, including: included)
        // What the form gets, not the entry's template: a value the catalog puts in must be visible here.
        if option.kind == .remote { return draft.url.isEmpty ? option.url : draft.url }
        return [draft.command, MCPDraft.joinArguments(draft.arguments)].joined(separator: " ")
    }

    private func notes(_ option: CatalogOption) -> [String] {
        var notes = ["\(server.title) · \(option.label) (\(server.source.title))"]
        notes += CatalogDraft.notes(for: option, including: included)
        if signsIn(option) { notes.append("Sign in after adding it. In Claude Code: /mcp, then pick the server.") }
        return notes
    }
}
