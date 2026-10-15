import Foundation

/// A merge request as Gather read it (`<run>/gitlab/mr.json`).
public struct GitLabMergeRequest: Codable, Sendable, Hashable {
    public struct DiffRefs: Codable, Sendable, Hashable {
        public var baseSHA: String
        public var startSHA: String
        public var headSHA: String

        public init(baseSHA: String, startSHA: String, headSHA: String) {
            self.baseSHA = baseSHA
            self.startSHA = startSHA
            self.headSHA = headSHA
        }
    }

    public var iid: Int
    public var title: String
    public var description: String
    public var state: String
    public var author: String
    public var sourceBranch: String
    public var targetBranch: String
    public var labels: [String]
    public var webURL: String
    public var diffRefs: DiffRefs?
}

/// One version of a merge request's diff (`GET …/versions`).
public struct GitLabVersion: Codable, Sendable, Hashable {
    public var id: Int
    public var headSHA: String
    public var baseSHA: String
    public var startSHA: String
}

/// One changed file (`GET …/diffs`).
public struct GitLabFileDiff: Codable, Sendable, Hashable {
    public var oldPath: String
    public var newPath: String
    public var diff: String
    public var newFile: Bool
    public var renamedFile: Bool
    public var deletedFile: Bool
    /// Over GitLab's diff limits: GitLab sends no diff and can't keep a comment on it.
    public var tooLarge: Bool

    public init(oldPath: String, newPath: String, diff: String, newFile: Bool = false, renamedFile: Bool = false,
                deletedFile: Bool = false, tooLarge: Bool = false) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.diff = diff
        self.newFile = newFile
        self.renamedFile = renamedFile
        self.deletedFile = deletedFile
        self.tooLarge = tooLarge
    }
}

/// Where a note sits in the diff (GitLab's `position`).
public struct GitLabPosition: Codable, Sendable, Hashable {
    public var baseSHA: String
    public var startSHA: String
    public var headSHA: String
    public var oldPath: String
    public var newPath: String
    public var oldLine: Int?
    public var newLine: Int?

    public init(baseSHA: String, startSHA: String, headSHA: String, oldPath: String, newPath: String, oldLine: Int?, newLine: Int?) {
        self.baseSHA = baseSHA
        self.startSHA = startSHA
        self.headSHA = headSHA
        self.oldPath = oldPath
        self.newPath = newPath
        self.oldLine = oldLine
        self.newLine = newLine
    }

    /// The body GitLab takes for a draft note's position.
    var json: JSONObject {
        var value: JSONObject = ["position_type": "text", "base_sha": baseSHA, "start_sha": startSHA, "head_sha": headSHA,
                                 "old_path": oldPath, "new_path": newPath]
        if let oldLine { value["old_line"] = oldLine }
        if let newLine { value["new_line"] = newLine }
        return value
    }

    static func from(_ object: JSONObject?) -> GitLabPosition? {
        guard let object, object.string("position_type") ?? "text" == "text",
              let head = object.string("head_sha"), let path = object.string("new_path") ?? object.string("old_path") else { return nil }
        return GitLabPosition(baseSHA: object.string("base_sha") ?? "", startSHA: object.string("start_sha") ?? "", headSHA: head,
                              oldPath: object.string("old_path") ?? path, newPath: path, oldLine: object.int("old_line"),
                              newLine: object.int("new_line"))
    }
}

public struct GitLabNote: Codable, Sendable, Hashable {
    public var id: Int
    public var body: String
    public var author: String
    public var system: Bool
    public var resolvable: Bool
    public var resolved: Bool
    public var resolvedBy: String?
    public var position: GitLabPosition?
    public var created: String

    public init(id: Int, body: String, author: String, system: Bool = false, resolvable: Bool = false, resolved: Bool = false,
                resolvedBy: String? = nil, position: GitLabPosition? = nil, created: String = "") {
        self.id = id
        self.body = body
        self.author = author
        self.system = system
        self.resolvable = resolvable
        self.resolved = resolved
        self.resolvedBy = resolvedBy
        self.position = position
        self.created = created
    }
}

public struct GitLabDiscussion: Codable, Sendable, Hashable {
    public var id: String
    public var notes: [GitLabNote]

    public init(id: String, notes: [GitLabNote]) {
        self.id = id
        self.notes = notes
    }

    /// Resolved threads: every resolvable note is resolved.
    public var isResolved: Bool {
        let resolvable = notes.filter(\.resolvable)
        return !resolvable.isEmpty && resolvable.allSatisfy(\.resolved)
    }
}

/// One of the user's pending draft notes (`GET …/draft_notes`): only the token's owner sees them.
public struct GitLabDraft: Codable, Sendable, Hashable {
    public var id: Int
    public var note: String
    public var position: GitLabPosition?
    public var discussionID: String?

    public init(id: Int, note: String, position: GitLabPosition? = nil, discussionID: String? = nil) {
        self.id = id
        self.note = note
        self.position = position
        self.discussionID = discussionID
    }
}

/// Reads GitLab's JSON, as GitLab's REST API and the GitLab MCP servers that pass it on
/// return it (`docs/design/review.md`, "Gather through MCP").
public enum GitLabJSON {
    public static func mergeRequest(_ object: JSONObject) -> GitLabMergeRequest? {
        guard let iid = object.int("iid"), object["diff_refs"] != nil || object["source_branch"] != nil else { return nil }
        let refs = object.object("diff_refs").flatMap { refs -> GitLabMergeRequest.DiffRefs? in
            guard let base = refs.string("base_sha"), let start = refs.string("start_sha"), let head = refs.string("head_sha") else { return nil }
            return GitLabMergeRequest.DiffRefs(baseSHA: base, startSHA: start, headSHA: head)
        }
        return GitLabMergeRequest(iid: iid, title: object.string("title") ?? "", description: object.string("description") ?? "",
                                  state: object.string("state") ?? "", author: object.object("author")?.string("username") ?? "",
                                  sourceBranch: object.string("source_branch") ?? "", targetBranch: object.string("target_branch") ?? "",
                                  labels: object["labels"] as? [String] ?? [], webURL: object.string("web_url") ?? "", diffRefs: refs)
    }

    public static func version(_ object: JSONObject) -> GitLabVersion? {
        guard let id = object.int("id"), let head = object.string("head_commit_sha") else { return nil }
        return GitLabVersion(id: id, headSHA: head, baseSHA: object.string("base_commit_sha") ?? "", startSHA: object.string("start_commit_sha") ?? "")
    }

    public static func fileDiff(_ object: JSONObject) -> GitLabFileDiff? {
        guard let path = object.string("new_path") ?? object.string("old_path"), object["diff"] != nil || object.bool("too_large") else { return nil }
        return GitLabFileDiff(oldPath: object.string("old_path") ?? path, newPath: path, diff: object.string("diff") ?? "",
                              newFile: object.bool("new_file"), renamedFile: object.bool("renamed_file"), deletedFile: object.bool("deleted_file"),
                              tooLarge: object.bool("too_large") || object.bool("collapsed"))
    }

    public static func discussion(_ object: JSONObject) -> GitLabDiscussion? {
        guard let id = object.string("id"), let notes = object["notes"] as? [JSONObject] else { return nil }
        return GitLabDiscussion(id: id, notes: notes.compactMap(note))
    }

    static func note(_ object: JSONObject) -> GitLabNote? {
        guard let id = object.int("id") else { return nil }
        return GitLabNote(id: id, body: object.string("body") ?? "", author: object.object("author")?.string("username") ?? "",
                          system: object.bool("system"), resolvable: object.bool("resolvable"), resolved: object.bool("resolved"),
                          resolvedBy: object.object("resolved_by")?.string("username"), position: GitLabPosition.from(object.object("position")),
                          created: object.string("created_at") ?? "")
    }

    static func draft(_ object: JSONObject) -> GitLabDraft? {
        guard let id = object.int("id"), let note = object.string("note") else { return nil }
        return GitLabDraft(id: id, note: note, position: GitLabPosition.from(object.object("position")),
                           discussionID: object.string("discussion_id"))
    }
}

/// Reads fields of `JSONSerialization` objects.
public typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue ?? (self[key] as? String).flatMap { Int($0) } }
    func bool(_ key: String) -> Bool { (self[key] as? Bool) ?? ((self[key] as? NSNumber)?.boolValue ?? false) }
    func object(_ key: String) -> JSONObject? { self[key] as? JSONObject }
    func objects(_ key: String) -> [JSONObject] { self[key] as? [JSONObject] ?? [] }
}
