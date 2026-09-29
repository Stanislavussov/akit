import AKitFoundation
import AKitHarnesses
import AKitModel
import Foundation

/// Finds MCP servers in the config files of the installed harnesses. Read-only.
public enum MCPScanner {
    public static func scan(installations: [HarnessInstallation], projects: [URL],
                            adapters: [any HarnessAdapter] = HarnessCatalog.adapters,
                            in env: HarnessEnvironment) -> MCPScanResult {
        let installed = Set(installations.map(\.id))
        let sources = adapters.filter { installed.contains($0.id) }.flatMap { $0.mcpSources(in: env, projects: projects) }
        return scan(sources, home: env.homeDirectory)
    }

    static func scan(_ sources: [MCPSource], home: URL) -> MCPScanResult {
        var result = MCPScanResult()
        var byID: [String: MCPServer] = [:]
        var order: [String] = []
        var failed = Set<String>()
        var cache: [String: [String: Any]] = [:]
        for source in sources {
            let found: [MCPServer]?
            do {
                found = try MCPReader.read(source, cache: &cache)
            } catch {
                if failed.insert(source.file.path).inserted {
                    result.problems.append("\(FileWalk.tilde(source.file, home: home)): \(error.localizedDescription)")
                }
                continue
            }
            for server in found ?? [] {
                if var existing = byID[server.id] {
                    existing.uses += server.uses.filter { use in !existing.uses.contains { $0.harness == use.harness } }
                    byID[server.id] = existing
                } else {
                    byID[server.id] = server
                    order.append(server.id)
                }
            }
        }
        var servers = order.compactMap { byID[$0] }
        markShadowed(&servers, home: home)
        for index in servers.indices {
            // Missing variables are checked by the app: it knows the Keychain and ~/.akit/env.sh.
            servers[index].uses.sort { $0.harness < $1.harness }
        }
        result.servers = servers
        return result
    }

    /// Two entries with one name that one harness loads in the same session: the higher
    /// layer wins. A session sees the global entries plus ONE project.
    static func markShadowed(_ servers: inout [MCPServer], home: URL) {
        let projects = Set(servers.compactMap { server -> URL? in
            if case .project(let url) = server.scope { return url }
            return nil
        })
        let contexts: [URL?] = [nil] + projects.map { Optional($0) }
        for harness in Set(servers.flatMap(\.usedBy)) {
            for context in contexts {
                // (server index, use index) of every entry this session loads.
                var loaded: [(Int, Int)] = []
                for (s, server) in servers.enumerated() {
                    switch server.scope {
                    case .global: break
                    case .project(let url): if url != context { continue }
                    default: continue // plugin servers are namespaced
                    }
                    if let u = server.uses.firstIndex(where: { $0.harness == harness }) { loaded.append((s, u)) }
                }
                for (_, entries) in Dictionary(grouping: loaded, by: { servers[$0.0].name }) where entries.count > 1 {
                    // Only an entry the harness really loads can win (not rejected, pending or inactive).
                    let ranked = entries
                        .filter { servers[$0.0].uses[$0.1].state.isActive || servers[$0.0].uses[$0.1].state == .disabled }
                        .sorted { servers[$0.0].uses[$0.1].precedence > servers[$1.0].uses[$1.1].precedence }
                    guard let top = ranked.first else { continue }
                    let winner = servers[top.0]
                    // Clashes between global entries are handled once, without a project.
                    if context != nil, winner.scope == .global { continue }
                    let place = "\(winner.uses[top.1].layer) (\(FileWalk.tilde(winner.file, home: home)))"
                    for (s, u) in ranked.dropFirst() {
                        if context != nil, servers[s].scope == .global {
                            // Still used everywhere else: only this project overrides it.
                            let note = "\(harness.displayName) in \(context!.lastPathComponent) uses \(place) instead"
                            if !servers[s].warnings.contains(note) { servers[s].warnings.append(note) }
                        } else if servers[s].uses[u].state.isActive {
                            servers[s].uses[u].state = .shadowed(by: place)
                        }
                    }
                }
            }
        }
    }
}
