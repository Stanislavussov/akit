import AKitFoundation
import AKitLab
import Foundation

/// Which of Pi's MCP servers and tools a review may use (`docs/design/review.md`, R2–R3). Pi
/// connects to GitLab, Azure DevOps and the other trackers itself, with the servers the user
/// configured in Pi; AKit only says which of them a run may use and checks every call.
public struct ReviewMCPAccess: Codable, Sendable, Hashable {
    /// Pi MCP server names (`~/.pi/agent/mcp.json`); empty = the servers whose names say GitLab
    /// or Azure DevOps (`gitlab…`, `…azure…`, `…devops…`, `ado`), never a browser, a file system or
    /// a web fetcher by default.
    public var servers: [String]
    /// Tool name patterns (`*` = any characters) that only read, on top of the tools a server
    /// marks `readOnlyHint` and the tools named by a reading verb (`get_…`, `wit_get_…`).
    public var read: [String]
    /// Tool name patterns the send pass may call to write draft notes.
    public var write: [String]
    /// Whether the brief, the role and the verifier passes may read through MCP too (the
    /// fetch pass always does).
    public var inPasses: Bool

    public static let defaultWrite = ["*draft_note*", "*draft*note*"]
    /// Server names a run uses when the profile names none.
    public static let defaultServerWords = ["gitlab", "azure", "devops"]

    public init(servers: [String] = [], read: [String] = [], write: [String] = ReviewMCPAccess.defaultWrite, inPasses: Bool = true) {
        self.servers = servers
        self.read = read
        self.write = write
        self.inPasses = inPasses
    }

    static func parse(_ map: [String: Any]?, where place: String) throws -> ReviewMCPAccess {
        guard let map else { return ReviewMCPAccess() }
        let servers = ReviewYAML.strings(map["servers"])
        for server in servers where server.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil {
            throw ReviewRole.Failure(message: "\(place): mcp server \(server) is not a Pi server name (letters, digits, _ and -).")
        }
        let write = map["write"] == nil ? defaultWrite : ReviewYAML.strings(map["write"])
        return ReviewMCPAccess(servers: servers, read: ReviewYAML.strings(map["read"]), write: write,
                               inPasses: map["in_passes"] as? Bool ?? true)
    }

    /// Whether a run may use this Pi server at all.
    public func allows(server: String) -> Bool {
        let name = ReviewMCPPolicy.normalized(server).lowercased()
        if !servers.isEmpty { return servers.map { ReviewMCPPolicy.normalized($0).lowercased() }.contains(name) }
        return Self.defaultServerWords.contains { name.contains($0) } || name == "ado"
    }

    /// `mcp__<server>__*` for `--tools`: Pi then keeps only these servers' tools.
    public var toolPatterns: [String] {
        servers.isEmpty ? Self.defaultServerWords.map { "mcp__*\($0)*__*" } + ["mcp__ado__*"]
            : servers.map { "mcp__\(ReviewMCPPolicy.normalized($0))__*" }
    }
}

/// The rules the extension applies to every MCP call (`akit-review.ts`), written once more in
/// Swift for `akit review check` and the tests. An allowlist: a tool reads only when its verb
/// reads; anything else is blocked unless the send pass may write with it.
public enum ReviewMCPPolicy {
    public enum Kind: String, Sendable {
        case read, write, blocked
    }

    /// Never, in any pass (R5): anywhere in a tool's name.
    public static let forbiddenWords = ["publish", "submit", "approve", "unapprove", "vote", "resolve", "unresolve", "rebase"]
    /// The verbs of reading tools: the first word (`get_merge_request`), or the second after a
    /// namespace (`wit_get_work_item`, `repo_list_pull_requests`).
    public static let readVerbs = ["get", "list", "search", "read", "show", "view", "fetch", "find", "query", "describe", "download"]
    /// The verbs a draft note tool may have in the send pass.
    public static let writeVerbs = ["create", "add", "post", "new", "update", "edit", "modify", "put", "patch", "delete", "remove", "destroy"]
    /// Reading tools of common GitLab servers whose names carry no verb.
    public static let knownReads = ["mr_discussions"]

    /// Pi names a server's tool `mcp__<server>__<tool>`, every character but letters, digits
    /// and `_` turned into `_`.
    public static func normalized(_ name: String) -> String {
        String(name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" ? Character($0) : "_" })
    }

    public static func matches(_ pattern: String, _ name: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern.lowercased()).replacingOccurrences(of: "\\*", with: ".*")
        return name.lowercased().range(of: "^\(escaped)$", options: .regularExpression) != nil
    }

    /// The first two words of a tool's name: where its verb is.
    static func lead(_ tool: String) -> [String] {
        Array(tool.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).prefix(2))
    }

    /// What a tool of a server is to a run: read, write (only in the send pass) or blocked.
    public static func kind(server: String, tool: String, readOnlyHint: Bool = false, access: ReviewMCPAccess) -> Kind {
        guard access.allows(server: server) else { return .blocked }
        let words = tool.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        if words.contains(where: forbiddenWords.contains) { return .blocked }
        let lead = lead(tool)
        let writes = lead.contains(where: writeVerbs.contains)
        // A write pattern catches only tools whose verb writes: `*draft_note*` takes
        // `create_draft_note`, not `list_draft_notes`.
        if writes { return access.write.contains(where: { matches($0, tool) }) ? .write : .blocked }
        if let first = lead.first, readVerbs.contains(first) { return .read }
        if lead.count == 2, readVerbs.contains(lead[1]) { return .read }
        if readOnlyHint || (access.read + knownReads).contains(where: { matches($0, tool) }) { return .read }
        return .blocked
    }
}

/// One MCP call a pass made, as the extension saved it (`<run>/mcp/calls/<pass>-<n>.json`):
/// the server's answer word for word, not what the model made of it.
public struct ReviewMCPCall: Codable, Sendable, Hashable {
    public var pass: String
    public var tool: String
    public var input: String
    public var text: [String]
    public var structured: String?
    public var isError: Bool

    /// The JSON values in the answer: the structured content, and each text block that is JSON
    /// (or holds JSON after a line of text).
    var values: [Any] {
        var result: [Any] = []
        if let structured, let value = Self.json(structured), !((value as? JSONObject)?["content"] is [Any]) { result.append(value) }
        for block in text {
            if let value = Self.json(block) { result.append(value) }
            else if let start = block.firstIndex(where: { $0 == "{" || $0 == "[" }), let value = Self.json(String(block[start...])) {
                result.append(value)
            }
        }
        return result
    }

    var inputObject: JSONObject { Self.json(input) as? JSONObject ?? [:] }

    static func json(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }
}

/// What the fetch pass read about a merge request, sorted out of the saved MCP answers by their
/// shape (GitLab's and Azure DevOps's JSON). AKit trusts the servers' answers, never the model's
/// account of them.
public struct ReviewMCPData: Sendable {
    public var mergeRequest: GitLabMergeRequest?
    public var versions: [GitLabVersion] = []
    public var diffs: [GitLabFileDiff] = []
    public var discussions: [GitLabDiscussion] = []
    public var drafts: [GitLabDraft] = []
    public var user: String?
    public var workItems: [WorkItem] = []
    /// Calls that failed: `tool: message`.
    public var failures: [String] = []
    public var calls = 0

    public static func calls(in folder: URL, pass: String? = nil) -> [ReviewMCPCall] {
        FileWalk.children(of: folder.appending(path: "mcp/calls")).filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { ReviewJSON.read(ReviewMCPCall.self, from: $0) }
            .filter { pass == nil || $0.pass == pass }
    }

    /// Sorts the calls of the fetch pass. Threads and drafts count only from calls whose input
    /// names the merge request's number (they carry no project of their own).
    public static func read(_ calls: [ReviewMCPCall], iid: Int) -> ReviewMCPData {
        var data = ReviewMCPData()
        var comments: [Int: [WorkItem.Comment]] = [:]
        for call in calls {
            data.calls += 1
            if call.isError {
                data.failures.append("\(call.tool): " + SecretFilter.masked(String(call.text.joined(separator: " ").prefix(200))))
                continue
            }
            // What the model submits itself is its account: context for the passes, never the
            // threads, drafts or user that decide what AKit may change in GitLab.
            let trusted = call.tool != "akit_submit_context"
            let aboutThis = trusted && mentions(call.inputObject, iid)
            for value in call.values { visit(value, depth: 0, aboutThis: aboutThis, trusted: trusted) }
        }
        func visit(_ value: Any, depth: Int, aboutThis: Bool, trusted: Bool) {
            guard depth < 5 else { return }
            if let list = value as? [Any] {
                for item in list { visit(item, depth: depth + 1, aboutThis: aboutThis, trusted: trusted) }
                return
            }
            guard let object = value as? JSONObject else { return }
            if let mr = GitLabJSON.mergeRequest(object) {
                guard mr.iid == iid else { return }
                if data.mergeRequest == nil || (data.mergeRequest?.diffRefs == nil && mr.diffRefs != nil) { data.mergeRequest = mr }
                // `GET …/changes` and some servers carry the diffs in the merge request.
                for change in object.objects("changes") { add(GitLabJSON.fileDiff(change)) }
                return
            }
            if let version = GitLabJSON.version(object) {
                if !data.versions.contains(where: { $0.id == version.id }) { data.versions.append(version) }
                return
            }
            if let diff = GitLabJSON.fileDiff(object) {
                add(diff)
                return
            }
            if let discussion = GitLabJSON.discussion(object) {
                if aboutThis, !data.discussions.contains(where: { $0.id == discussion.id }) { data.discussions.append(discussion) }
                return
            }
            if let draft = GitLabJSON.draft(object), object["merge_request_id"] != nil || object["author_id"] != nil || object["position"] != nil
                || object["discussion_id"] != nil {
                if aboutThis, !data.drafts.contains(where: { $0.id == draft.id }) { data.drafts.append(draft) }
                return
            }
            if let item = AzureDevOpsJSON.workItem(object) {
                if !data.workItems.contains(where: { $0.id == item.id }) { data.workItems.append(item) }
                return
            }
            if let comment = AzureDevOpsJSON.comment(object) {
                comments[comment.item, default: []].append(comment.comment)
                return
            }
            // The signed-in user: a whole answer that is one user.
            if trusted, depth == 0, let name = object.string("username"), object["iid"] == nil, object["notes"] == nil, data.user == nil {
                data.user = name
                return
            }
            for (key, child) in object where key != "author" && key != "assignee" && key != "assignees" && key != "reviewers" {
                if child is [Any] || child is JSONObject { visit(child, depth: depth + 1, aboutThis: aboutThis, trusted: trusted) }
            }
        }
        func add(_ diff: GitLabFileDiff?) {
            guard let diff, !data.diffs.contains(where: { $0.newPath == diff.newPath && $0.oldPath == diff.oldPath }) else { return }
            data.diffs.append(diff)
        }
        for index in data.workItems.indices { data.workItems[index].comments = comments[data.workItems[index].id] ?? [] }
        return data
    }

    /// Whether an input names the merge request's number (`merge_request_iid: "7"`, `iid: 7`, …).
    static func mentions(_ input: JSONObject, _ iid: Int) -> Bool {
        input.contains { key, value in
            let lower = key.lowercased()
            guard lower.contains("iid") || lower.contains("merge_request") || lower == "id" || lower == "mr" else { return false }
            return (value as? NSNumber)?.intValue == iid || (value as? String) == String(iid)
        }
    }
}

/// `akit review check` and Review Settings…: the servers Pi connects to (`pi mcp list --json`)
/// and what review may do with each tool. Only names and states: never a server's command line,
/// environment or headers, which can hold tokens.
public enum ReviewMCPCheck {
    public struct Server: Sendable, Hashable, Identifiable {
        public var name: String
        public var enabled: Bool
        /// `connected`, `failed`, `needs-auth`, … as Pi says.
        public var state: String
        public var tools: [(name: String, kind: ReviewMCPPolicy.Kind)]
        public var id: String { name }

        public static func == (a: Server, b: Server) -> Bool {
            a.name == b.name && a.enabled == b.enabled && a.state == b.state && a.tools.map(\.name) == b.tools.map(\.name)
        }

        public func hash(into hasher: inout Hasher) { hasher.combine(name) }

        public func count(_ kind: ReviewMCPPolicy.Kind) -> Int { tools.filter { $0.kind == kind }.count }
    }

    public struct Report: Sendable {
        public var servers: [Server]
        /// Pi's configuration errors, masked.
        public var errors: [String]
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Runs `pi mcp list --json` (it connects to every enabled server) and sorts each tool by
    /// the run's rules. Tools Pi lists without annotations are sorted by their names; a tool a
    /// server marks read-only reads in a run even when its name doesn't say so.
    public static func run(env: HarnessEnvironment, access: ReviewMCPAccess, timeout: TimeInterval = 120) async throws -> Report {
        guard let pi = env.findExecutable("pi") else { throw Failure(message: "Pi (pi) is not installed.") }
        let result = await ProcessRunner.run(pi, arguments: ["mcp", "list", "--json"], environment: ChildProcess.harnessEnvironment(env),
                                             timeout: timeout)
        guard let result else { throw Failure(message: "pi mcp list didn't start.") }
        guard result.output.contains("{") else {
            throw Failure(message: "pi mcp list gave no JSON: " + SecretFilter.masked(String(result.output.prefix(300))))
        }
        return try parse(result.output, access: access)
    }

    static func parse(_ text: String, access: ReviewMCPAccess) throws -> Report {
        guard let start = text.firstIndex(of: "{"), let object = ReviewMCPCall.json(String(text[start...])) as? JSONObject else {
            throw Failure(message: "pi mcp list --json gave no JSON object.")
        }
        let servers = object.objects("servers").map { server -> Server in
            let name = server.string("name") ?? "?"
            let tools = (server["tools"] as? [Any] ?? []).compactMap { $0 as? String ?? ($0 as? JSONObject)?.string("name") }
            return Server(name: name, enabled: server["enabled"] as? Bool ?? true, state: server.string("state") ?? "",
                          tools: tools.map { ($0, ReviewMCPPolicy.kind(server: name, tool: $0, access: access)) })
        }
        let errors = (object["errors"] as? [Any] ?? []).map { error -> String in
            let text = error as? String ?? (error as? JSONObject)?.string("message") ?? "\(error)"
            return SecretFilter.masked(String(text.prefix(300)))
        }
        return Report(servers: servers, errors: errors)
    }
}
