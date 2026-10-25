import AKitFoundation
import Foundation

/// A note for a folder on this Mac (K27): another repository (a backend beside the frontend) or
/// a folder without git (a local wiki), so the base is the one way in and an agent finds the
/// folder through `akit kb context` / `show` (`local`). Add Folder… in the app and
/// `akit kb add-folder` make it; the person checks the text first.
///
/// ```markdown
/// ---
/// kind: service                     # folder without git
/// repo: git@github.com:shop/api.git # the origin remote, when there is one
/// path: ~/Projects/shop-api
/// ---
/// # shop-api
///
/// Orders and payments API.          # the description: given, else README's first line, else none
/// ```
public struct KnowledgeFolderNote: Sendable, Equatable, Encodable {
    public typealias Failure = KnowledgeBase.Failure

    public let area: String
    public let name: String
    /// `service` for a git repository, else `folder`.
    public let kind: String
    /// The origin remote, without a user or password in it.
    public let repo: String?
    /// The folder as `~/…` (absolute outside the home folder).
    public let path: String
    public let description: String?
    /// The note's whole text.
    public let text: String

    public var note: String { "\(area)/\(name)" }

    /// The note for `folder` in `area`. `name` defaults to the folder's name; `description` nil
    /// takes README's first line, "" none.
    public static func plan(folder: URL, area: String, name: String? = nil, description: String? = nil,
                            home: URL) throws(Failure) -> KnowledgeFolderNote {
        let folder = folder.standardized
        guard FileWalk.isDirectory(folder) else { throw Failure(message: "\(FileWalk.tilde(folder, home: home)) is not a folder.") }
        let area = KnowledgeBase.nfc(area.trimmingCharacters(in: .whitespaces))
        let name = KnowledgeBase.nfc((name ?? folder.lastPathComponent).trimmingCharacters(in: .whitespaces))
        guard KnowledgeBase.validName(area) else {
            throw Failure(message: "“\(area)” can't be an area: one folder name, without /, and doesn't start with a dot.")
        }
        guard KnowledgeBase.validName(name) else {
            throw Failure(message: "“\(name)” can't be a note name: one file name, without /, and doesn't start with a dot. Give another name.")
        }
        let repo = GitCheckout.at(folder).flatMap(\.originURL).map(withoutCredentials)
        let kind = GitCheckout.at(folder) != nil ? "service" : "folder"
        // /tmp and /private/tmp (or /var and /private/var) are one folder: either spelling gets its ~.
        var path = FileWalk.tilde(folder, home: home)
        if !path.hasPrefix("~") { path = FileWalk.tilde(folder.standardizedFileURL, home: home.standardizedFileURL) }
        var line = description.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? readmeLine(in: folder)
        // A README line with a token in it stays out of the base.
        if let text = line, text.isEmpty || KnowledgeInbox.hasSecret(text) { line = nil }
        var front = ["kind: \(kind)"]
        if let repo { front.append("repo: \(yaml(repo))") }
        front.append("path: \(yaml(path))")
        let text = "---\n" + front.joined(separator: "\n") + "\n---\n# \(name)\n" + (line.map { "\n\($0)\n" } ?? "")
        return KnowledgeFolderNote(area: area, name: name, kind: kind, repo: repo, path: path, description: line, text: text)
    }

    /// The first line of prose in the folder's README: no heading, badge, HTML or rule; one
    /// sentence, at most 200 characters. Nil without one.
    static func readmeLine(in folder: URL) -> String? {
        let names = ["README.md", "README", "readme.md", "Readme.md", "README.markdown", "README.txt", "index.md"]
        guard let file = names.map({ folder.appending(path: $0) }).first(where: FileWalk.isRegularFile),
              let data = FileManager.default.contents(atPath: file.path), data.count < 1_000_000 else { return nil }
        var inFence = false
        for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[!") || line.hasPrefix("![") || line.hasPrefix("<")
                || line.hasPrefix("---") || line.hasPrefix("===") || line.hasPrefix("|") || line.hasPrefix(">") { continue }
            var sentence = line
            if let end = line.range(of: ". ") { sentence = String(line[..<end.lowerBound]) + "." }
            return sentence.count <= 200 ? sentence : String(sentence.prefix(199)) + "…"
        }
        return nil
    }

    /// `https://user:token@host/x.git` → `https://host/x.git`; other remotes as they are.
    static func withoutCredentials(_ remote: String) -> String {
        guard let scheme = remote.range(of: "://"), let at = remote[scheme.upperBound...].firstIndex(of: "@"),
              !remote[scheme.upperBound..<at].contains("/") else { return remote }
        return String(remote[..<scheme.upperBound]) + remote[remote.index(after: at)...]
    }

    /// A value as one YAML scalar: plain when that reads back the same, else double-quoted.
    static func yaml(_ value: String) -> String {
        let plain = !value.contains(": ") && !value.contains(" #") && !value.hasSuffix(":")
            && !value.hasPrefix("\"") && !value.hasPrefix("'") && !"[]{}&*!|>%@`,?-".contains(value.first ?? " ")
        if plain { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension KnowledgeBase {
    /// The note `add-folder` would write, refused when the folder is the base or inside it, or
    /// the note exists already.
    public func plan(folder: URL, area: String, name: String? = nil, description: String? = nil,
                     home: URL) throws(Failure) -> KnowledgeFolderNote {
        let plan = try KnowledgeFolderNote.plan(folder: folder, area: area, name: name, description: description, home: home)
        let own = root.resolvingSymlinksInPath().path, given = folder.standardized.resolvingSymlinksInPath().path
        if given == own || given.hasPrefix(own + "/") {
            throw Failure(message: "\(FileWalk.tilde(folder, home: home)) is the knowledge base itself or inside it.")
        }
        if FileManager.default.fileExists(atPath: noteFile(plan.note).path) {
            throw Failure(message: "The note \(plan.note) exists already. Give another name (--name), or set its path with akit kb set \(plan.note) path=\(plan.path).")
        }
        return plan
    }

    /// Writes the planned note (the area too, when new) and commits it at once. When `kb.yaml`
    /// doesn't list the note's kind, the kind is added to it with the default fields, in the same
    /// commit (`kindAdded`); a `kb.yaml` with keys AKit doesn't know is left as it is.
    @discardableResult
    public func addFolder(_ plan: KnowledgeFolderNote, env: HarnessEnvironment) async throws(Failure) -> (path: String, kindAdded: Bool) {
        let path = notePath(plan.note)
        let file = noteFile(plan.note)
        if FileManager.default.fileExists(atPath: file.path) { throw Failure(message: "The note \(plan.note) exists already.") }
        var paths = [path]
        var kindAdded = false
        if FileManager.default.fileExists(atPath: root.appending(path: KnowledgeKinds.fileName).path),
           let kinds = try? kinds(), kinds.kind(plan.kind) == nil, kinds.unknownKeys.isEmpty,
           let fields = KnowledgeKinds.defaults.kind(plan.kind)?.fields {
            try kinds.adding(plan.kind, fields: fields).write(base: root)
            paths.append(KnowledgeKinds.fileName)
            kindAdded = true
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(plan.text.utf8).write(to: file, options: .withoutOverwriting)
        } catch {
            throw Failure(message: "Couldn't write \(path): \(error.localizedDescription)")
        }
        do {
            try await KnowledgeGit(base: root, env: env).commit(paths: paths, message: "Add note \(plan.note) for \(plan.path)")
        } catch {
            throw Failure(message: "\(path) was written, but not committed: \(error.message)")
        }
        return (path, kindAdded)
    }
}
