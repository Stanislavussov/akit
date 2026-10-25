import AKitFoundation
import Foundation

/// Renaming a note or a map (R3): plan → verify → all or nothing.
///
/// 1. Every link value in the notes and maps of `areas/` whose resolution is the old id is collected.
/// 2. Each gets a new value: the alias, `#heading`, `.md` and the `[[ ]]` or `akit:` form are kept,
///    and the path part is as short as the old one was, if that still resolves (else the full id).
///    In maps only the JSON-encoded `"link"` value tokens change; the rest of the file keeps its bytes.
/// 3. Every link in the base is resolved before and after, on the planned contents: only the
///    planned links may change their target (this catches a silent retarget, like `a/foo → a/bar`
///    while `b/bar` exists).
/// 4. Each changed map is parsed again; its (element id, target) pairs must be exactly the expected ones.
/// 5. Any failure refuses the whole rename with the planned diff. `apply` flushes the commit
///    queue, writes, moves the file and commits once; a failed write puts back what was written.
public struct KnowledgeRename: Sendable, Equatable, Encodable {
    public enum Kind: String, Encodable, Sendable { case note, map }

    public struct LinkChange: Encodable, Sendable, Equatable {
        public let old: String
        public let new: String
    }

    public struct FileChange: Encodable, Sendable, Equatable {
        /// Base-relative, as it is now.
        public let path: String
        /// Base-relative after the rename: differs only for the renamed file.
        public let newPath: String
        public let links: [LinkChange]
        /// The bytes as read when planning, and the planned bytes.
        let original: Data
        let planned: Data

        private enum CodingKeys: String, CodingKey { case path, newPath, links }
    }

    public let kind: Kind
    /// Ids: `payments/billing`, `payments/maps/overview`.
    public let from: String
    public let to: String
    /// The renamed file first, then every file with a changed link, by path.
    public let files: [FileChange]

    /// How many links change.
    public var linkCount: Int { files.reduce(0) { $0 + $1.links.count } }

    /// The plan as text: the move, then each file's changed links.
    public var diff: String {
        var lines: [String] = []
        for file in files {
            lines.append(file.path == file.newPath ? file.path : "\(file.path) → \(file.newPath)")
            for link in file.links {
                lines.append("  - \(link.old)")
                lines.append("  + \(link.new)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Link tokens

    /// One link in a file's text: where its value is, and the value as `KnowledgeLinks` reads it.
    struct Token {
        let range: Range<String.Index>
        let value: String
    }

    /// Links in a note: `[[…]]` (and `![[…]]`), then `akit:note/…` / `akit:map/…` outside them (a
    /// full stop or comma after one ends the sentence, not the link).
    static func noteTokens(_ text: String) -> [Token] {
        var tokens: [Token] = []
        for match in text.matches(of: /\[\[[^\[\]\n]+\]\]/) { tokens.append(Token(range: match.range, value: String(match.output))) }
        for match in text.matches(of: /akit:(?:note|map)\/[^\s\)\]>"'`]*[^\s\)\]>"'`.,;:!?]/) where !tokens.contains(where: { $0.range.overlaps(match.range) }) {
            tokens.append(Token(range: match.range, value: String(match.output)))
        }
        return tokens.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Links in a map: the body of every JSON string value of a `"link"` key, decoded.
    static func mapTokens(_ text: String) -> [Token]? {
        var tokens: [Token] = []
        for match in text.matches(of: /"link"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            let body = match.output.1
            guard let value = try? JSONSerialization.jsonObject(with: Data("\"\(body)\"".utf8), options: .fragmentsAllowed) as? String
            else { return nil }
            tokens.append(Token(range: body.startIndex..<body.endIndex, value: value))
        }
        return tokens
    }

    /// A string as a JSON string body (no quotes), slashes not escaped.
    static func jsonBody(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8), text.count >= 2 else { return nil }
        return String(text.dropFirst().dropLast())
    }

    /// The new value of a link that pointed to the renamed item, or nil when no form resolves to it.
    static func rewrite(_ value: String, to newID: String, isMap: Bool, from path: String, targets: KnowledgeLinks) -> String? {
        let wanted: KnowledgeLinks.Resolution = isMap ? .map(newID) : .note(newID)
        var inner = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let wiki = inner.hasPrefix("[[") && inner.hasSuffix("]]")
        if wiki { inner = String(inner.dropFirst(2).dropLast(2)) }
        func wrap(_ text: String) -> String { wiki ? "[[\(text)]]" : text }
        for prefix in ["akit:note/", "akit:map/"] where inner.hasPrefix(prefix) {
            let candidate = wrap(prefix + newID)
            return targets.resolve(candidate, from: path) == wanted ? candidate : nil
        }
        // target | alias, target #heading: only the target part changes.
        let cut = inner.firstIndex { $0 == "|" || $0 == "#" || $0 == "\\" } ?? inner.endIndex
        var target = String(inner[..<cut]).trimmingCharacters(in: .whitespaces)
        let rest = String(inner[cut...])
        var lead = ""
        if target.hasPrefix("/") { lead = "/"; target.removeFirst() }
        if target.lowercased().hasPrefix("areas/") { lead += String(target.prefix(6)); target.removeFirst(6) }
        var ext = ""
        for suffix in [".md", ".excalidraw"] where target.lowercased().hasSuffix(suffix) {
            ext = String(target.suffix(suffix.count))
            target.removeLast(suffix.count)
        }
        let parts = newID.split(separator: "/").map(String.init)
        let length = target.split(separator: "/").count
        var forms: [String] = []
        if length > 0, length <= parts.count { forms.append(parts.suffix(length).joined(separator: "/")) }
        if !forms.contains(newID) { forms.append(newID) }
        for form in forms {
            let candidate = wrap(lead + form + ext + rest)
            if targets.resolve(candidate, from: path) == wanted { return candidate }
        }
        return nil
    }
}

extension KnowledgeBase {
    /// Plans and verifies renaming a note or a map. `new` is a name (same folder), or for a note
    /// an id with its area (`logistics/invoicing`). Throws, writing nothing, when anything is off.
    public func planRename(_ name: String, to new: String) throws(Failure) -> KnowledgeRename {
        let item = try self.item(name)
        let kind: KnowledgeRename.Kind
        switch item.kind {
        case .note: kind = .note
        case .map: kind = .map
        case .area: throw Failure(message: "\(item.id) is an area; only a note or a map can be renamed.")
        }
        let old = item.id
        let toID = try renamedID(old, to: new, kind: kind)
        let ext = kind == .note ? ".md" : ".excalidraw"
        let oldPath = "areas/\(old)\(ext)", newPath = "areas/\(toID)\(ext)"
        if toID == old { throw Failure(message: "\(old) has that name already.") }
        let caseOnly = toID.lowercased() == old.lowercased()
        if !caseOnly, FileManager.default.fileExists(atPath: root.appending(path: newPath).path) {
            throw Failure(message: "\(newPath) exists already.")
        }

        let before = linkTargets()
        func swap(_ id: String) -> String { id == old ? toID : id }
        let after = kind == .note ? KnowledgeLinks(notes: before.notes.map(swap), maps: before.maps)
            : KnowledgeLinks(notes: before.notes, maps: before.maps.map(swap))
        func moved(_ resolution: KnowledgeLinks.Resolution) -> KnowledgeLinks.Resolution {
            switch resolution {
            case .note(let id) where kind == .note: return .note(swap(id))
            case .map(let id) where kind == .map: return .map(swap(id))
            case .ambiguous(let ids): return .ambiguous(ids.map { kind == .note && before.notes.contains($0) || kind == .map && before.maps.contains($0) ? swap($0) : $0 }.sorted())
            default: return resolution
            }
        }
        let oldTarget: KnowledgeLinks.Resolution = kind == .note ? .note(old) : .map(old)

        var changes: [KnowledgeRename.FileChange] = []
        var problems: [String] = []
        for file in Self.files(in: areasFolder) {
            let id = Self.id(of: file, areas: areasFolder)
            let isMapFile = file.pathExtension == "excalidraw"
            let path = "areas/\(id).\(file.pathExtension)"
            let filePath = path == oldPath ? newPath : path
            guard let data = try? Data(contentsOf: file) else {
                problems.append("\(path) can't be read")
                continue
            }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            guard let tokens = isMapFile ? KnowledgeRename.mapTokens(text) : KnowledgeRename.noteTokens(text) else {
                problems.append("\(path) has a link value that isn't valid JSON")
                continue
            }
            // Plan (steps 1–2): the text between the changed tokens is copied as it is.
            var planned = ""
            var copied = text.startIndex
            var links: [KnowledgeRename.LinkChange] = []
            var changed: Set<Int> = []
            for (index, token) in tokens.enumerated() where before.resolve(token.value, from: path) == oldTarget {
                guard let value = KnowledgeRename.rewrite(token.value, to: toID, isMap: kind == .map, from: filePath, targets: after) else {
                    problems.append("no link to \(toID) can stand for \(token.value) in \(path)")
                    continue
                }
                guard let written = isMapFile ? KnowledgeRename.jsonBody(value) : value else {
                    problems.append("\(value) can't be written as JSON in \(path)")
                    continue
                }
                planned += text[copied..<token.range.lowerBound] + written
                copied = token.range.upperBound
                links.append(KnowledgeRename.LinkChange(old: token.value, new: value))
                changed.insert(index)
            }
            planned += text[copied...]
            // Verify (step 3): every link of the file, before and after.
            guard let plannedTokens = isMapFile ? KnowledgeRename.mapTokens(planned) : KnowledgeRename.noteTokens(planned),
                  plannedTokens.count == tokens.count else {
                problems.append("the planned \(path) doesn't keep its links")
                continue
            }
            for (index, token) in tokens.enumerated() {
                let was = before.resolve(token.value, from: path)
                let expected = changed.contains(index) ? (kind == .note ? .note(toID) : .map(toID)) : moved(was)
                let now = after.resolve(plannedTokens[index].value, from: filePath)
                if now != expected {
                    problems.append("\(plannedTokens[index].value) in \(path) would point to \(Self.describe(now)) instead of \(Self.describe(expected))")
                }
            }
            let plannedData = Data(planned.utf8)
            // Verify (step 4): a changed map parses, and links exactly the expected targets.
            if isMapFile, plannedData != data {
                switch (ExcalidrawFile.parse(data), ExcalidrawFile.parse(plannedData)) {
                case (.success(let old), .success(let new)):
                    let expected = Self.linkTargets(of: old, from: path, targets: before).mapValues(moved)
                    let got = Self.linkTargets(of: new, from: filePath, targets: after)
                    if got != expected { problems.append("the planned \(path) links other elements than expected") }
                default:
                    problems.append("the planned \(path) isn't an Excalidraw scene")
                }
            }
            if !links.isEmpty || path == oldPath {
                changes.append(KnowledgeRename.FileChange(path: path, newPath: filePath, links: links, original: data, planned: plannedData))
            }
        }
        changes.sort { ($0.path == oldPath ? 0 : 1, $0.path) < ($1.path == oldPath ? 0 : 1, $1.path) }
        let plan = KnowledgeRename(kind: kind, from: old, to: toID, files: changes)
        if !problems.isEmpty {
            throw Failure(message: "Refused to rename \(old) to \(toID), nothing was written: " + problems.joined(separator: "; ")
                + ".\nPlanned:\n" + plan.diff)
        }
        return plan
    }

    /// Writes a verified plan: commits the pending edits first (U2), writes every changed file,
    /// moves the renamed one, and commits all of it at once. Refused when a file changed since the
    /// plan. The committed paths.
    @discardableResult
    public func apply(_ plan: KnowledgeRename, env: HarnessEnvironment) async throws(Failure) -> [String] {
        try await apply(plan, env: env) { data, url in try data.write(to: url, options: .atomic) }
    }

    /// `apply` with the file writer given (tests make it fail after a move).
    func apply(_ plan: KnowledgeRename, env: HarnessEnvironment,
               write: (Data, URL) throws -> Void) async throws(Failure) -> [String] {
        _ = await KnowledgeCommitQueue(base: root, env: env).flush()
        for change in plan.files where (try? Data(contentsOf: root.appending(path: change.path))) != change.original {
            throw Failure(message: "\(change.path) changed after the rename was planned; nothing was written. Plan it again.")
        }
        // Every change whose file was moved or written, recorded right after its move, so a write
        // that fails after the move is undone too.
        var written: [KnowledgeRename.FileChange] = []
        do {
            for change in plan.files {
                let from = root.appending(path: change.path), to = root.appending(path: change.newPath)
                if change.path == change.newPath {
                    try write(change.planned, from)
                    written.append(change)
                } else {
                    try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if change.path.lowercased() == change.newPath.lowercased() {
                        // A change of case only: through a temporary name (the disk may ignore case).
                        let temporary = from.deletingLastPathComponent().appending(path: ".akit-rename-\(UUID().uuidString)")
                        try FileManager.default.moveItem(at: from, to: temporary)
                        do { try FileManager.default.moveItem(at: temporary, to: to) } catch {
                            try? FileManager.default.moveItem(at: temporary, to: from)
                            throw error
                        }
                    } else {
                        try FileManager.default.moveItem(at: from, to: to)
                    }
                    written.append(change)
                    try write(change.planned, to)
                }
            }
        } catch {
            for change in written.reversed() {
                let from = root.appending(path: change.path), to = root.appending(path: change.newPath)
                if change.path != change.newPath {
                    if change.path.lowercased() == change.newPath.lowercased() {
                        // Back through a temporary name too.
                        let temporary = to.deletingLastPathComponent().appending(path: ".akit-rename-\(UUID().uuidString)")
                        if (try? FileManager.default.moveItem(at: to, to: temporary)) != nil,
                           (try? FileManager.default.moveItem(at: temporary, to: from)) == nil {
                            try? FileManager.default.moveItem(at: temporary, to: to)
                        }
                    } else {
                        try? FileManager.default.moveItem(at: to, to: from)
                    }
                }
                try? change.original.write(to: from, options: .atomic)
            }
            throw Failure(message: "Couldn't write the rename (\(error.localizedDescription)); the files written are back as they were.")
        }
        var paths: [String] = []
        for change in plan.files {
            if !paths.contains(change.path) { paths.append(change.path) }
            if !paths.contains(change.newPath) { paths.append(change.newPath) }
        }
        let links = plan.linkCount
        let message = "Rename \(plan.kind.rawValue) \(plan.from) to \(plan.to)"
            + (links == 0 ? "" : ", \(links) link\(links == 1 ? "" : "s") in \(plan.files.filter { !$0.links.isEmpty }.count) file\(plan.files.filter { !$0.links.isEmpty }.count == 1 ? "" : "s")")
        do { try await KnowledgeGit(base: root, env: env).commit(paths: paths, message: message) } catch {
            throw Failure(message: "The rename is written, but not committed: \(error.message)")
        }
        return paths
    }

    /// The new id: `new` as a name in the old one's folder, or (a note) a whole id.
    func renamedID(_ old: String, to new: String, kind: KnowledgeRename.Kind) throws(Failure) -> String {
        var name = Self.nfc(new.trimmingCharacters(in: .whitespaces))
        if name.hasPrefix("areas/") { name.removeFirst("areas/".count) }
        for ext in [".md", ".excalidraw"] where name.hasSuffix(ext) { name.removeLast(ext.count) }
        let folder = old.split(separator: "/").dropLast().joined(separator: "/")
        let id: String
        if name.contains("/") {
            guard kind == .note else { throw Failure(message: "A map is renamed within its maps/ folder: give a name, like flows.") }
            id = name
        } else {
            id = folder + "/" + name
        }
        let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.allSatisfy(Self.validName) else {
            throw Failure(message: "“\(new)” can't be used: a name is one file name, without a dot at the start; an id is area/name.")
        }
        if kind == .note, parts.dropLast().contains(where: { $0.lowercased() == "maps" }) {
            throw Failure(message: "A note can't go into a maps/ folder: links there mean maps.")
        }
        _ = try areaFolder(parts[0])
        return id
    }

    /// Element id → what its link resolves to, for every element with a link (deleted ones too).
    static func linkTargets(of scene: ExcalidrawFile, from path: String, targets: KnowledgeLinks) -> [String: KnowledgeLinks.Resolution] {
        var result: [String: KnowledgeLinks.Resolution] = [:]
        for element in scene.elements {
            if let link = element.link, !link.isEmpty { result[element.id] = targets.resolve(link, from: path) }
        }
        return result
    }

    static func describe(_ resolution: KnowledgeLinks.Resolution) -> String {
        switch resolution {
        case .note(let id): return "the note \(id)"
        case .map(let id): return "the map \(id)"
        case .missing: return "nothing"
        case .ambiguous(let ids): return "several (\(ids.joined(separator: ", ")))"
        }
    }
}
