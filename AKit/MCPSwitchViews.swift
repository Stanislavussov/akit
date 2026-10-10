import AKitFoundation
import AKitMCP
import AKitModel
import AKitProjectSetup
import SwiftUI

/// An MCP switch change waiting in its sheet.
struct MCPSwitchRequest: Identifiable {
    enum Kind {
        case everywhere
        /// Off in Project…: projects are chosen in the sheet first.
        case chooseProjects
        /// Back on everywhere and in every folder where it is off.
        case allOn
        case connectors
    }

    let id = UUID()
    let server: MCPServer?
    let harness: HarnessID
    let off: Bool
    let kind: Kind
}

/// MCP server details: per harness the state and the buttons that change it.
struct MCPSwitchControls: View {
    @Environment(AppModel.self) private var model
    let server: MCPServer

    var body: some View {
        let rows = MCPSwitches.harnesses.compactMap { harness in
            MCPSwitches.options(for: server, harness: harness, in: .current).map { (harness, $0) }
        }
        if !rows.isEmpty {
            GroupBox("Switches") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(rows, id: \.0) { harness, options in
                        GridRow {
                            HarnessBadge(harness: harness)
                            if let reason = options.unavailable {
                                Text("No switch").foregroundStyle(.secondary).help(reason)
                            } else {
                                let status = model.mcpStates[server.id]?[harness] ?? MCPSwitches.Status()
                                Text(status.title)
                                    .foregroundStyle(status.unknown != nil ? .orange : status.isOn ? .primary : .secondary)
                                    .help(MCPSwitchText.statusHelp(status))
                                HStack(spacing: 6) {
                                    if options.modes.contains(.everywhere), !status.offEverywhere {
                                        Button("Off Everywhere…") { open(harness, off: true, .everywhere) }
                                            .help(options.everywhereHelp ?? "")
                                    }
                                    Button("Off in Project…") { open(harness, off: true, .chooseProjects) }
                                        .help(options.projectHelp)
                                    if !status.isOn, status.unknown == nil {
                                        Button("Turn On…") { open(harness, off: false, .allOn) }
                                            .help("Removes the entries that turn \(server.name) off: the deny rule or enabled: false, and the folders' entries")
                                    }
                                }
                                .disabled(status.unknown != nil)
                            }
                        }
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private func open(_ harness: HarnessID, off: Bool, _ kind: MCPSwitchRequest.Kind) {
        model.mcpSwitchRequest = MCPSwitchRequest(server: server, harness: harness, off: off, kind: kind)
    }
}

/// Context menus (MCP Servers list, Insights → MCP Servers): a submenu per harness.
struct MCPSwitchMenu: View {
    @Environment(AppModel.self) private var model
    let server: MCPServer

    var body: some View {
        ForEach(MCPSwitches.harnesses, id: \.self) { harness in
            if let options = MCPSwitches.options(for: server, harness: harness, in: .current) {
                if options.unavailable != nil {
                    Button("\(harness.displayName): No Switch") {}.disabled(true)
                } else {
                    let status = model.mcpStates[server.id]?[harness] ?? MCPSwitches.Status()
                    Menu("\(harness.displayName): \(status.title)") {
                        if options.modes.contains(.everywhere) {
                            Button("Off Everywhere…") { open(harness, off: true, .everywhere) }.disabled(status.offEverywhere)
                        }
                        Button("Off in Project…") { open(harness, off: true, .chooseProjects) }
                        Button("Turn On…") { open(harness, off: false, .allOn) }.disabled(status.isOn)
                    }
                    .disabled(status.unknown != nil)
                }
            }
        }
    }

    private func open(_ harness: HarnessID, off: Bool, _ kind: MCPSwitchRequest.Kind) {
        model.mcpSwitchRequest = MCPSwitchRequest(server: server, harness: harness, off: off, kind: kind)
    }
}

enum MCPSwitchText {
    static func statusHelp(_ status: MCPSwitches.Status) -> String {
        if let unknown = status.unknown { return unknown }
        var lines: [String] = []
        if status.offEverywhere { lines.append("Off everywhere.") }
        if !status.offIn.isEmpty {
            let home = HarnessEnvironment.current.homeDirectory
            lines.append("Off in: " + status.offIn.map { FileWalk.tilde(URL(filePath: $0), home: home) }.joined(separator: ", "))
        }
        return lines.isEmpty ? "On" : lines.joined(separator: " ")
    }
}

/// Off in Project… (choose projects first), Off Everywhere…, Turn On…, claude.ai Connectors:
/// the change of each file as a diff, then Apply.
struct MCPSwitchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: MCPSwitchRequest
    @State private var chosen: Set<String> = []
    @State private var plan: MCPSwitches.Plan?
    @State private var busy = false
    @State private var error: String?

    private var options: MCPSwitches.Options? {
        request.server.flatMap { MCPSwitches.options(for: $0, harness: request.harness, in: .current) }
    }

    /// Main checkouts AKit knows (a worktree stands for its main checkout).
    private var projects: [URL] {
        if let own = options?.ownProject { return [own] }
        var seen = Set<String>()
        return model.projects.filter { project in
            let main = GitCheckout.at(project)?.mainFolder ?? project
            return seen.insert(main.standardizedFileURL.path).inserted
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan?.title ?? title).font(.title2.bold())
            if request.kind == .chooseProjects, plan == nil {
                chooser
            } else if let plan {
                preview(plan)
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if request.kind == .chooseProjects, plan == nil {
                    Button("Preview") { makePlan() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(chosen.isEmpty || busy)
                        .help("Show what changes in each file, for the chosen projects and their git worktrees")
                } else {
                    Button("Apply", action: apply)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || plan == nil || plan?.changesNothing == true)
                        .help("Back up each file, then write the change. Refused if a changed entry differs from this preview.")
                }
            }
        }
        .padding(20)
        .frame(width: 640)
        .task {
            if request.kind == .chooseProjects {
                if let own = options?.ownProject { chosen = [own.path] }
            } else {
                makePlan()
            }
        }
    }

    private var title: String {
        let name = request.server?.name ?? "claude.ai Connectors"
        return switch request.kind {
        case .everywhere: "Turn \(name) Off Everywhere in \(request.harness.displayName)"
        case .chooseProjects: "Turn \(name) Off in Projects in \(request.harness.displayName)"
        case .allOn: "Turn \(name) On in \(request.harness.displayName)"
        case .connectors: "Turn claude.ai Connectors \(request.off ? "Off" : "On")"
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(options?.projectHelp ?? "")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if projects.isEmpty {
                Text("AKit knows no projects yet.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(projects, id: \.path) { project in
                            Toggle(isOn: Binding(get: { chosen.contains(project.path) },
                                                 set: { if $0 { chosen.insert(project.path) } else { chosen.remove(project.path) } })) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(project.lastPathComponent)
                                    Text(project.tildePath).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(options?.ownProject != nil)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private func preview(_ plan: MCPSwitches.Plan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if plan.changesNothing {
                Text("Nothing to change: it is already so.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(plan.changes.enumerated()), id: \.offset) { _, change in
                        Text("\(change.creates ? "Creates" : "Changes") \(change.file.tildePath)").font(.callout.bold())
                        VStack(alignment: .leading, spacing: 0) {
                            DiffPreview(diff: change.diff)
                        }
                        .font(.callout.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .frame(maxHeight: 260)
            ForEach(plan.notes, id: \.self) { note in
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func makePlan() {
        busy = true
        error = nil
        let request = request, chosen = chosen, known = model.projects
        Task {
            let env = HarnessEnvironment.current
            let result: Result<MCPSwitches.Plan, MCPSwitches.Failure> = await Task.detached {
                do {
                    if request.kind == .connectors { return .success(try MCPSwitches.connectorsPlan(off: request.off, in: env)) }
                    guard let server = request.server else { throw MCPSwitches.Failure("No server.") }
                    let target: MCPSwitches.Target
                    switch request.kind {
                    case .everywhere: target = .everywhere
                    case .allOn: target = .all
                    default:
                        target = .projects(chosen.sorted().map { path in
                            let family = ProjectWorktrees.family(of: URL(filePath: path, directoryHint: .isDirectory), env: env)
                            return MCPSwitches.Family(main: family.main, worktrees: family.worktrees)
                        })
                    }
                    return .success(try MCPSwitches.plan(server, harness: request.harness, off: request.off, target: target, known: known, in: env))
                } catch let error as MCPSwitches.Failure {
                    return .failure(error)
                } catch {
                    return .failure(MCPSwitches.Failure(error.localizedDescription))
                }
            }.value
            switch result {
            case .success(let made): plan = made
            case .failure(let failure): error = failure.message
            }
            busy = false
        }
    }

    private func apply() {
        guard let plan else { return }
        busy = true
        error = nil
        Task {
            do {
                try await model.applyMCPSwitch(plan)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

extension MCPSwitchRequest.Kind: Equatable {}

extension View {
    /// The MCP switch sheet, once for the window.
    func mcpSwitchSheet(_ model: AppModel) -> some View {
        @Bindable var model = model
        return sheet(item: $model.mcpSwitchRequest) { MCPSwitchSheet(request: $0) }
    }
}
