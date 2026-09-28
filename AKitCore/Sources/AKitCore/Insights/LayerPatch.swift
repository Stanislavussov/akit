import Foundation

/// The two `layer.yaml` edits `akit recommend` makes to one skill entry: `mode: manual`
/// (`recommend apply`) and `keep_auto: true` (`recommend dismiss`). The rest of the file
/// (comments, order, line endings) stays as it is; the result is read back through
/// `LayerManifest.parse` and must differ from the old layer in that one field only.
enum LayerPatch {
    enum Change: Equatable {
        /// `mode: auto` → `mode: manual`.
        case manual
        /// `keep_auto: true`.
        case keepAuto

        var key: String {
            switch self {
            case .manual: "mode"
            case .keepAuto: "keep_auto"
            }
        }

        var value: String {
            switch self {
            case .manual: "manual"
            case .keepAuto: "true"
            }
        }

        /// The commit message: no project, no evidence.
        func message(skill: String, layer: String) -> String {
            switch self {
            case .manual: "Set \(skill) to manual in layer \(layer)"
            case .keepAuto: "Keep \(skill) auto in layer \(layer)"
            }
        }
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Larger files are not edited or checked (the line diff is quadratic).
    static let maxBytes = 200_000

    static func path(layer: String) -> String { "layers/\(layer)/layer.yaml" }

    /// The text with the change made to the skill's entry in the top-level `skills:` block list.
    static func edit(_ text: String, skill: String, layer: String, change: Change) throws(Failure) -> String {
        guard text.utf8.count <= maxBytes else { throw Failure(message: "\(path(layer: layer)) is too large to edit safely.") }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline)
        guard let key = lines.firstIndex(where: { $0.hasPrefix("skills:") }) else {
            throw Failure(message: "\(path(layer: layer)) has no skills list.")
        }
        var rest = lines[key].dropFirst("skills:".count).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("#") { rest = "" }
        guard rest.isEmpty else {
            throw Failure(message: "The \(layer) layer's skills are written on one line. Write them as a block list (one “- name” per line) and try again.")
        }
        var end = key + 1
        while end < lines.count, lines[end].isEmpty || lines[end].first == " " || lines[end].first == "-" { end += 1 }
        let items = (key + 1..<end).filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("-") }
        let indent = items.first.map { lines[$0].prefix { $0 == " " }.count } ?? 0
        let starts = items.filter { lines[$0].prefix { $0 == " " }.count == indent }

        // The item: "- tdd", "- name: tdd", or "- mode: …" first with "name: tdd" below it.
        var found: (start: Int, end: Int)?
        for start in starts {
            let blockEnd = starts.first { $0 > start } ?? end
            if (start..<blockEnd).contains(where: { entry(lines[$0], dash: $0 == start)?.key == "name" && entry(lines[$0], dash: $0 == start)?.value == skill })
                || bareName(lines[start]) == skill {
                found = (start, blockEnd)
                break
            }
        }
        guard let found else {
            throw Failure(message: "\(skill) is not in the \(layer) layer's skills list.")
        }
        let dash = lines[found.start]
        let dashIndent = String(dash.prefix { $0 == " " })
        if bareName(dash) == skill {
            // A bare name becomes a map with the name and the changed field.
            let after = dash.dropFirst(dashIndent.count + 1).drop { $0 == " " }
            lines[found.start] = "\(dashIndent)- name: \(after)"
            lines.insert("\(dashIndent)  \(change.key): \(change.value)", at: found.start + 1)
        } else {
            // Keys of the map sit where the text after "- " starts.
            let keyColumn = dashIndent.count + 1 + dash.dropFirst(dashIndent.count + 1).prefix { $0 == " " }.count
            var existing: Int?
            for index in found.start..<found.end {
                let isDash = index == found.start
                guard isDash || lines[index].prefix(while: { $0 == " " }).count == keyColumn,
                      let field = entry(lines[index], dash: isDash) else { continue }
                if field.key == change.key { existing = index }
            }
            if let existing {
                lines[existing] = replacingValue(of: lines[existing], with: change.value)
            } else {
                // A new key goes last in the entry, before any blank lines after it.
                var last = found.end
                while last > found.start + 1, lines[last - 1].trimmingCharacters(in: .whitespaces).isEmpty { last -= 1 }
                lines.insert(String(repeating: " ", count: keyColumn) + "\(change.key): \(change.value)", at: last)
            }
        }
        let result = lines.joined(separator: newline)
        if let problem = problem(before: text, after: result, skill: skill, layer: layer, change: change) {
            throw Failure(message: "AKit couldn't change \(skill) in \(path(layer: layer)) safely (\(problem)). Edit it by hand.")
        }
        return result
    }

    /// Why `after` is not exactly `before` with the change made to the skill; nil when it is.
    /// Read back through `LayerManifest.parse`, and line by line: every changed line is the skill's
    /// name, mode or keep_auto line (comments only as they were), so nothing else can ride along.
    static func problem(before: String, after: String, skill: String, layer: String, change: Change) -> String? {
        guard before.utf8.count <= maxBytes, after.utf8.count <= maxBytes else { return "the file is too large" }
        let folder = URL(filePath: "/\(layer)")
        guard let old = try? LayerManifest.parse(before, folder: folder), let new = try? LayerManifest.parse(after, folder: folder) else {
            return "it doesn't read as a layer"
        }
        guard new.problems == old.problems else { return "it reads with other problems" }
        guard let entry = old.layer.skills.first(where: { $0.name == skill }), old.layer.skills.filter({ $0.name == skill }).count == 1 else {
            return "\(skill) is not listed once"
        }
        let expected: LayerSkill
        switch change {
        case .manual:
            guard entry.mode == .auto else { return "\(skill) is not auto" }
            expected = LayerSkill(name: skill, mode: .manual, when: entry.when, override: entry.override, keepAuto: entry.keepAuto)
        case .keepAuto:
            guard !entry.keepAuto else { return "\(skill) is kept auto already" }
            expected = LayerSkill(name: skill, mode: entry.mode, when: entry.when, override: entry.override, keepAuto: true)
        }
        let wanted = old.layer.skills.map { $0.name == skill ? expected : $0 }
        guard new.layer.skills == wanted, new.layer.fields == old.layer.fields, new.layer.files == old.layer.files,
              new.layer.requires == old.layer.requires, new.layer.conflicts == old.layer.conflicts,
              new.layer.description == old.layer.description else { return "more than that skill's \(change.key) changed" }

        let names: Set<String> = [skill, "\"\(skill)\"", "'\(skill)'"]
        func allowed(_ line: String, added: Bool) -> (ok: Bool, comment: String?) {
            var text = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")).trimmingCharacters(in: .whitespaces)
            var comment: String?
            if let hash = text.range(of: " #") {
                comment = String(text[hash.lowerBound...]).trimmingCharacters(in: .whitespaces)
                text = text[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            if text.hasPrefix("- ") { text = text.dropFirst(2).trimmingCharacters(in: .whitespaces) }
            if !added, names.contains(text) { return (true, comment) }  // a bare name became a map
            guard let colon = text.firstIndex(of: ":") else { return (false, comment) }
            let key = text[..<colon].trimmingCharacters(in: .whitespaces)
            let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "name": return (names.contains(value), comment)
            case change.key:
                let values: Set<String> = added ? [change.value] : change == .manual ? ["auto"] : ["false"]
                return (values.contains(value), comment)
            default: return (false, comment)
            }
        }
        var removedComments: [String] = []
        var addedComments: [String] = []
        for line in TextDiff.lines(from: before, to: after) {
            switch line {
            case .same: continue
            case .removed(let text):
                let check = allowed(text, added: false)
                guard check.ok else { return "it would remove “\(text.trimmingCharacters(in: .whitespaces))”" }
                if let comment = check.comment { removedComments.append(comment) }
            case .added(let text):
                let check = allowed(text, added: true)
                guard check.ok else { return "it would add “\(text.trimmingCharacters(in: .whitespaces))”" }
                if let comment = check.comment { addedComments.append(comment) }
            }
        }
        for comment in addedComments {
            guard let index = removedComments.firstIndex(of: comment) else { return "it would add a comment" }
            removedComments.remove(at: index)
        }
        return nil
    }

    // MARK: - Commit

    /// Writes the edited layer.yaml and commits it alone with the change's message. A work Mac goes
    /// through `WorkFilter` (path, message and the diff against HEAD checked; the brain's own
    /// identity); a personal Mac commits like other brain edits. Refused when the file changed
    /// since `before` was read or has uncommitted edits.
    static func commit(skill: String, layer: String, change: Change, before: String, after: String, brain root: URL,
                       machine: MachineProfile, env: HarnessEnvironment) async throws(Failure) {
        let path = path(layer: layer), url = root.appending(path: path)
        guard (try? String(contentsOf: url, encoding: .utf8)) == before else {
            throw Failure(message: "\(path) changed since it was read; run akit recommend again.")
        }
        let message = change.message(skill: skill, layer: layer)
        if machine.isWork {
            do {
                try await WorkFilter.commit(.layer(layer: layer, skill: skill, change: change), files: [path: Data(after.utf8)],
                                            message: message, brain: root, machine: machine, env: env)
            } catch {
                throw Failure(message: error.message)
            }
            return
        }
        let isRepo = FileManager.default.fileExists(atPath: root.appending(path: ".git").path)
        if isRepo, !(try await git(["status", "--porcelain", "--", path], in: root, env: env)).isEmpty {
            throw Failure(message: "\(path) has uncommitted changes. Commit or discard them first.")
        }
        do {
            try Data(after.utf8).write(to: url, options: .atomic)
        } catch {
            throw Failure(message: "Couldn't write \(path): \(error.localizedDescription)")
        }
        guard isRepo else { return }
        try await git(["add", "--", path], in: root, env: env)
        try await git(["commit", "--quiet", "-m", message, "--", path], in: root, env: env)
    }

    @discardableResult
    private static func git(_ arguments: [String], in root: URL, env: HarnessEnvironment) async throws(Failure) -> String {
        guard let git = env.findExecutable("git") else { throw Failure(message: "git was not found, so nothing was committed.") }
        let result = await ProcessRunner.run(git, arguments: arguments, directory: root, environment: env.gitVariables, timeout: 30)
        guard let result, result.succeeded else {
            let output = result.map(\.failureText) ?? "couldn't start git"
            throw Failure(message: "git \(arguments[0]) failed: \(output)")
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Lines

    /// `key: value` of a map line (after "- " on the item's first line); nil for anything else.
    private static func entry(_ line: String, dash: Bool) -> (key: String, value: String)? {
        var text = line.trimmingCharacters(in: .whitespaces)
        if dash {
            guard text.hasPrefix("-") else { return nil }
            text = text.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        if let comment = text.range(of: " #") { text = text[..<comment.lowerBound].trimmingCharacters(in: .whitespaces) }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let key = text[..<colon].trimmingCharacters(in: .whitespaces)
        let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (key, value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
    }

    /// The name of a bare item (`- tdd`, `- "tdd"  # note`); nil for a map item.
    private static func bareName(_ line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("-") else { return nil }
        text = text.dropFirst().trimmingCharacters(in: .whitespaces)
        if let comment = text.range(of: " #") { text = text[..<comment.lowerBound].trimmingCharacters(in: .whitespaces) }
        guard !text.isEmpty, !text.contains(":") else { return nil }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// The line with its value replaced; a trailing comment stays.
    private static func replacingValue(of line: String, with value: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }
        let tail = line[line.index(after: colon)...]
        let comment = tail.range(of: " #").map { String(tail[$0.lowerBound...]) } ?? ""
        let spacing = comment.isEmpty ? "" : String(tail[..<(tail.range(of: " #")?.lowerBound ?? tail.endIndex)]
            .reversed().prefix { $0 == " " })
        return String(line[...colon]) + " " + value + spacing + comment
    }
}
