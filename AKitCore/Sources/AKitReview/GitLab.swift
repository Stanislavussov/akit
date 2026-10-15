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

/// GitLab's REST API v4, with the user's token (R2). Reads a merge request and its threads,
/// and creates, updates and deletes the user's own draft notes. It has no call that publishes
/// a draft, resolves a thread or touches any other note (R5, R12).
public struct GitLabClient: Sendable {
    public let host: String
    let token: String
    let fetch: ReviewFetch

    public init(host: String, token: String, fetch: @escaping ReviewFetch = ReviewHTTP.network) {
        var trimmed = host
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.host = trimmed
        self.token = token
        self.fetch = fetch
    }

    /// `/api/v4/version`: step 0's check.
    public func version() async throws -> String {
        let object = try await getObject("/version", what: "GitLab version")
        return object.string("version") ?? "unknown"
    }

    public func currentUser() async throws -> String {
        let object = try await getObject("/user", what: "GitLab user")
        guard let name = object.string("username") else { throw ReviewHTTP.Failure(message: "GitLab /user named no user.") }
        return name
    }

    public func mergeRequest(_ ref: MergeRequestRef) async throws -> GitLabMergeRequest {
        let object = try await getObject(mrPath(ref), what: "the merge request")
        let refs = object.object("diff_refs").flatMap { refs -> GitLabMergeRequest.DiffRefs? in
            guard let base = refs.string("base_sha"), let start = refs.string("start_sha"), let head = refs.string("head_sha") else { return nil }
            return GitLabMergeRequest.DiffRefs(baseSHA: base, startSHA: start, headSHA: head)
        }
        return GitLabMergeRequest(iid: object.int("iid") ?? ref.iid, title: object.string("title") ?? "",
                                  description: object.string("description") ?? "", state: object.string("state") ?? "",
                                  author: object.object("author")?.string("username") ?? "",
                                  sourceBranch: object.string("source_branch") ?? "", targetBranch: object.string("target_branch") ?? "",
                                  labels: object["labels"] as? [String] ?? [], webURL: object.string("web_url") ?? ref.url, diffRefs: refs)
    }

    public func versions(_ ref: MergeRequestRef) async throws -> [GitLabVersion] {
        try await getList(mrPath(ref) + "/versions", what: "the merge request's versions").compactMap {
            guard let id = $0.int("id"), let head = $0.string("head_commit_sha") else { return nil }
            return GitLabVersion(id: id, headSHA: head, baseSHA: $0.string("base_commit_sha") ?? "", startSHA: $0.string("start_commit_sha") ?? "")
        }
    }

    public func diffs(_ ref: MergeRequestRef) async throws -> [GitLabFileDiff] {
        try await getList(mrPath(ref) + "/diffs", what: "the merge request's diffs").map {
            GitLabFileDiff(oldPath: $0.string("old_path") ?? "", newPath: $0.string("new_path") ?? "", diff: $0.string("diff") ?? "",
                           newFile: $0.bool("new_file"), renamedFile: $0.bool("renamed_file"), deletedFile: $0.bool("deleted_file"),
                           tooLarge: $0.bool("too_large") || $0.bool("collapsed"))
        }
    }

    public func discussions(_ ref: MergeRequestRef) async throws -> [GitLabDiscussion] {
        try await getList(mrPath(ref) + "/discussions", what: "the merge request's threads").compactMap { object in
            guard let id = object.string("id") else { return nil }
            return GitLabDiscussion(id: id, notes: object.objects("notes").compactMap(Self.note))
        }
    }

    public func drafts(_ ref: MergeRequestRef) async throws -> [GitLabDraft] {
        try await getList(mrPath(ref) + "/draft_notes", what: "your draft notes").compactMap(Self.draft)
    }

    @discardableResult
    public func createDraft(_ ref: MergeRequestRef, note: String, position: GitLabPosition?) async throws -> GitLabDraft {
        var body: JSONObject = ["note": note]
        if let position { body["position"] = position.json }
        let data = try await send("POST", mrPath(ref) + "/draft_notes", body: body)
        guard let object = try ReviewHTTP.json(data, what: "the new draft") as? JSONObject, let draft = Self.draft(object) else {
            throw ReviewHTTP.Failure(message: "GitLab didn't return the new draft.")
        }
        return draft
    }

    public func updateDraft(_ ref: MergeRequestRef, id: Int, note: String, position: GitLabPosition?) async throws {
        var body: JSONObject = ["note": note]
        if let position { body["position"] = position.json }
        _ = try await send("PUT", mrPath(ref) + "/draft_notes/\(id)", body: body)
    }

    public func deleteDraft(_ ref: MergeRequestRef, id: Int) async throws {
        _ = try await send("DELETE", mrPath(ref) + "/draft_notes/\(id)", body: nil)
    }

    /// A reply in one of AKit's own published threads ("looks fixed in <sha>"), as a draft.
    @discardableResult
    public func createDraftReply(_ ref: MergeRequestRef, discussionID: String, note: String) async throws -> GitLabDraft {
        let data = try await send("POST", mrPath(ref) + "/draft_notes", body: ["note": note, "in_reply_to_discussion_id": discussionID])
        guard let object = try ReviewHTTP.json(data, what: "the new draft") as? JSONObject, let draft = Self.draft(object) else {
            throw ReviewHTTP.Failure(message: "GitLab didn't return the new draft.")
        }
        return draft
    }

    // MARK: - Requests

    func mrPath(_ ref: MergeRequestRef) -> String {
        let project = ref.projectPath.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ref.projectPath
        return "/projects/\(project)/merge_requests/\(ref.iid)"
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(string: host) else { throw ReviewHTTP.Failure(message: "\(host) is not a web address.") }
        // The project path is percent-encoded already: set the encoded path, so `%2F` stays.
        components.percentEncodedPath = (components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast())
                                         : components.percentEncodedPath) + "/api/v4" + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ReviewHTTP.Failure(message: "Can't make an address from \(host) and \(path).") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func getObject(_ path: String, what: String) async throws -> JSONObject {
        let (data, _) = try await ReviewHTTP.send(request("GET", path), fetch: fetch)
        guard let object = try ReviewHTTP.json(data, what: what) as? JSONObject else {
            throw ReviewHTTP.Failure(message: "\(what): GitLab's answer is not an object.")
        }
        return object
    }

    /// Every page (`per_page=100`, the `X-Next-Page` header), at most 50 pages.
    func getList(_ path: String, what: String) async throws -> [JSONObject] {
        var result: [JSONObject] = []
        var page = 1
        for _ in 0..<50 {
            let (data, response) = try await ReviewHTTP.send(request("GET", path, query: [URLQueryItem(name: "per_page", value: "100"),
                                                                                          URLQueryItem(name: "page", value: String(page))]),
                                                             fetch: fetch)
            guard let list = try ReviewHTTP.json(data, what: what) as? [JSONObject] else {
                throw ReviewHTTP.Failure(message: "\(what): GitLab's answer is not a list.")
            }
            result += list
            guard let next = (response.value(forHTTPHeaderField: "X-Next-Page")).flatMap(Int.init), next > page else { break }
            page = next
        }
        return result
    }

    func send(_ method: String, _ path: String, body: JSONObject?) async throws -> Data {
        var request = try request(method, path)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await ReviewHTTP.send(request, fetch: fetch).0
    }

    static func note(_ object: JSONObject) -> GitLabNote? {
        guard let id = object.int("id") else { return nil }
        return GitLabNote(id: id, body: object.string("body") ?? "", author: object.object("author")?.string("username") ?? "",
                          system: object.bool("system"), resolvable: object.bool("resolvable"), resolved: object.bool("resolved"),
                          resolvedBy: object.object("resolved_by")?.string("username"), position: GitLabPosition.from(object.object("position")),
                          created: object.string("created_at") ?? "")
    }

    static func draft(_ object: JSONObject) -> GitLabDraft? {
        guard let id = object.int("id") else { return nil }
        return GitLabDraft(id: id, note: object.string("note") ?? "", position: GitLabPosition.from(object.object("position")),
                           discussionID: object.string("discussion_id"))
    }
}
