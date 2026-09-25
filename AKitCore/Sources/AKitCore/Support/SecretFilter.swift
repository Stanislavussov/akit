import Foundation

/// Keeps secrets out of what AKit shows from session files: transcripts may contain
/// tool output of `cat .env` or a read of auth.json. Two layers:
/// output of tools that read a known secret file is hidden completely, and common
/// token shapes are masked everywhere else.
public enum SecretFilter {
    public static let hiddenOutput = "[Hidden by AKit: this output comes from a file that usually holds secrets.]"
    static let mask = "[secret hidden]"

    /// Whether a tool call reads a file that usually holds secrets: its `file_path`/`path`
    /// names one, or the first line of its shell `command` (before any heredoc) has one
    /// as a word. Merely mentioning such a file in a prompt or file content doesn't count.
    public static func readsSecretFile(_ input: Any?) -> Bool {
        guard let input = input as? [String: Any] else { return false }
        for key in ["file_path", "path", "filePath", "notebook_path"] {
            if let path = input[key] as? String, isSecretFile(path) { return true }
        }
        if let command = input["command"] as? String { return commandReadsSecretFile(command) }
        return false
    }

    public static func commandReadsSecretFile(_ command: String) -> Bool {
        let firstLine = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let beforeHeredoc = firstLine.components(separatedBy: "<<").first ?? ""
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ";|&()<>\"'`=,"))
        return beforeHeredoc.components(separatedBy: separators).contains(where: isSecretFile)
    }

    static func isSecretFile(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard let name = parts.last.map(String.init) else { return false }
        if secretFileNames.contains(name) || name == ".env" || name.hasPrefix(".env.") { return true }
        if name.hasPrefix("id_"), parts.dropLast().last == ".ssh", !name.hasSuffix(".pub") { return true }
        return name == "credentials" && parts.dropLast().last == ".aws"
    }

    private static let secretFileNames: Set<String> = [
        "auth.json", "settings.local.json", "models-store.json", "github-token", ".netrc", ".npmrc", ".pypirc",
    ]

    /// Masks token-like values. Keys and surrounding text stay readable.
    public static func masked(_ text: String) -> String {
        var result = text
        for (pattern, template) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            guard pattern.firstMatch(in: result, range: range) != nil else { continue }
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    private static let patterns: [(NSRegularExpression, String)] = [
        (regex(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#), mask),
        (regex(#"\b(sk-ant-|sk-proj-|sk-)[A-Za-z0-9_-]{20,}"#), mask),
        (regex(#"\b(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})"#), mask),
        (regex(#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#), mask),
        (regex(#"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#), mask),
        (regex(#"\bAIza[0-9A-Za-z_-]{35}\b"#), mask),
        (regex(#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#), mask), // JWT
        (regex(#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{16,}"#), "$1 \(mask)"),
        // Environment style: DB_PASSWORD=…, GITHUB_TOKEN="…" (upper-case names only).
        (regex(#"\b([A-Z][A-Z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?)\s*=\s*["']?)[^\s"']{8,}"#),
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
