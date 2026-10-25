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
    /// GitLab's number of the project: some MCP tools take it instead of the path.
    public var projectID: Int?
    /// Draft (or "work in progress"); nil when the answer didn't say.
    public var draft: Bool? = nil
    /// The head pipeline's status (`success`, `failed`, `running`, …) and commit; nil when unknown.
    public var pipelineStatus: String? = nil
    public var pipelineSHA: String? = nil
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
        // GraphQL's position (GitLab's own MCP server) keeps the commits in `diff_refs`.
        let refs = object?.object("diff_refs")
        guard let object, (object.string("position_type") ?? "text").lowercased() == "text",
              let head = object.string("head_sha") ?? refs?.string("head_sha"),
              let path = object.string("new_path") ?? object.string("old_path") else { return nil }
        return GitLabPosition(baseSHA: object.string("base_sha") ?? refs?.string("base_sha") ?? "",
                              startSHA: object.string("start_sha") ?? refs?.string("start_sha") ?? "", headSHA: head,
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
        } ?? object.string("diff_head_sha").map { head in
            // GraphQL's flat fields (GitLab's own MCP server).
            GitLabMergeRequest.DiffRefs(baseSHA: object.string("diff_base_sha") ?? "", startSHA: object.string("diff_start_sha") ?? "", headSHA: head)
        }
        var mr = GitLabMergeRequest(iid: iid, title: object.string("title") ?? "", description: object.string("description") ?? "",
                                    state: object.string("state") ?? "", author: object.object("author")?.string("username") ?? "",
                                    sourceBranch: object.string("source_branch") ?? "", targetBranch: object.string("target_branch") ?? "",
                                    labels: object["labels"] as? [String] ?? object.objects("labels").compactMap { $0.string("title") }, webURL: object.string("web_url") ?? "", diffRefs: refs,
                                    projectID: object.int("project_id"))
        if object["draft"] != nil || object["work_in_progress"] != nil {
            mr.draft = object.bool("draft") || object.bool("work_in_progress")
        }
        if let pipeline = object.object("head_pipeline") ?? object.object("pipeline") {
            mr.pipelineStatus = pipeline.string("status")
            mr.pipelineSHA = pipeline.string("sha")
        }
        return mr
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
        var parsed = notes.compactMap(note)
        // GraphQL marks the thread resolvable and resolved, not its notes.
        if object["resolvable"] != nil, !notes.contains(where: { $0["resolvable"] != nil }) {
            for index in parsed.indices {
                parsed[index].resolvable = object.bool("resolvable")
                parsed[index].resolved = object.bool("resolved")
            }
        }
        return GitLabDiscussion(id: id, notes: parsed)
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

extension GitLabJSON {
    /// An answer of GitLab's own MCP server (`/api/v4/mcp`) in REST's shape: GraphQL's lists
    /// (`{nodes: [...], pageInfo}`) become arrays, camelCase keys snake_case (`sourceBranch` →
    /// `source_branch`), global ids (`gid://gitlab/Note/12`) GitLab's own (`12`). Only answers
    /// that carry such an id change: other servers' keys (Azure DevOps's `System.Title`) stay.
    static func restShape(_ value: Any) -> Any {
        hasGlobalID(value, depth: 0) ? graphQLToREST(value, depth: 0) : value
    }

    static func hasGlobalID(_ value: Any, depth: Int) -> Bool {
        guard depth < 8 else { return false }
        if let object = value as? JSONObject {
            if (object["id"] as? String)?.hasPrefix("gid://gitlab/") == true { return true }
            return object.values.contains { hasGlobalID($0, depth: depth + 1) }
        }
        if let list = value as? [Any] { return list.prefix(20).contains { hasGlobalID($0, depth: depth + 1) } }
        return false
    }

    static func graphQLToREST(_ value: Any, depth: Int) -> Any {
        guard depth < 12 else { return value }
        if let list = value as? [Any] { return list.map { graphQLToREST($0, depth: depth + 1) } }
        guard let object = value as? JSONObject else { return value }
        if let nodes = object["nodes"] as? [Any], Set(object.keys).isSubset(of: ["nodes", "pageInfo", "count", "edges"]) {
            return nodes.map { graphQLToREST($0, depth: depth + 1) }
        }
        var result: JSONObject = [:]
        for (key, child) in object {
            let name = snakeCase(key)
            if name == "id", let text = child as? String, text.hasPrefix("gid://gitlab/") {
                let tail = String(text.split(separator: "/").last ?? "")
                result[name] = Int(tail).map { $0 as Any } ?? tail
            } else if result[name] == nil || key == name {
                result[name] = graphQLToREST(child, depth: depth + 1)
            }
        }
        return result
    }

    /// `sourceBranch` → `source_branch`, `aMode` → `a_mode`; snake_case stays.
    static func snakeCase(_ key: String) -> String {
        var result = ""
        for character in key {
            if character.isUppercase, !result.isEmpty { result += "_" }
            result += character.lowercased()
        }
        return result
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
