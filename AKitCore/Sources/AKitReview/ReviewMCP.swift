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
    /// Context servers on top of `servers` (a profile's `mcp: extra_servers:` and a run's choice):
    /// Figma, Confluence, a wiki. Read only in every pass: their tools never write, not even in
    /// the send pass. A server that `servers` (or the defaults) already allow keeps its own role.
    public var extraServers: [String]
    /// Tool name patterns (`*` = any characters) that only read, on top of the tools a server
    /// marks `readOnlyHint` and the tools named by a reading verb (`get_…`, `wit_get_…`).
    public var read: [String]
    /// Tool name patterns the send pass may call to write draft notes.
    public var write: [String]
    /// Whether the brief, the role and the verifier passes may read through MCP too (the
    /// fetch pass always does).
    public var inPasses: Bool
    /// Whether the brief, the roles, the steps and the verifier may read through every server of
    /// the user's Pi (R22), not only the run's own and context servers. Risky servers (a
    /// browser, a file system, a web fetcher) still need a name in `servers` or `extraServers`.
    public var allServers: Bool

    public static let defaultWrite = ["*draft_note*", "*draft*note*"]
    /// Server names a run uses when the profile names none.
    public static let defaultServerWords = ["gitlab", "azure", "devops"]
    /// Words in a server's name that say it drives a browser, reads files or fetches any web
    /// address: such a server reaches far more than one link, so it is never offered by
    /// default, and ticking one shows a warning.
    public static let riskyServerWords = ["browser", "playwright", "puppeteer", "selenium", "chrome", "chromium", "firefox", "safari",
                                          "file", "files", "filesystem", "fs", "fetch", "http", "web", "curl", "shell", "terminal",
                                          "exec", "command", "desktop", "computer",
                                          // Secret stores, databases and cloud consoles: what they read is too much for a review.
                                          "vault", "secret", "secrets", "keychain", "password", "passwords", "sql", "db", "database",
                                          "postgres", "postgresql", "mysql", "sqlite", "mongo", "mongodb", "redis", "kubernetes", "k8s",
                                          "kubectl", "aws", "gcloud", "ssh"]
    /// Parts that mark such a server anywhere in its name (`webfetch`, `firecrawl-mcp`, `exa`).
    public static let riskyServerParts = ["fetch", "web", "crawl", "browser", "puppeteer", "playwright", "firecrawl", "tavily", "exa", "jina",
                                          "brightdata", "filesystem", "1password", "bitwarden", "lastpass", "keepass", "postgres",
                                          "mysql", "sqlite", "mongo", "clickhouse", "snowflake", "bigquery"]

    public init(servers: [String] = [], extraServers: [String] = [], read: [String] = [], write: [String] = ReviewMCPAccess.defaultWrite,
                inPasses: Bool = true, allServers: Bool = true) {
        self.servers = servers
        self.extraServers = extraServers
        self.read = read
        self.write = write
        self.inPasses = inPasses
        self.allServers = allServers
    }

    enum CodingKeys: String, CodingKey {
        case servers, extraServers, read, write, inPasses, allServers
    }

    /// Runs made before extra servers (2026-10-22) have none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        servers = try container.decode([String].self, forKey: .servers)
        extraServers = try container.decodeIfPresent([String].self, forKey: .extraServers) ?? []
        read = try container.decode([String].self, forKey: .read)
        write = try container.decode([String].self, forKey: .write)
        inPasses = try container.decode(Bool.self, forKey: .inPasses)
        // Runs made before 2026-10-23 read only their own servers.
        allServers = try container.decodeIfPresent(Bool.self, forKey: .allServers) ?? false
    }

    /// Whether a name is a Pi server name AKit can put into `--tools` and a profile.
    public static func isServerName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    static func parse(_ map: [String: Any]?, where place: String) throws -> ReviewMCPAccess {
        guard let map else { return ReviewMCPAccess() }
        let servers = ReviewYAML.strings(map["servers"])
        let extra = ReviewYAML.strings(map["extra_servers"])
        for server in servers + extra where !isServerName(server) {
            throw ReviewRole.Failure(message: "\(place): mcp server \(server) is not a Pi server name (letters, digits, _ and -).")
        }
        let write = map["write"] == nil ? defaultWrite : ReviewYAML.strings(map["write"])
        return ReviewMCPAccess(servers: servers, extraServers: extra, read: ReviewYAML.strings(map["read"]), write: write,
                               inPasses: map["in_passes"] as? Bool ?? true, allServers: map["all_servers"] as? Bool ?? true)
    }

    /// Whether the server is one of the run's own servers (named, or the defaults): GitLab and
    /// the tracker, the only ones Send Drafts may write with.
    public func isBase(server: String) -> Bool {
        let name = ReviewMCPPolicy.normalized(server).lowercased()
        if !servers.isEmpty { return servers.map { ReviewMCPPolicy.normalized($0).lowercased() }.contains(name) }
        return Self.defaultServerWords.contains { name.contains($0) } || name == "ado"
    }

    /// Whether the server is only a context server of this run: read only.
    public func isExtra(server: String) -> Bool {
        let name = ReviewMCPPolicy.normalized(server).lowercased()
        return !isBase(server: server) && extraServers.map { ReviewMCPPolicy.normalized($0).lowercased() }.contains(name)
    }

    /// Whether a run may use this Pi server at all. `inPasses`: in the brief, a role, a step or
    /// the verifier, where every server that isn't risky reads (`allServers`).
    public func allows(server: String, inPasses: Bool = false) -> Bool {
        isBase(server: server) || isExtra(server: server) || (inPasses && allServers && !Self.isRisky(server: server))
    }

    /// `--tools` of the brief, the roles, the steps and the verifier: every server's tools when
    /// they may read through all of them; the extension still checks each call.
    public var passPatterns: [String] {
        allServers ? ["mcp__*"] : toolPatterns
    }

    /// `mcp__<server>__*` for `--tools`: Pi then keeps only these servers' tools.
    public var toolPatterns: [String] {
        let extra = extraServers.filter { !isBase(server: $0) }.map { "mcp__\(ReviewMCPPolicy.normalized($0))__*" }
        var seen = Set<String>()
        return (basePatterns + extra).filter { seen.insert($0).inserted }
    }

    /// The run's own servers only (GitLab and the tracker): the send pass gets nothing else.
    public var basePatterns: [String] {
        servers.isEmpty ? Self.defaultServerWords.map { "mcp__*\($0)*__*" } + ["mcp__ado__*"]
            : servers.map { "mcp__\(ReviewMCPPolicy.normalized($0))__*" }
    }

    /// Whether a saved answer came from one of the run's own servers (or is the fetch pass's
    /// `akit_submit_context`): only those make the merge request's data.
    public func answeredByBase(_ call: ReviewMCPCall) -> Bool {
        if call.tool == "akit_submit_context" { return true }
        guard let server = call.server ?? server(ofTool: call.tool), !server.isEmpty else { return false }
        return isBase(server: server)
    }

    /// The same access without context servers (the send pass).
    public var withoutExtras: ReviewMCPAccess {
        var access = self
        access.extraServers = []
        return access
    }

    /// Context servers that `servers` (or the defaults) already allow: they keep their role,
    /// writes in Send Drafts included, so `config show` and `check` warn about them.
    public var extrasTakenAsBase: [String] { extraServers.filter { isBase(server: $0) } }

    /// The server of `mcp__<server>__<tool>`: the longest allowed name that fits, as the
    /// extension splits it, else the part before the first `__`.
    public func server(ofTool name: String) -> String? {
        guard name.hasPrefix("mcp__") else { return nil }
        let rest = String(name.dropFirst(5))
        let known = (servers + extraServers).map(ReviewMCPPolicy.normalized)
        if let named = known.filter({ rest.hasPrefix($0 + "__") }).max(by: { $0.count < $1.count }) { return named }
        return rest.components(separatedBy: "__").first
    }

    /// The same access with more context servers (a run's choice on top of the profile's).
    public func adding(extraServers more: [String]) -> ReviewMCPAccess {
        var access = self
        for server in more where !access.extraServers.contains(where: { $0.lowercased() == server.lowercased() }) {
            access.extraServers.append(server)
        }
        return access
    }

    /// A browser, a file system or a web fetcher by its name (the extension's `risky`).
    public static func isRisky(server name: String) -> Bool {
        let lower = name.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.contains(where: riskyServerWords.contains) || riskyServerParts.contains(where: lower.contains)
    }

    /// Why a server needs a second thought before a review uses it: it looks like a browser, a
    /// file system or a web fetcher. nil for the others.
    public static func warning(forServer name: String) -> String? {
        guard isRisky(server: name) else { return nil }
        return "\(name) looks like a browser, file system or web fetch server: it can read far more than your links (local files, any web "
            + "page, your signed-in sessions), and what it reads goes to the model. Tick it only if you trust it with this review."
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
    /// Reading tools of common servers whose names carry no reading verb: GitLab's
    /// `mr_discussions`; Azure DevOps MCP 2.x's one-tool-per-area reads (`wit_work_item` with
    /// `action: get`), which its server marks read-only, also for a Pi that doesn't pass the
    /// mark on; and context7's `resolve-library-id`, which resolves a library's name, not a
    /// thread (exact names only, so the forbidden `resolve` still blocks the rest).
    public static let knownReads = ["mr_discussions", "wit_work_item", "wit_query", "wit_work_item_attachment", "repo_pull_request",
                                    "repo_pull_request_thread", "repo_file", "repo_repository", "repo_branch", "wiki"]
    public static let knownExactReads = ["resolve-library-id", "resolve_library_id", "query-docs", "query_docs", "get-library-docs",
                                         "get_library_docs"]
    /// Words that run or change something anywhere in a tool's name: an open server's tool with
    /// one of them never runs (`execute_query`, `get_or_create_issue`).
    public static let actingWords = writeVerbs + ["execute", "exec", "run", "send", "merge", "trigger", "cancel", "close", "archive", "set",
                                                  "complete", "order", "invite", "share", "upload", "sql", "query", "insert", "drop", "move",
                                                  "rename", "start", "stop", "deploy", "pay", "buy", "checkout", "submit", "reply", "comment"]
    /// The longest argument text an open server's tool may get, and never a line break: code of
    /// the change doesn't fit, so it can't leave through a search box.
    public static let openArgumentLimit = 300

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
    public static func kind(server: String, tool: String, readOnlyHint: Bool = false, access: ReviewMCPAccess, inPasses: Bool = false) -> Kind {
        guard access.allows(server: server, inPasses: inPasses) else { return .blocked }
        if knownExactReads.contains(tool.lowercased()) { return .read }
        let words = tool.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        if words.contains(where: forbiddenWords.contains) { return .blocked }
        // An open server (reached only through `allServers`): AKit knows nothing of its tools, so
        // only a tool its server marks read-only, or one named like a plain read with no word that
        // acts anywhere in the name.
        if !access.isBase(server: server), !access.isExtra(server: server) {
            if readOnlyHint { return .read }
            if words.contains(where: actingWords.contains) || tool.contains("__") { return .blocked }
            return words.first.map(readVerbs.contains) == true ? .read : .blocked
        }
        let lead = lead(tool)
        let writes = lead.contains(where: writeVerbs.contains)
        // A write pattern catches only tools whose verb writes: `*draft_note*` takes
        // `create_draft_note`, not `list_draft_notes`. A context server never writes.
        if writes { return access.isBase(server: server) && access.write.contains(where: { matches($0, tool) }) ? .write : .blocked }
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
    /// The link the fetch pass named with `akit_reading_link` before this call; nil otherwise.
    public var link: String? = nil
    /// The server that answered, as the extension split the tool's name; nil in older runs.
    public var server: String? = nil

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
    /// Earlier merge requests the fetch pass read for the history of the changed files (R30):
    /// their titles and their threads, by number.
    public var pastMergeRequests: [Int: GitLabMergeRequest] = [:]
    public var pastDiscussions: [Int: [GitLabDiscussion]] = [:]
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
    /// `project`: the merge request's project path. iids count per project, so an answer about
    /// `!7` of another project (step 7 reads lists of merge requests) is never this one.
    public static func read(_ calls: [ReviewMCPCall], iid: Int, project: String? = nil) -> ReviewMCPData {
        var data = ReviewMCPData()
        func sameProject(_ mr: GitLabMergeRequest, about: Bool) -> Bool {
            guard let project, !project.isEmpty else { return true }
            guard !mr.webURL.isEmpty else { return about }
            return mr.webURL.lowercased().contains("/\(project.lowercased())/-/merge_requests/")
        }
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
            // A call about another merge request (its number in the input): the history of the files.
            let other = trusted && !aboutThis ? number(in: call.inputObject).flatMap { $0 == iid ? nil : $0 } : nil
            for value in call.values { visit(value, depth: 0, aboutThis: aboutThis, trusted: trusted, other: other) }
        }
        func visit(_ value: Any, depth: Int, aboutThis: Bool, trusted: Bool, other: Int? = nil) {
            guard depth < 5 else { return }
            if let list = value as? [Any] {
                for item in list { visit(item, depth: depth + 1, aboutThis: aboutThis, trusted: trusted, other: other) }
                return
            }
            guard let object = value as? JSONObject else { return }
            if let mr = GitLabJSON.mergeRequest(object) {
                guard mr.iid == iid, other == nil, sameProject(mr, about: aboutThis) else {
                    if trusted, mr.iid != iid, data.pastMergeRequests.count < 50 { data.pastMergeRequests[mr.iid] = mr }
                    return
                }
                let earlier = data.mergeRequest
                if data.mergeRequest == nil || (data.mergeRequest?.diffRefs == nil && mr.diffRefs != nil) { data.mergeRequest = mr }
                // One answer may carry the pipeline or the draft flag and another the diff refs: they
                // count only from a call about this merge request, the status with its own commit.
                if data.mergeRequest != earlier {
                    data.mergeRequest?.draft = earlier?.draft
                    data.mergeRequest?.pipelineStatus = earlier?.pipelineStatus
                    data.mergeRequest?.pipelineSHA = earlier?.pipelineSHA
                }
                if aboutThis {
                    if let draft = mr.draft { data.mergeRequest?.draft = draft }
                    if mr.pipelineStatus != nil {
                        data.mergeRequest?.pipelineStatus = mr.pipelineStatus
                        data.mergeRequest?.pipelineSHA = mr.pipelineSHA
                    }
                }
                // `GET …/changes` and some servers carry the diffs in the merge request.
                for change in object.objects("changes") { add(GitLabJSON.fileDiff(change)) }
                return
            }
            // Versions and diffs of an earlier merge request are its own, not this one's.
            if other != nil, GitLabJSON.version(object) != nil || GitLabJSON.fileDiff(object) != nil { return }
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
                if let other, !(data.pastDiscussions[other] ?? []).contains(where: { $0.id == discussion.id }) {
                    data.pastDiscussions[other, default: []].append(discussion)
                }
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
                if child is [Any] || child is JSONObject { visit(child, depth: depth + 1, aboutThis: aboutThis, trusted: trusted, other: other) }
            }
        }
        func add(_ diff: GitLabFileDiff?) {
            guard let diff, !data.diffs.contains(where: { $0.newPath == diff.newPath && $0.oldPath == diff.oldPath }) else { return }
            data.diffs.append(diff)
        }
        for index in data.workItems.indices { data.workItems[index].comments = comments[data.workItems[index].id] ?? [] }
        // Threads of earlier merge requests count only for one the pass read as merged, in this
        // project: never a thread of any number a prompt-injected model asked for.
        data.pastDiscussions = data.pastDiscussions.filter { number, _ in
            guard let mr = data.pastMergeRequests[number] else { return false }
            return mr.state == "merged" && sameProject(mr, about: false)
        }
        return data
    }

    /// Whether the data holds anything of a merge request (work items aside): an answer like
    /// this is the merge request's, never a link's.
    var hasMergeRequestData: Bool {
        mergeRequest != nil || !versions.isEmpty || !diffs.isEmpty || !discussions.isEmpty || !drafts.isEmpty || user != nil
    }

    /// The merge request number an input names (`merge_request_iid: 7`, `iid: "7"`), if one.
    /// Keys with `iid` first, then `mr` and other `merge_request…` keys (never `merge_request_id`,
    /// GitLab's global id), in a fixed order.
    static func number(in input: JSONObject) -> Int? {
        let keys = input.keys.sorted()
        let ranked = keys.filter { $0.lowercased().contains("iid") }
            + keys.filter { let k = $0.lowercased(); return !k.contains("iid") && k != "merge_request_id" && (k.contains("merge_request") || k == "mr") }
        for key in ranked {
            let value = input[key]
            if let number = (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init) { return number }
        }
        return nil
    }

    /// Whether an input names the merge request's number (`merge_request_iid: "7"`, `iid: 7`, …).
    /// A key that names a merge request decides; a bare `id` (some servers' project id) counts
    /// only when no such key is there.
    static func mentions(_ input: JSONObject, _ iid: Int) -> Bool {
        if let number = number(in: input) { return number == iid }
        guard let value = input.first(where: { $0.key.lowercased() == "id" })?.value else { return false }
        return (value as? NSNumber)?.intValue == iid || (value as? String) == String(iid)
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

    /// Runs `pi mcp list --json` (it connects to every enabled server) with the environment a
    /// pass gets, so the check sees what a run sees, and sorts each tool by the run's rules. Tools Pi lists without annotations are sorted by their names; a tool a
    /// server marks read-only reads in a run even when its name doesn't say so.
    public static func run(env: HarnessEnvironment, access: ReviewMCPAccess, timeout: TimeInterval = 120) async throws -> Report {
        guard let pi = env.findExecutable("pi") else { throw Failure(message: "Pi (pi) is not installed.") }
        let result = await ProcessRunner.run(pi, arguments: ["mcp", "list", "--json"], environment: await ReviewPasses.passEnvironment(env),
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
                          tools: tools.map { ($0, ReviewMCPPolicy.kind(server: name, tool: $0, access: access, inPasses: true)) })
        }
        let errors = (object["errors"] as? [Any] ?? []).map { error -> String in
            let text = error as? String ?? (error as? JSONObject)?.string("message") ?? "\(error)"
            return SecretFilter.masked(String(text.prefix(300)))
        }
        return Report(servers: servers, errors: errors)
    }
}
