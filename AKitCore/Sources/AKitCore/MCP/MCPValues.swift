import Foundation

/// Variable references and masking for MCP config values.
enum MCPValues {
    /// Set by the harness itself, never needed from the user.
    static let builtInVariables: Set<String> = [
        "CLAUDE_PLUGIN_ROOT", "CLAUDE_PLUGIN_DATA", "CLAUDE_PROJECT_DIR", "PLUGIN_ROOT", "PLUGIN_DATA",
        "HOME", "USER", "PATH", "PWD", "TMPDIR", "SHELL",
    ]

    static let hidden = SecretFilter.mask

    /// `${VAR}`, `${VAR:-default}` (Claude, Pi), `$env:VAR` (Pi), `{env:VAR}` (OpenCode), `{file:path}` (OpenCode).
    private static let referencePattern = try! NSRegularExpression(
        pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)(:-[^}]*)?\}|\$env:([A-Za-z_][A-Za-z0-9_]*)|\{env:([A-Za-z_][A-Za-z0-9_]*)\}|\{file:[^}]+\}"#)
    private static let defaultPattern = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*):-[^}]+\}"#)

    /// Names of variables `text` needs, without the ones that have a default.
    static func requiredVariables(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return referencePattern.matches(in: text, range: range).compactMap { match in
            for group in [1, 3, 4] {
                guard let range = Range(match.range(at: group), in: text) else { continue }
                if group == 1, match.range(at: 2).location != NSNotFound { return nil } // has a default
                let name = String(text[range])
                return builtInVariables.contains(name) ? nil : name
            }
            return nil
        }
    }

    static func hasReference(_ text: String) -> Bool {
        referencePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// `text` with all references removed.
    static func withoutReferences(_ text: String) -> String {
        referencePattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// `${X:-default}` → `${X:-…}`: a default is a literal and may be a secret.
    static func hidingDefaults(_ text: String) -> String {
        defaultPattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\\${$1:-…}")
    }

    /// Only references, optionally after a scheme word like `Bearer`.
    static func isReferenceOnly(_ text: String) -> Bool {
        guard hasReference(text) else { return false }
        let rest = withoutReferences(text).trimmingCharacters(in: .whitespaces).lowercased()
        return ["", "bearer", "basic", "token"].contains(rest)
    }

    /// An env or header value, safe to show.
    static func setting(_ key: String, _ raw: Any, commandPrefix: Bool) -> MCPSetting {
        guard let text = raw as? String else { return MCPSetting(key: key, value: .hidden) }
        if commandPrefix, text.hasPrefix("!"), !text.hasPrefix("!!") {
            return MCPSetting(key: key, value: .command(shownCommand(String(text.dropFirst()))))
        }
        let shown = hidingDefaults(text)
        return MCPSetting(key: key, value: isReferenceOnly(shown) ? .reference(shown) : .hidden)
    }

    private static let secretName = try! NSRegularExpression(
        pattern: #"(?i)(token|key|secret|passw|pwd|auth|bearer|credential|signature|session|cookie|dsn|connection|database.?url|db.?url|private)"#)

    static func looksSecret(name: String) -> Bool {
        let bare = name.drop { $0 == "-" }.lowercased()
        if ["pat", "sig", "code", "p"].contains(bare) { return true }
        return secretName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    private static let headerFlags: Set<String> = ["-H", "--header", "--headers"]
    private static let connectionPassword = try! NSRegularExpression(pattern: #"(?i)\b(password|pwd)=[^;]*"#)

    /// Arguments with secrets masked: values after `--token`-like flags, `NAME=value` with a
    /// secret-looking name, header values after `-H`/`--header`, URLs, connection-string
    /// passwords, known token shapes; `sh -c` scripts are masked word by word.
    static func maskedArguments(_ args: [String]) -> [String] {
        var result: [String] = []
        var previous = ""
        for raw in args {
            let arg = hidingDefaults(raw)
            defer { previous = arg }
            if isReferenceOnly(arg) { result.append(arg); continue }
            if headerFlags.contains(previous) {
                result.append(maskedHeader(arg))
                continue
            }
            if previous.hasPrefix("-"), !previous.contains("="), looksSecret(name: previous), !arg.hasPrefix("-") {
                result.append(hidden)
                continue
            }
            result.append(maskedWord(arg))
        }
        return result
    }

    /// One argument that isn't the value of a flag.
    private static func maskedWord(_ arg: String) -> String {
        if arg.contains(where: \.isWhitespace), !arg.contains("://") || arg.split(whereSeparator: \.isWhitespace).count > 1 {
            // A script (`sh -c "…"`) or several words: mask each word with the same rules.
            return maskedCommandLine(arg)
        }
        if let eq = arg.firstIndex(of: "="), eq != arg.startIndex, !arg.hasPrefix("http") {
            let name = String(arg[..<eq])
            let value = String(arg[arg.index(after: eq)...])
            if isReferenceOnly(value) { return arg }
            if looksSecret(name: name) { return name + "=" + hidden }
            if value.contains("://") { return name + "=" + maskedURL(value) }
        }
        if arg.contains("://") { return maskedURL(arg) }
        let text = connectionPassword.stringByReplacingMatches(
            in: arg, range: NSRange(arg.startIndex..., in: arg), withTemplate: "$1=\(hidden)")
        return SecretFilter.masked(text)
    }

    /// `Name: value` → value hidden unless it is only references.
    private static func maskedHeader(_ header: String) -> String {
        guard let colon = header.firstIndex(of: ":") else { return hidden }
        let value = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return isReferenceOnly(value) ? header : String(header[...colon]) + " " + hidden
    }

    /// Password managers: their arguments name the item, they don't hold the secret.
    static let secretManagers: Set<String> = ["security", "op", "pass", "gopass", "bw", "vault", "secret-tool", "doppler", "infisical"]

    /// A command that prints a secret: shown in full for known password managers,
    /// otherwise only the program (`echo …`), since its arguments may be the secret itself.
    static func shownCommand(_ line: String) -> String {
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return "" }
        if secretManagers.contains(URL(filePath: first).lastPathComponent) { return maskedCommandLine(line) }
        return words.count > 1 ? first + " …" : first
    }

    /// A command line (Pi `!command`, `sh -c` script) masked word by word.
    static func maskedCommandLine(_ line: String) -> String {
        maskedArguments(line.split(whereSeparator: \.isWhitespace).map(String.init)).joined(separator: " ")
    }

    private static let userInfo = try! NSRegularExpression(pattern: #"://[^/?#\s]*@"#)
    private static let queryItem = try! NSRegularExpression(pattern: #"([?&])([^=&#\s]+)=([^&#\s]*)"#)
    private static let pathSegment = try! NSRegularExpression(pattern: #"(?<=/)[^/?#\s]+"#)

    /// URL with user info, secret-looking query values and token-like path segments masked.
    /// Works on the text, so `${VAR}` references stay exactly as written.
    static func maskedURL(_ raw: String) -> String {
        var result = hidingDefaults(raw)
        result = userInfo.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                   withTemplate: "://hidden@")
        for match in queryItem.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let name = Range(match.range(at: 2), in: result), let value = Range(match.range(at: 3), in: result)
            else { continue }
            let text = String(result[value])
            guard looksSecret(name: String(result[name])), !text.isEmpty, !isReferenceOnly(text) else { continue }
            result.replaceSubrange(value, with: "hidden")
        }
        // Path segments after the host: long random-looking ones are keys (Pipedream, Zapier URLs).
        if let scheme = result.range(of: "://") {
            let pathStart = result[scheme.upperBound...].firstIndex(of: "/") ?? result.endIndex
            let range = NSRange(pathStart..., in: result)
            for match in pathSegment.matches(in: result, range: range).reversed() {
                guard let segment = Range(match.range, in: result), looksRandom(String(result[segment])) else { continue }
                result.replaceSubrange(segment, with: "hidden")
            }
        }
        return SecretFilter.masked(result)
    }

    /// UUIDs and long strings mixing letters and digits.
    static func looksRandom(_ text: String) -> Bool {
        if hasReference(text) { return false }
        if UUID(uuidString: text) != nil { return true }
        let letters = text.contains(where: \.isLetter)
        let digits = text.filter(\.isNumber).count
        return text.count >= 20 && letters && digits >= 2
    }
}
