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
        guard !ids.isEmpty, ids.isDisjoint(with: mcpChecking) else { return }
        mcpChecking.formUnion(ids)
        defer { mcpChecking.subtract(ids) }
        let results = await MCPCheck.run(requests, in: env)
        try? await Task.detached { try MCPCheckStore.save(results, home: env.homeDirectory) }.value
        for result in results { mcpChecks[result.id] = result }
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

    var body: some View {
        let checks = model.mcpChecks(of: server)
        if !checks.isEmpty {
            let running = checks.contains { model.mcpChecking.contains($0.id) }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(checks, id: \.id) { check in
                        MCPCheckRow(harness: check.harness, result: model.mcpChecks[check.id], running: model.mcpChecking.contains(check.id))
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
        }
    }
}

struct MCPCheckRow: View {
    let harness: HarnessID
    let result: MCPCheckResult?
    let running: Bool

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
                    if let tools = result.tools, result.state == .connected {
                        Text("\(tools.count) tool\(tools.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    }
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
