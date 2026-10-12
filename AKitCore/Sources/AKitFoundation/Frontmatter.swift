import Foundation

/// Reads the `---` YAML header of SKILL.md / agent files.
/// Only the simple subset used in practice: top-level `key: value`, quoted values,
/// block scalars (`|`, `>`) and plain values continued on indented lines.
/// Nested maps and lists are skipped.
public enum Frontmatter {
    /// The header's lines among `lines` (a text split at its line ends; a BOM may lead the first):
    /// between the opening `---` and the next line that is `---` with nothing before it, so an
    /// indented `---` inside a block value doesn't end the header. nil without a header.
    public static func header(in lines: [String]) -> Range<Int>? {
        guard let first = lines.first,
              (first.hasPrefix("\u{FEFF}") ? String(first.dropFirst()) : first).trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.hasPrefix("---") && $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }
        return 1..<end
    }

    /// A header line that sets `disable-model-invocation`: whether to true. The key bare or quoted,
    /// any spacing, the value bare or quoted, a trailing ` # comment` ignored. nil for any other line.
    public static func modelInvocationFlag(in line: String) -> Bool? {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let quotes = CharacterSet(charactersIn: "\"'")
        guard parts.count == 2, let first = line.first, first != " ", first != "\t",
              parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: quotes) == "disable-model-invocation" else { return nil }
        let value = (parts[1].components(separatedBy: " #").first ?? "").trimmingCharacters(in: .whitespaces)
        return value.trimmingCharacters(in: quotes).lowercased() == "true"
    }

    /// The text's header sets `disable-model-invocation: true` (only `/name` runs the skill). The
    /// one reading of the flag, for the skill scanner and for what changes it.
    public static func disablesModelInvocation(_ text: String) -> Bool {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard let header = header(in: lines) else { return false }
        return lines[header].contains { modelInvocationFlag(in: $0) == true }
    }

    public static func parse(_ text: String) -> [String: String] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if lines.first?.hasPrefix("\u{FEFF}") == true { lines[0].removeFirst() }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return [:]
        }
        let body = Array(lines[1..<end])

        var result: [String: String] = [:]
        var i = 0
        while i < body.count {
            let line = body[i]
            i += 1
            guard let first = line.first, first != " ", first != "\t", first != "#",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            // Indented lines that follow belong to this key.
            var continuation: [String] = []
            while i < body.count, body[i].isEmpty || body[i].first == " " || body[i].first == "\t" {
                continuation.append(body[i].trimmingCharacters(in: .whitespaces))
                i += 1
            }
            while continuation.last?.isEmpty == true { continuation.removeLast() }

            if let style = value.first, style == "|" || style == ">" {
                value = style == "|"
                    ? continuation.joined(separator: "\n")
                    : continuation.split(separator: "", omittingEmptySubsequences: false)
                        .map { $0.joined(separator: " ") }.joined(separator: "\n")
            } else if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
                value = q == "'" ? value.replacingOccurrences(of: "''", with: "'")
                                 : value.replacingOccurrences(of: "\\\"", with: "\"")
            } else if !continuation.isEmpty, !value.isEmpty {
                value = ([value] + continuation.filter { !$0.isEmpty }).joined(separator: " ")
            } else if value.isEmpty {
                continue // nested map or list: not supported, skip
            }
            result[key] = value
        }
        return result
    }
}
