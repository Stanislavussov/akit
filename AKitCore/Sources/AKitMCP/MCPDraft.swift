import AKitFoundation
import AKitModel
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
        /// Editing: the value already sits in the Keychain under this account. Empty `value` keeps it.
        public var keychainAccount: String?
        /// Editing: the value written in the file. Never shown; empty `value` keeps it
        /// (or moves it into the Keychain when `isSecret` is switched on).
        var existingLiteral: String?
        /// Editing: the original JSON value (keeps numbers and booleans as they were).
        var existingJSON: String?

        public init(key: String = "", value: String = "", isSecret: Bool = false, keychainAccount: String? = nil) {
            self.key = key
            self.value = value
            self.isSecret = isSecret
            self.keychainAccount = keychainAccount
        }

        /// The file holds a value the form doesn't show.
        public var hasHiddenValue: Bool { existingLiteral != nil }
        /// Nothing typed: the stored value (Keychain item or hidden literal) stays.
        public var keepsStoredValue: Bool { value.isEmpty && (keychainAccount != nil || existingLiteral != nil) }
    }

    public var name: String
    public var transport: Transport
    public var command: String
    public var arguments: [String]
    public var url: String
    public var environment: [Value]
    public var headers: [Value]
    /// Editing: fields of the entry the form doesn't cover (`cwd`, `lifecycle`, `timeout`, …),
    /// as JSON, written back unchanged.
    var preservedJSON: String?
    /// Write `type` for a stdio server (off when editing an entry that had none).
    var writesStdioType = true
    /// Editing an entry that spells the transport `transport` instead of `type`.
    var usesTransportKey = false

    /// The list the chosen transport uses: env for stdio, headers for remote servers.
    public var activeValues: [Value] { transport == .stdio ? environment : headers }

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
        let listName = transport == .stdio ? "Environment" : "Headers"
        let keys = activeValues.map { $0.key.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if Set(keys).count != keys.count { result.append("A name is used twice in \(listName).") }
        // Secret names end up in shell code (sh wrapper, env.sh, headersHelper): strict characters.
        // Plain values only go into JSON, where any printable name is fine.
        for value in activeValues {
            let key = value.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                result.append("Name “\(key)” has control characters.")
            } else if value.isSecret, transport == .stdio, !KeychainSecretStore.isVariableName(key) {
                result.append("Secret name “\(key)” may only use letters, digits and _ (not starting with a digit).")
            } else if value.isSecret, transport != .stdio, !KeychainSecretStore.isHeaderName(key) {
                result.append("Secret header “\(key)” has characters AKit can't put into a Keychain lookup.")
            }
        }
        for value in activeValues where value.isSecret {
            if value.key.trimmingCharacters(in: .whitespaces).isEmpty { result.append("A secret needs a name.") }
            if value.value.isEmpty, !value.keepsStoredValue { result.append("Secret \(value.key) is empty.") }
        }
        for value in activeValues where !value.isSecret && value.keychainAccount != nil && value.value.isEmpty {
            result.append("\(value.key) is in the Keychain: keep it secret or type a value.")
        }
        return result
    }

    /// Keychain account (and variable name) a secret is stored under.
    /// A `${VAR}` reference needs the env key itself; a Keychain lookup is free to use
    /// `<SERVER>_<KEY>` so two servers' `API_KEY`s don't overwrite each other.
    /// Headers always get `<SERVER>_<HEADER>` (e.g. `GITHUB_AUTHORIZATION`).
    public func variable(for value: Value, isHeader: Bool, lookup: Bool = false) -> String {
        if let account = value.keychainAccount { return account }
        let key = value.key.trimmingCharacters(in: .whitespaces)
        guard isHeader || lookup else { return key }
        let prefix = String(name.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }) + "_"
        if !isHeader, key.uppercased().hasPrefix(prefix), KeychainSecretStore.isVariableName(key) { return key }
        var raw = String("\(name)_\(key)".uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
        if raw.first?.isNumber == true { raw = "_" + raw }
        return raw
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

    static func draft(name: String, entry: [String: Any], dialect: MCPSource.Dialect) -> MCPDraft {
        var entry = entry
        if dialect == .codex {
            // Codex: bearer_token_env_var and env_http_headers become header references.
            var headers = entry["http_headers"] as? [String: Any] ?? [:]
            for (key, variable) in entry["env_http_headers"] as? [String: Any] ?? [:] { headers[key] = "${\(variable)}" }
            if let token = entry["bearer_token_env_var"] as? String { headers["Authorization"] = "Bearer ${\(token)}" }
            entry["headers"] = headers
        }
        return draft(name: name, entry)
    }

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

// MARK: - Secret names

extension MCPDraft {
    /// Whether a variable or header name reads like a credential (`API_KEY`, `Authorization`).
    public static func looksSecret(name: String) -> Bool { MCPValues.looksSecret(name: name) }
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

// MARK: - Editing an existing entry

extension MCPDraft {
    /// The form for an entry already in a config file. Literal env/header values stay hidden;
    /// AKit's own Keychain lookups (sh wrapper, Pi `!command`, Claude `headersHelper`) and
    /// `${VAR}` references to AKit Keychain items come back as Keychain secrets.
    public static func editing(name: String, entry: [String: Any], dialect: MCPSource.Dialect,
                               keychain: SecretStore) -> MCPDraft {
        var draft = MCPDraft.draft(name: name, entry: entry, dialect: dialect)
        var managed: Set<String> = dialect == .openCode
            ? ["type", "command", "environment", "url", "headers"]
            : ["type", "transport", "command", "args", "env", "url", "headers"]
        // Only AKit's own helper is rebuilt from the form; anyone else's is kept as it is.
        let ownHelper = (entry["headersHelper"] as? String).map { !KeychainSecretStore.helperHeaders($0).isEmpty } ?? false
        if ownHelper { managed.insert("headersHelper") }
        let preserved = entry.filter { !managed.contains($0.key) }
        if !preserved.isEmpty, let data = try? JSONSerialization.data(withJSONObject: preserved, options: [.sortedKeys]) {
            draft.preservedJSON = String(decoding: data, as: UTF8.self)
        }
        draft.writesStdioType = entry["type"] != nil
        draft.usesTransportKey = entry["type"] == nil && entry["transport"] != nil
        let rawEnv = (entry[dialect == .openCode ? "environment" : "env"] as? [String: Any]) ?? [:]
        let rawHeaders = (entry["headers"] as? [String: Any]) ?? [:]
        // Unwrap `/bin/sh -c 'A="$(security … -a 'A' -w)" && export A && exec "$0" "$@"' command args…`
        var wrapped: [(key: String, account: String)] = []
        if draft.command == "/bin/sh", draft.arguments.count >= 3, draft.arguments[0] == "-c",
           let accounts = KeychainSecretStore.wrapperAccounts(draft.arguments[1]) {
            wrapped = accounts
            draft.command = draft.arguments[2]
            draft.arguments = Array(draft.arguments.dropFirst(3))
        }
        func convert(_ list: [Value], raw: [String: Any]) -> [Value] {
            list.map { original in
                var value = original
                value.isSecret = false
                if let account = KeychainSecretStore.lookupAccount(inCommand: value.value.hasPrefix("!") ? String(value.value.dropFirst()) : "") {
                    value.value = ""
                    value.keychainAccount = account
                    value.isSecret = true
                } else if let variable = pureReference(value.value), keychain.contains(variable) {
                    value.value = ""
                    value.keychainAccount = variable
                    value.isSecret = true
                } else if !MCPValues.isReferenceOnly(value.value) {
                    value.existingLiteral = value.value
                    if let rawValue = raw[value.key], !(rawValue is String),
                       let data = try? JSONSerialization.data(withJSONObject: rawValue, options: [.fragmentsAllowed]) {
                        value.existingJSON = String(decoding: data, as: UTF8.self)
                    }
                    // A secret-looking value in the file is offered for the Keychain: saving it
                    // as is would also pass it to `claude mcp add-json` as an argument.
                    value.isSecret = MCPValues.looksSecret(name: value.key) || SecretFilter.masked(value.value) != value.value
                    value.value = ""
                }
                return value
            }
        }
        draft.environment = convert(draft.environment, raw: rawEnv)
        draft.headers = convert(draft.headers, raw: rawHeaders)
        for pair in wrapped where !draft.environment.contains(where: { $0.key == pair.key }) {
            draft.environment.append(Value(key: pair.key, isSecret: true, keychainAccount: pair.account))
        }
        if ownHelper, let helper = entry["headersHelper"] as? String {
            for (header, account) in KeychainSecretStore.helperHeaders(helper) {
                draft.headers.append(Value(key: header, isSecret: true, keychainAccount: account))
            }
        }
        return draft
    }

    /// `${VAR}` or `{env:VAR}` and nothing else → VAR.
    static func pureReference(_ text: String) -> String? {
        for pattern in [#"^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$"#, #"^\{env:([A-Za-z_][A-Za-z0-9_]*)\}$"#] {
            if let match = text.range(of: pattern, options: .regularExpression) {
                let inner = text[match].drop { $0 == "$" || $0 == "{" }.dropLast()
                return String(inner.hasPrefix("env:") ? inner.dropFirst(4) : inner)
            }
        }
        return nil
    }
}
