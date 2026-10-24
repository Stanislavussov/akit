import AKitFoundation
import AKitModel
import Foundation

/// Pi's `exposure` of one MCP server (mcp.md, "Control tool exposure"): how the model reaches its
/// tools. Written on the server's entry in the Pi `mcp.json` that defines it (the global one or a
/// project's own), through `SettingsFile` like the switches: a diff first, a backup, refused if
/// the file changed. A project override of a user server is not written here.
extension MCPSwitches {
    /// mcp.md: `codemode` (the default; `codemode-deferred` is its alias), `deferred`, `direct`, `hidden`.
    public static let piExposures = ["direct", "deferred", "codemode", "hidden"]

    /// What each value means, from mcp.md's table.
    public static func exposureHelp(_ exposure: String) -> String {
        switch exposure {
        case "direct": "Declared to the model like a built-in tool in every request, and callable from codemode."
        case "deferred": "Not declared until tool_search loads a match for the next model call."
        case "hidden": "Registered but unreachable."
        default: "Callable from codemode scripts, but neither declared to the model nor listed in the codemode description (Pi's default)."
        }
    }

    /// The server's exposure in Pi now: its entry's `exposure`, else `codemode`.
    public static func piExposure(of server: MCPServer, in env: HarnessEnvironment) -> String? {
        guard isPiOwnFile(server.file, env: env),
              let value = try? SettingsFile.read(server.file, home: env.homeDirectory)?.value,
              let entry = value.value(at: ["mcpServers", server.name])?.objectMembers else { return nil }
        if case .string(let exposure)? = entry["exposure"] { return exposure == "codemode-deferred" ? "codemode" : exposure }
        return "codemode"
    }

    /// `~/.pi/agent/mcp.json` or a project's `.pi/mcp.json`: files Pi itself reads.
    static func isPiOwnFile(_ file: URL, env: HarnessEnvironment) -> Bool {
        let path = file.standardizedFileURL.path
        return path == piGlobal(env)?.standardizedFileURL.path || path.hasSuffix("/.pi/mcp.json")
    }

    /// Sets the server's `exposure` (codemode, the default, removes the key).
    public static func exposurePlan(_ server: MCPServer, exposure: String, in env: HarnessEnvironment) throws(Failure) -> Plan {
        guard piExposures.contains(exposure) else { throw Failure("Exposure is \(piExposures.joined(separator: ", ")) (mcp.md).") }
        let home = env.homeDirectory
        let shown = FileWalk.tilde(server.file, home: home)
        guard server.usedBy.contains(.pi), isPiOwnFile(server.file, env: env) else {
            throw Failure("\(server.name) in \(shown) isn't in a Pi mcp.json; AKit changes the exposure only there.")
        }
        do {
            guard let value = try SettingsFile.read(server.file, home: home)?.value,
                  let entry = value.value(at: ["mcpServers", server.name])?.objectMembers else {
                throw Failure("\(shown) has no server \(server.name) any more. Look at the MCP Servers screen again.")
            }
            let now: String = if case .string(let text)? = entry["exposure"] { text == "codemode-deferred" ? "codemode" : text } else { "codemode" }
            var changes: [SettingsFile.Change] = []
            if now != exposure {
                let edit: SettingsFile.Edit = exposure == "codemode" ? .remove(["mcpServers", server.name, "exposure"])
                    : .set(["mcpServers", server.name, "exposure"], .string(exposure))
                changes.append(try SettingsFile.change(server.file, edits: [edit], home: home))
            }
            return Plan(title: "Set \(server.name)'s Exposure to \(exposure) in Pi", changes: changes,
                        notes: ["\(exposure): \(exposureHelp(exposure))", "Was \(now). Only this key changes; the rest of the file stays as it is. Run /reload in a running Pi session."],
                        skipped: [], unmanaged: [], piFolders: [], store: StoreEdit())
        } catch let error as Failure {
            throw error
        } catch let error as SettingsFile.Failure {
            throw Failure(error.message)
        } catch {
            throw Failure(error.localizedDescription)
        }
    }
}
