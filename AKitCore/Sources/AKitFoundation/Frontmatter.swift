import Foundation

/// Reads the `---` YAML header of SKILL.md / agent files.
/// Only the simple subset used in practice: top-level `key: value`, quoted values,
/// block scalars (`|`, `>`) and plain values continued on indented lines.
/// Nested maps and lists are skipped.
public enum Frontmatter {
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
