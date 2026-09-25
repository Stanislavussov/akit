import Foundation

/// A server the user is adding, filled from the form or from pasted JSON.
/// Secret values live here only until Apply moves them into the Keychain.
public struct MCPDraft: Hashable, Sendable {
    public enum Transport: String, CaseIterable, Hashable, Sendable { case stdio, http, sse }

    public struct Value: Hashable, Sendable, Identifiable {
        public var id = UUID()
        public var key: String
        public var value: String
        /// Stored in the Keychain; the config gets a reference or a lookup instead.
        public var isSecret: Bool

        public init(key: String = "", value: String = "", isSecret: Bool = false) {
            self.key = key
            self.value = value
            self.isSecret = isSecret
        }
    }

    public var name: String
    public var transport: Transport
    public var command: String
    public var arguments: [String]
    public var url: String
    public var environment: [Value]
    public var headers: [Value]

    public init(name: String = "", transport: Transport = .stdio, command: String = "", arguments: [String] = [],
                url: String = "", environment: [Value] = [], headers: [Value] = []) {
        self.name = name
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.environment = environment
        self.headers = headers
    }

    /// Problems that block Apply. Empty = OK.
    public var problems: [String] {
        var result: [String] = []
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { result.append("Name is required.") }
        if trimmed.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) == nil, !trimmed.isEmpty {
            result.append("Name may only contain letters, digits, \"-\", \"_\" and \".\".")
        }
        switch transport {
        case .stdio: if command.trimmingCharacters(in: .whitespaces).isEmpty { result.append("Command is required.") }
        case .http, .sse:
            let url = URL(string: url.trimmingCharacters(in: .whitespaces))
            if url?.scheme == nil || url?.host() == nil { result.append("URL must look like https://host/path.") }
        }
        for list in [environment, headers] {
            let keys = list.map { $0.key.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if Set(keys).count != keys.count { result.append("A name is used twice in \(list == environment ? "Environment" : "Headers").") }
        }
        for value in environment + headers where value.isSecret {
            if value.key.trimmingCharacters(in: .whitespaces).isEmpty { result.append("A secret needs a name.") }
            if value.value.isEmpty { result.append("Secret \(value.key) is empty.") }
        }
        return result
    }

    /// Variable name a secret is stored and referenced under: env keys as is, headers get
    /// `<SERVER>_<HEADER>` (e.g. `GITHUB_AUTHORIZATION`).
    public func variable(for value: Value, isHeader: Bool) -> String {
        let key = value.key.trimmingCharacters(in: .whitespaces)
        guard isHeader else { return key }
        let raw = "\(name)_\(key)".uppercased()
        return String(raw.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }
}

// MARK: - Pasted JSON

extension MCPDraft {
    /// Servers from pasted JSON. Accepted shapes:
    /// `{"mcpServers": {name: server}}` (Claude, Cursor, Pi), `{"mcp": {name: server}}` (OpenCode),
    /// `{name: server}`, a single server object (name left empty), or `"name": {…}` without braces.
    /// Server fields: `command` (string or array), `args`, `env`/`environment`, `url`, `type`, `headers`.
    public static func parse(json text: String) throws -> [MCPDraft] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var object: [String: Any]
        do {
            object = try ConfigText.jsonObject(Data(trimmed.utf8), jsonc: true)
        } catch {
            // `"name": {…}` copied out of a bigger file.
            guard let wrapped = try? ConfigText.jsonObject(Data("{\(trimmed)}".utf8), jsonc: true) else {
                throw ConfigTextError("This is not valid JSON: \(error.localizedDescription)")
            }
            object = wrapped
        }
        for key in ["mcpServers", "mcp_servers", "servers", "mcp"] {
            if let table = object[key] as? [String: Any] { object = table; break }
        }
        if isServer(object) { return [draft(name: "", object)] }
        let drafts = object.keys.sorted().compactMap { name -> MCPDraft? in
            guard let entry = object[name] as? [String: Any], isServer(entry) else { return nil }
            return draft(name: name, entry)
        }
        if drafts.isEmpty { throw ConfigTextError("No MCP server found: expected \"command\" or \"url\".") }
        return drafts
    }

    static func isServer(_ object: [String: Any]) -> Bool { object["command"] != nil || object["url"] != nil }

    static func draft(name: String, _ entry: [String: Any]) -> MCPDraft {
        var command = MCPReader.strings(entry["command"])
        let arguments = command.count > 1 ? Array(command.dropFirst()) : MCPReader.strings(entry["args"])
        if command.count > 1 { command = [command[0]] }
        let url = entry["url"] as? String ?? ""
        let type = (entry["type"] as? String ?? entry["transport"] as? String)?.lowercased()
        let transport: Transport = switch type {
        case "sse": .sse
        case "http", "streamable-http", "streamablehttp", "remote": .http
        case "stdio", "local": .stdio
        default: url.isEmpty ? .stdio : .http
        }
        func values(_ raw: Any?) -> [Value] {
            let table = raw as? [String: Any] ?? [:]
            return table.keys.sorted().map { key in
                let text = table[key].map { "\($0)" } ?? ""
                // A pasted literal that looks like a credential is kept secret by default.
                let secret = !MCPValues.hasReference(text) && (MCPValues.looksSecret(name: key) || SecretFilter.masked(text) != text)
                return Value(key: key, value: text, isSecret: secret)
            }
        }
        return MCPDraft(name: name, transport: transport, command: command.first ?? "", arguments: arguments, url: url,
                        environment: values(entry["env"] ?? entry["environment"]), headers: values(entry["headers"]))
    }
}

// MARK: - Arguments as one line

extension MCPDraft {
    /// Splits `-y "@scope/pkg" --dir 'my folder'` like a shell (quotes and backslashes, no expansion).
    public static func splitArguments(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        var escaped = false
        for char in line {
            if escaped { current.append(char); escaped = false; continue }
            if char == "\\", quote != "'" { escaped = true; hasToken = true; continue }
            if let open = quote {
                if char == open { quote = nil } else { current.append(char) }
                continue
            }
            if char == "\"" || char == "'" { quote = char; hasToken = true; continue }
            if char.isWhitespace {
                if hasToken { result.append(current); current = ""; hasToken = false }
                continue
            }
            current.append(char)
            hasToken = true
        }
        if hasToken { result.append(current) }
        return result
    }

    /// The reverse of `splitArguments`: quotes arguments that need it.
    public static func joinArguments(_ arguments: [String]) -> String {
        arguments.map { arg in
            if !arg.isEmpty, arg.allSatisfy({ !$0.isWhitespace && !"\"'\\$`".contains($0) }) { return arg }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
