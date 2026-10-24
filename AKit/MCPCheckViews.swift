import AKitFoundation
import AKitMCP
import AKitModel
import SwiftUI

/// The connection check (docs/design/mcp-check.md): Claude Code and Pi say whether a server
/// connects. Shown on the server's details, in the list and after Apply in the editor.
extension AppModel {
    /// The folder a global server is checked in: the project the MCP screen shows, else home.
    var mcpCheckContext: URL? {
        if case .project(let url) = mcpFilter { return url }
        return nil
    }

    /// One check per harness that can check this server: the harness and the result's id.
    func mcpChecks(of server: MCPServer) -> [(harness: HarnessID, id: String)] {
        MCPCheck.requests(for: [server], context: mcpCheckContext, home: HarnessEnvironment.current.homeDirectory).map {
            ($0.harness, MCPCheckResult.key(harness: $0.harness.rawValue, name: server.name, folder: $0.folder.standardizedFileURL.path))
        }
    }

    /// Asks the harnesses about these servers. Pi answers for all its servers in a folder, so
    /// their results are updated too.
    func checkMCP(_ servers: [MCPServer]) async {
        let env = HarnessEnvironment.current
        let requests = MCPCheck.requests(for: servers, context: mcpCheckContext, home: env.homeDirectory)
        let ids = Set(requests.flatMap { request in
            request.names.map { MCPCheckResult.key(harness: request.harness.rawValue, name: $0, folder: request.folder.standardizedFileURL.path) }
        })
        guard !ids.isEmpty else { return }
        // A check of these servers is running (Check All): wait for it, so this one sees the
        // config as it is now (the check after Apply).
        while !ids.isDisjoint(with: mcpChecking) {
            try? await Task.sleep(for: .milliseconds(300))
        }
        mcpChecking.formUnion(ids)
        defer { mcpChecking.subtract(ids) }
        let results = await MCPCheck.run(requests, in: env)
        try? await Task.detached { try MCPCheckStore.save(results, home: env.homeDirectory) }.value
        for result in results { mcpChecks[result.id] = result }
    }

    /// Sign In…: the harness's own `mcp login` (it opens the browser), then a new check.
    func signInMCP(_ server: MCPServer, harness: HarnessID, id: String) async {
        guard let folder = mcpChecks[id].map({ URL(filePath: $0.folder, directoryHint: .isDirectory) }),
              !mcpChecking.contains(id) else { return }
        mcpChecking.insert(id)
        mcpFixErrors[id] = nil
        let failure = await MCPApprove.signIn(server.name, harness: harness, folder: folder, in: .current)
        mcpChecking.remove(id)
        mcpFixErrors[id] = failure
        await checkMCP([server])
    }

    /// Copy to Pi… / Copy to Claude Code…: the harnesses (of these two) that don't read the
    /// server yet and have a place of their own to write it. Not for plugins or files AKit
    /// can't read.
    func copyTargets(of server: MCPServer) -> [HarnessID] {
        guard MCPWriter.target(of: server, in: mcpWriteTargets) != nil else { return [] }
        return MCPCheck.harnesses.filter { harness in
            installations.contains { $0.id == harness } && !server.usedBy.contains(harness)
                && mcpWriteTargets.contains { $0.harnesses == [harness] && $0.blockedReason == nil }
        }
    }

    /// Problems of the last checks of a server, for the list's mark; empty when all connected.
    func mcpCheckProblems(of server: MCPServer) -> [MCPCheckResult] {
        mcpChecks(of: server).compactMap { mcpChecks[$0.id] }.filter(\.state.isProblem)
    }
}

extension MCPCheckResult.State {
    var icon: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .off: "pause.circle"
        case .needsSignIn: "person.badge.key"
        case .pendingApproval: "questionmark.circle"
        case .untrustedProject: "lock.shield"
        case .missingVariables: "key"
        case .failed, .timedOut, .notFound: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .connected: .green
        case .off: .secondary
        case .failed, .timedOut, .notFound: .red
        default: .orange
        }
    }
}

/// The Connection box: one row per harness, with Check Connection.
struct MCPConnectionBox: View {
    @Environment(AppModel.self) private var model
    let server: MCPServer
    @State private var variable: String?
    @State private var approving: URL?

    var body: some View {
        let checks = model.mcpChecks(of: server)
        if !checks.isEmpty {
            let running = checks.contains { model.mcpChecking.contains($0.id) }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(checks, id: \.id) { check in
                        HStack(alignment: .firstTextBaseline) {
                            MCPCheckRow(harness: check.harness, result: model.mcpChecks[check.id], running: model.mcpChecking.contains(check.id),
                                        fixError: model.mcpFixErrors[check.id])
                            Spacer()
                            if !model.mcpChecking.contains(check.id), let result = model.mcpChecks[check.id] {
                                fix(result, harness: check.harness, id: check.id)
                            }
                        }
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } label: {
                HStack {
                    Text("Connection")
                    Spacer()
                    Button("Check Connection", systemImage: "bolt.horizontal") { Task { await model.checkMCP([server]) } }
                        .controlSize(.small)
                        .disabled(running)
                        .help("Ask \(checks.map(\.harness.displayName).joined(separator: " and ")) to connect to this server now. "
                              + "It starts the server; Pi checks all its servers in that folder.")
                }
            }
            .sheet(item: Binding(get: { variable.map(VariableRequest.init) }, set: { variable = $0?.name })) { request in
                KeychainSecretSheet(name: request.name) { Task { await model.checkMCP([server]) } }
            }
            .sheet(item: Binding(get: { approving.map(ApproveRequest.init) }, set: { approving = $0?.project })) { request in
                MCPApproveSheet(server: server, project: request.project)
            }
        }
    }

    /// The one fix of a state that has one.
    @ViewBuilder
    private func fix(_ result: MCPCheckResult, harness: HarnessID, id: String) -> some View {
        switch result.state {
        case .needsSignIn:
            Button("Sign In…") { Task { await model.signInMCP(server, harness: harness, id: id) } }
                .controlSize(.small)
                .help("Run \(harness == .pi ? "pi" : "claude") mcp login \(server.name): it opens the browser; AKit checks again afterwards")
        case .missingVariables:
            Menu("Set Variable…") {
                ForEach(result.missingVariables, id: \.self) { name in
                    Button(name) { variable = name }
                }
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help("Save the value in the Keychain; ~/.akit/env.sh exports it to your shell")
        case .pendingApproval:
            if harness == .claudeCode, case .project(let project) = server.scope {
                Button("Approve…") { approving = project }
                    .controlSize(.small)
                    .help("Answer Claude Code's question for this .mcp.json server: its name in enabledMcpjsonServers (a diff first)")
            }
        default:
            EmptyView()
        }
    }
}

private struct VariableRequest: Identifiable {
    let name: String
    var id: String { name }
}

private struct ApproveRequest: Identifiable {
    let project: URL
    var id: String { project.path }
}

/// Approve…: the one key of `.claude/settings.local.json` (the rest of the file is never
/// shown), then Approve writes it and the server is checked again.
struct MCPApproveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: MCPServer
    let project: URL
    @State private var plan: MCPApprove.Plan?
    @State private var error: String?
    @State private var isApplying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Approve “\(server.name)” in Claude Code").font(.title3.bold())
            Text(MCPApprove.file(in: project).tildePath).font(.callout.monospaced()).foregroundStyle(.secondary)
            if let plan {
                ForEach(plan.notes, id: \.self) { Label($0, systemImage: "info.circle").foregroundStyle(.secondary) }
                DiffPreview(diff: plan.change.diff)
                    .font(.callout.monospaced())
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Approve") { approve() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil || isApplying)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            // Off the main thread: the plan asks git whether the file is tracked.
            let name = server.name, project = project
            do { plan = try await Task.detached { try MCPApprove.plan(name, project: project, env: .current) }.value }
            catch { self.error = error.localizedDescription }
        }
    }

    private func approve() {
        guard let plan else { return }
        isApplying = true
        let home = HarnessEnvironment.current.homeDirectory
        Task {
            defer { isApplying = false }
            do {
                _ = try await Task.detached { try MCPApprove.apply(plan, home: home) }.value
            } catch {
                self.error = error.localizedDescription
                return
            }
            dismiss()
            await model.refresh()
            await model.checkMCP([server])
        }
    }
}

struct MCPCheckRow: View {
    let harness: HarnessID
    let result: MCPCheckResult?
    let running: Bool
    var fixError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HarnessBadge(harness: harness)
                if running {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                } else if let result {
                    Label(result.state.title, systemImage: result.state.icon).foregroundStyle(result.state.color)
                    Text(result.checkedAt.formatted(.relative(presentation: .named)))
                        .foregroundStyle(.secondary)
                        .help(result.checkedAt.formatted(date: .abbreviated, time: .standard))

                } else {
                    Text("Not checked yet").foregroundStyle(.secondary)
                }
            }
            if !running, let result {
                if result.folder != HarnessEnvironment.current.homeDirectory.standardizedFileURL.path {
                    Text("In \(URL(filePath: result.folder).tildePath)").font(.caption).foregroundStyle(.secondary)
                }
                if !result.missingVariables.isEmpty {
                    Text("Not set in your shell: \(result.missingVariables.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let tools = result.tools, !tools.isEmpty, result.state == .connected {
                    MCPToolList(tools: tools, exposure: result.exposure, toolExposure: result.toolExposure ?? [:])
                }
                if let fixError {
                    Text(fixError).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                if let detail = result.detail {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(8)
                }
            }
        }
    }
}

/// Pi's answer about a connected server: its tools and how each reaches the model
/// (`exposure` of the server, `toolExposure` where a tool differs). Only shown, never changed.
struct MCPToolList: View {
    let tools: [String]
    let exposure: String?
    let toolExposure: [String: String]
    /// A short list is open from the start.
    @State private var expanded: Bool

    init(tools: [String], exposure: String?, toolExposure: [String: String]) {
        self.tools = tools
        self.exposure = exposure
        self.toolExposure = toolExposure
        _expanded = State(initialValue: tools.count <= 5)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(tools, id: \.self) { tool in
                    HStack(spacing: 6) {
                        Text(tool).font(.caption.monospaced()).textSelection(.enabled)
                        if let own = toolExposure[tool] {
                            Text(own)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.orange)
                                .help("This tool's exposure differs from the server's (\(exposure ?? "codemode"))")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        } label: {
            Text("\(tools.count) tool\(tools.count == 1 ? "" : "s")" + (exposure.map { " · \($0)" } ?? ""))
        }
        .font(.caption)
        .help("The tools Pi listed at the last check. Exposure: codemode (scripts find them), deferred (tool_search loads them), direct (always declared), hidden")
    }
}
