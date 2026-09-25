import Foundation

/// Reads server entries from one `MCPSource`.
enum MCPReader {
    static let maxFileSize = 32 << 20

    /// Server entries of the source, or nil when the file doesn't exist. Throws when it can't be parsed.
    /// `cache` keeps parsed files for one scan: `~/.claude.json` is a source once per project.
    static func read(_ source: MCPSource, cache: inout [String: [String: Any]]) throws -> [MCPServer]? {
        guard let root = try parsed(source, cache: &cache) else { return nil }
        var table: Any? = root
        for key in source.keyPath { table = (table as? [String: Any])?[key] }
        guard let servers = table as? [String: Any] else { return [] }
        return servers.keys.sorted().compactMap { name in
            guard let entry = servers[name] as? [String: Any], entry["command"] != nil || entry["url"] != nil else { return nil }
            return server(name: name, entry: entry, source: source)
        }
    }

    private static func parsed(_ source: MCPSource, cache: inout [String: [String: Any]]) throws -> [String: Any]? {
        let path = source.file.path
        if let root = cache[path] { return root }
        // Only regular files of sane size: a FIFO named .mcp.json would block the scan.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.file.resolvingSymlinksInPath().path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        guard (attributes[.size] as? Int ?? 0) <= maxFileSize else { throw ConfigTextError("the file is too large") }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let root: [String: Any]
        switch source.format {
        case .json: root = try ConfigText.jsonObject(data, jsonc: false)
        case .jsonc: root = try ConfigText.jsonObject(data, jsonc: true)
        case .toml: root = try MiniTOML.parse(String(decoding: data, as: UTF8.self))
        }
        cache[path] = root
        return root
    }

    static func server(name: String, entry: [String: Any], source: MCPSource) -> MCPServer {
        switch source.dialect {
        case .standard: standard(name: name, entry: entry, source: source)
        case .openCode: openCode(name: name, entry: entry, source: source)
        case .codex: codex(name: name, entry: entry, source: source)
        }
    }

    // MARK: - Dialects

    private static func standard(name: String, entry: [String: Any], source: MCPSource) -> MCPServer {
        let url = entry["url"] as? String
        let type = (entry["type"] as? String ?? entry["transport"] as? String)?.lowercased()
        let transport: MCPTransport = switch type {
        case "stdio": .stdio
        case "http", "streamable-http", "streamablehttp": .http
        case "sse": .sse
        case let other?: .other(other)
        case nil: url == nil ? .stdio : .http
        }
        var extra: [String] = []
        if let env = entry["bearerTokenEnv"] as? String { extra.append(env) }
        if let token = entry["bearerToken"] as? String { extra += MCPValues.requiredVariables(in: token) }
        let disabled = (entry["disabled"] as? Bool) == true || (entry["enabled"] as? Bool) == false
        return build(name: name, source: source, transport: transport,
                     command: entry["command"] as? String, arguments: strings(entry["args"]), url: url,
                     cwd: entry["cwd"] as? String, env: entry["env"] as? [String: Any],
                     headers: entry["headers"] as? [String: Any], extraVariables: extra, disabled: disabled)
    }

    private static func openCode(name: String, entry: [String: Any], source: MCPSource) -> MCPServer {
        let type = (entry["type"] as? String)?.lowercased()
        let commandLine = strings(entry["command"])
        let url = entry["url"] as? String
        let transport: MCPTransport = switch type {
        case "local": .stdio
        case "remote": .http
        case let other?: .other(other)
        case nil: url == nil ? .stdio : .http
        }
        return build(name: name, source: source, transport: transport,
                     command: commandLine.first, arguments: Array(commandLine.dropFirst()), url: url, cwd: nil,
                     env: entry["environment"] as? [String: Any], headers: entry["headers"] as? [String: Any],
                     extraVariables: [], disabled: (entry["enabled"] as? Bool) == false)
    }

    private static func codex(name: String, entry: [String: Any], source: MCPSource) -> MCPServer {
        let url = entry["url"] as? String
        var headers = (entry["http_headers"] as? [String: Any]) ?? [:]
        var extra = strings(entry["env_vars"])
        for (key, variable) in (entry["env_http_headers"] as? [String: Any]) ?? [:] {
            guard let variable = variable as? String else { continue }
            headers[key] = "${\(variable)}"
        }
        if let token = entry["bearer_token_env_var"] as? String {
            headers["Authorization"] = "Bearer ${\(token)}"
            extra.append(token)
        }
        return build(name: name, source: source, transport: url == nil ? .stdio : .http,
                     command: entry["command"] as? String, arguments: strings(entry["args"]), url: url,
                     cwd: entry["cwd"] as? String, env: entry["env"] as? [String: Any],
                     headers: headers.isEmpty ? nil : headers, extraVariables: extra,
                     disabled: (entry["enabled"] as? Bool) == false)
    }

    // MARK: - Helpers

    private static func build(name: String, source: MCPSource, transport: MCPTransport, command: String?,
                              arguments: [String], url: String?, cwd: String?, env: [String: Any]?,
                              headers: [String: Any]?, extraVariables: [String], disabled: Bool) -> MCPServer {
        // Codex and OpenCode don't expand ${VAR} in env values; count only what the harness expands.
        let expands = source.dialect == .standard
        let pi = source.harness == .pi
        var variables = extraVariables
        if expands {
            for text in [command, url, cwd].compactMap({ $0 }) + arguments { variables += MCPValues.requiredVariables(in: text) }
            for value in (env ?? [:]).values.compactMap({ $0 as? String }) { variables += MCPValues.requiredVariables(in: value) }
            for value in (headers ?? [:]).values.compactMap({ $0 as? String }) { variables += MCPValues.requiredVariables(in: value) }
        } else if source.dialect == .openCode {
            for text in [url].compactMap({ $0 }) + arguments + ((env ?? [:]).values.compactMap { $0 as? String })
                + ((headers ?? [:]).values.compactMap { $0 as? String }) {
                variables += MCPValues.requiredVariables(in: text)
            }
        } else {
            for value in headers?.values.compactMap({ $0 as? String }) ?? [] { variables += MCPValues.requiredVariables(in: value) }
        }

        var state: MCPState = disabled ? .disabled : .active
        if !disabled, let approval = source.approval { state = approval.state(of: name) }
        if source.turnedOff.contains(name) { state = .disabled }
        if let reason = source.inactiveReason { state = .inactive(reason) }

        return MCPServer(
            name: name, file: source.file, keyPath: source.keyPath, scope: source.scope, transport: transport,
            command: command.map { MCPValues.maskedArguments([$0])[0] }, arguments: MCPValues.maskedArguments(arguments),
            url: url.map(MCPValues.maskedURL), workingDirectory: cwd,
            environment: settings(env, commandPrefix: pi), headers: settings(headers, commandPrefix: pi),
            variables: Array(Set(variables)).sorted(),
            uses: [MCPUse(harness: source.harness, layer: source.layer, precedence: source.precedence, state: state)],
            isReadOnly: source.isReadOnly, warnings: [])
    }

    private static func settings(_ table: [String: Any]?, commandPrefix: Bool) -> [MCPSetting] {
        (table ?? [:]).keys.sorted().map { MCPValues.setting($0, table![$0]!, commandPrefix: commandPrefix) }
    }

    static func strings(_ value: Any?) -> [String] {
        if let list = value as? [Any] {
            return list.compactMap { item in
                if let text = item as? String { return text }
                if item is [Any] || item is [String: Any] { return nil }
                return "\(item)"
            }
        }
        if let text = value as? String { return [text] }
        return []
    }
}
