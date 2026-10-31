import Foundation

/// Keeps secrets out of what AKit shows from session files: transcripts may contain
/// tool output of `cat .env` or a read of auth.json. Two layers:
/// output of tools that read a known secret file is hidden completely, and common
/// token shapes are masked everywhere else.
public enum SecretFilter {
    public static let hiddenOutput = "[Hidden by AKit: this output comes from a file that usually holds secrets.]"
    public static let mask = "[secret hidden]"

    /// Whether a tool call reads or writes a file that usually holds secrets: its
    /// `file_path`/`path` names one, or its shell `command` (up to any heredoc) has one
    /// as a word. Merely mentioning such a file in a prompt or file content doesn't count.
    public static func readsSecretFile(_ input: Any?) -> Bool {
        readsSecretFile(input, depth: 0)
    }

    /// Also the inner `args` / `arguments` of an adapter's call (an MCP tool through Pi's
    /// `mcp` or `codemode` tool), as an object or a JSON string, a few levels deep.
    private static func readsSecretFile(_ input: Any?, depth: Int) -> Bool {
        guard depth < 4, let input = input as? [String: Any] else { return false }
        for key in ["file_path", "path", "filePath", "notebook_path"] {
            if let path = input[key] as? String, isSecretFile(path) { return true }
        }
        if let command = input["command"] as? String, commandReadsSecretFile(command) { return true }
        for key in ["args", "arguments", "input", "params"] {
            var inner = input[key]
            if let text = inner as? String, text.hasPrefix("{") { inner = try? JSONSerialization.jsonObject(with: Data(text.utf8)) }
            if readsSecretFile(inner, depth: depth + 1) { return true }
        }
        return false
    }

    /// Heredoc bodies are file content, not commands, so the text after `<<` is ignored.
    public static func commandReadsSecretFile(_ command: String) -> Bool {
        let beforeHeredoc = command.components(separatedBy: "<<").first ?? ""
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";|&()<>\"'`=,"))
        return beforeHeredoc.components(separatedBy: separators).contains(where: isSecretFile)
    }

    /// The tool input with the file content replaced when the call writes a secret file
    /// (Write/Edit fields, or the heredoc body of a shell command like `cat > .env <<EOF`).
    public static func redactedInput(_ input: Any?) -> Any? {
        guard readsSecretFile(input), var fields = input as? [String: Any] else { return input }
        for key in ["content", "new_string", "old_string", "edits", "text", "newText", "oldText"] where fields[key] != nil {
            fields[key] = hiddenOutput
        }
        if let command = fields["command"] as? String, let heredoc = command.range(of: "<<") {
            let lineEnd = command[heredoc.upperBound...].firstIndex(where: \.isNewline) ?? command.endIndex
            if lineEnd < command.endIndex {
                fields["command"] = String(command[..<lineEnd]) + "\n" + hiddenOutput
            }
        }
        return fields
    }

    public static func isSecretFile(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard let name = parts.last.map(String.init) else { return false }
        let parent = parts.dropLast().last.map(String.init)
        if secretFileNames.contains(name) { return true }
        // A glob that can name a secret file (`.e*`, `auth.*`, `.env?`) counts as one.
        // As the shell expands it: a leading dot must be written (FNM_PERIOD), and a bare `*` or `?`
        // (no letter in it) doesn't count.
        if name.contains(where: { "*?[".contains($0) }), name.contains(where: { $0.isLetter || $0.isNumber }) {
            let candidates = secretFileNames.union([".env", ".envrc", ".env.local"])
            if candidates.contains(where: { fnmatch(name, $0, FNM_PERIOD) == 0 }) { return true }
        }
        // .env, .env.local, .env* (glob), .envrc; not .envelope.ts
        if name == ".env" || name == ".envrc" || name.hasPrefix(".env.") || name.hasPrefix(".env*") { return true }
        if name.hasPrefix("id_"), parent == ".ssh", !name.hasSuffix(".pub") { return true }
        switch (parent, name) {
        case (".aws", "credentials"), (".docker", "config.json"), (".kube", "config"): return true
        // Pi's MCP file; other mcp.json files are usually project config without env.
        case ("agent", "mcp.json"): return parts.dropLast(2).last == ".pi"
        default: return false
        }
    }

    /// Credential stores and files that hold MCP server env/headers.
    private static let secretFileNames: Set<String> = [
        "auth.json", "settings.local.json", "models-store.json", "github-token", ".netrc", ".npmrc", ".pypirc",
        ".git-credentials", ".credentials.json", ".claude.json", ".mcp.json",
    ]

    /// Masks token-like values. Keys and surrounding text stay readable.
    public static func masked(_ text: String) -> String {
        // The token shapes and passwords are the Scrubber's own rules, so the two never drift apart.
        var counts: [String: Int] = [:]
        var current = text as NSString
        let present = Scrubber.presentHints(in: text)
        for rule in Scrubber.rules + Scrubber.passwordRules {
            current = Scrubber.apply(rule, to: current, present: present, counts: &counts)
        }
        return maskedNamedValues(current as String)
    }

    /// `masked` without the password rules: token shapes, keys and values after a secret's
    /// name. What is left for the password rules alone is a weaker sign (a test fixture's password).
    public static func maskedTokens(_ text: String) -> String {
        var counts: [String: Int] = [:]
        var current = text as NSString
        let present = Scrubber.presentHints(in: text)
        for rule in Scrubber.rules { current = Scrubber.apply(rule, to: current, present: present, counts: &counts) }
        return maskedNamedValues(current as String)
    }

    /// Values after a secret's name in environment and JSON style, which the Scrubber's own
    /// keyword rule leaves to entropy.
    static func maskedNamedValues(_ text: String) -> String {
        var result = text
        for (pattern, template) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            guard pattern.firstMatch(in: result, range: range) != nil else { continue }
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    private static let patterns: [(NSRegularExpression, String)] = [
        // Environment style: DB_PASSWORD=…, GITHUB_TOKEN="…" (upper-case names, no spaces around =,
        // so code like `API_KEY = os.environ["X"]` stays readable).
        (regex(#"\b([A-Z][A-Z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?)=["']?)[^\s"'\[\]()]{8,}"#),
         "$1\(mask)"),
        // JSON style: "access_token": "…" (quoted string values only, so "max_tokens": 4096 stays).
        (regex(#"(?i)("[\w-]*(api[_-]?key|token|secret|password|passwd|credential)[\w-]*"\s*:\s*")[^"]{8,}""#),
         "$1\(mask)\""),
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants; a typo is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }
}
