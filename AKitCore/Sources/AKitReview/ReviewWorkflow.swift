import AKitFoundation
import AKitLab
import Foundation

/// A finding the reviewer missed, added by the user (Add Missed…, label `missed`).
public struct ReviewMissed: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var date: Date
    public var file: String?
    public var line: Int?
    public var text: String
}

/// What the Review screen and `akit review show/post` do with one run: plan the requests,
/// record the user's decisions, send the approved ones (R4–R5, R16).
public enum ReviewWorkflow {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public struct Run: Sendable {
        public var folder: URL
        public var spec: ReviewRunSpec
        public var status: ReviewRunStatus?
        public var passes: ReviewPassLog?
        public var findings: ReviewFindingsFile?
        public var gaps: [ContextGap]
        public var plan: ReviewPlanFile?
        public var snapshot: ReviewSnapshot?
        public var missed: [ReviewMissed]
        /// The snapshot of each linked merge request that Gather read, by key.
        public var linked: [String: ReviewSnapshot] = [:]
        /// What a cleanup removed after 14 days without use (R61); nil while the worktrees are there.
        public var removed: ReviewCleanup.Removed?

        public var id: String { spec.id }
        public var worktree: URL? {
            let url = folder.appending(path: "worktree")
            return FileManager.default.fileExists(atPath: url.appending(path: ".git").path) ? url : nil
        }

        public func finding(_ id: String?) -> ReviewFinding? { findings?.findings.first { $0.id == id } }
        public func placement(_ id: String) -> ReviewPlacement? { plan?.placements.first { $0.findingID == id } }

        /// The code around a line of the reviewed commit, numbered; nil without a worktree or the file.
        public func code(around line: Int, in file: String, radius: Int = 3) -> [(number: Int, text: String)]? {
            guard let lines = ReviewCandidates.fileLines(file, worktree: worktree), line >= 1, line <= lines.count else { return nil }
            return (max(1, line - radius)...min(lines.count, line + radius)).map { ($0, lines[$0 - 1]) }
        }
    }

    public static func load(_ folder: URL) throws -> Run {
        ReviewMask.saved(in: folder)
        guard let spec = ReviewJSON.read(ReviewRunSpec.self, from: folder.appending(path: "run.json")) else {
            throw Failure(message: "\(folder.lastPathComponent) has no readable run.json.")
        }
        var linked: [String: ReviewSnapshot] = [:]
        for change in spec.linked ?? [] {
            if let snapshot = ReviewJSON.read(ReviewSnapshot.self, from: ReviewLinked.snapshotFile(folder, key: change.key)) { linked[change.key] = snapshot }
        }
        return Run(folder: folder, spec: spec, status: ReviewJSON.read(ReviewRunStatus.self, from: folder.appending(path: "status.json")),
                   passes: ReviewJSON.read(ReviewPassLog.self, from: folder.appending(path: "passes.json")),
                   findings: ReviewJSON.read(ReviewFindingsFile.self, from: folder.appending(path: "findings.json")),
                   gaps: ReviewJSON.read([ContextGap].self, from: folder.appending(path: "gaps.json")) ?? [],
                   plan: ReviewJSON.read(ReviewPlanFile.self, from: folder.appending(path: "requests.json")),
                   snapshot: ReviewJSON.read(ReviewSnapshot.self, from: folder.appending(path: "gitlab/snapshot.json")),
                   missed: ReviewJSON.read([ReviewMissed].self, from: folder.appending(path: "missed.json")) ?? [], linked: linked,
                   removed: ReviewCleanup.removed(folder))
    }

    /// Plans the requests from the findings, against the drafts and threads the run's fetch pass
    /// read (a rerun is a new run, with a new fetch). Decisions and edits of requests that are
    /// planned again are kept.
    @discardableResult
    public static func plan(_ folder: URL, env: HarnessEnvironment) async throws -> ReviewPlanFile {
        let run = try load(folder)
        guard let findings = run.findings else { throw Failure(message: "\(run.id) has no findings yet; run the passes first.") }
        guard let snapshot = run.snapshot, let refs = snapshot.refs else { throw Failure(message: "\(run.id) has no GitLab snapshot.") }
        let forced = Set(ReviewJSON.read([String].self, from: folder.appending(path: "forced-inline.json")) ?? [])
        let scrub = LabSettings.load(env: env).scrub
        // Each merge request gets its own plan: its findings, positions, drafts and summary.
        let own = findings.findings.filter { ReviewLinked.key(of: $0.file, spec: run.spec) == nil }
        var plan = ReviewPlanner.plan(.init(spec: run.spec, findings: own, gaps: run.gaps, diffs: snapshot.diffs, refs: refs,
                                            drafts: snapshot.drafts, discussions: snapshot.discussions, user: snapshot.user,
                                            scrub: scrub, forcedInline: forced,
                                            keptFingerprints: Set(ReviewJSON.read([String].self, from: folder.appending(path: "rerun-kept.json")) ?? [])),
                                      findingsVersion: findings.version)
        for change in run.spec.linked ?? [] {
            guard change.headSHA != nil, let linked = run.linked[change.key], let linkedRefs = linked.refs else { continue }
            var part = ReviewPlanner.plan(.init(spec: linkedSpec(run.spec, change), findings: linkedFindings(findings.findings, key: change.key),
                                                gaps: [], diffs: linked.diffs, refs: linkedRefs, drafts: linked.drafts,
                                                discussions: linked.discussions, user: linked.user, scrub: scrub, forcedInline: forced),
                                          findingsVersion: findings.version)
            for index in part.requests.indices {
                part.requests[index].mergeRequest = change.mergeRequest
                part.requests[index].file = part.requests[index].file.map { ReviewLinked.path(change.key, $0) }
            }
            plan.requests += part.requests
            plan.placements += part.placements
        }
        if let old = run.plan {
            for index in plan.requests.indices {
                let new = plan.requests[index]
                guard let previous = old.requests.first(where: { $0.kind == new.kind && $0.fingerprint == new.fingerprint
                    && $0.mergeRequest == new.mergeRequest
                    && $0.draftID == new.draftID && $0.discussionID == new.discussionID && !$0.isSent }) else { continue }
                plan.requests[index].decision = previous.decision
                plan.requests[index].reason = previous.reason
                plan.requests[index].comment = previous.comment
                // An edit stays only while AKit proposes the same text it was made on.
                if previous.proposed == new.proposed { plan.requests[index].edited = previous.edited }
                else if previous.decision == .approved { plan.requests[index].decision = .pending }
            }
        }
        // What was sent stays on the list, first; the new requests are numbered after it.
        let sent = run.plan?.requests.filter(\.isSent) ?? []
        let start = (sent.compactMap { Int($0.id.dropFirst()) }.max() ?? 0)
        for index in plan.requests.indices { plan.requests[index].id = "r\(start + index + 1)" }
        plan.requests = sent + plan.requests
        try ReviewJSON.write(plan, to: folder.appending(path: "requests.json"))
        // What became of AKit's published threads, as this run's fetch read them (R31).
        if run.spec.local == nil {
            try? ReviewOutcomes.write(folder: folder, run: try load(folder), discussions: snapshot.discussions, mergeRequest: snapshot.mergeRequest,
                                      head: refs.headSHA, user: snapshot.user, home: env.homeDirectory, checked: snapshot.gathered)
        }
        return plan
    }

    /// The spec a linked merge request is planned with: its own merge request, head and commit
    /// range; no rerun (a rerun follows the first merge request) and no path rules of the first's project.
    static func linkedSpec(_ spec: ReviewRunSpec, _ change: ReviewLinkedChange) -> ReviewRunSpec {
        var sub = spec
        sub.mergeRequest = change.mergeRequest
        sub.headSHA = change.headSHA
        sub.rerun = nil
        sub.since = change.since
        sub.fromCommit = change.fromCommit
        sub.linked = nil
        sub.pathInstructions = []
        return sub
    }

    /// The findings of one linked merge request, with their paths in its own repository.
    static func linkedFindings(_ findings: [ReviewFinding], key: String) -> [ReviewFinding] {
        findings.compactMap { finding in
            guard let split = ReviewLinked.split(finding.file), split.key == key else { return nil }
            var finding = finding
            finding.file = split.path
            return finding
        }
    }

    /// Approve or reject one request, with the edited text and the reason (a rejected
    /// finding needs one, R16).
    public static func decide(_ folder: URL, request id: String, decision: ReviewRequest.Decision, edited: String? = nil,
                              reason: ReviewRequest.Reason? = nil, comment: String? = nil) throws {
        try ReviewJSON.update(folder.appending(path: "requests.json"), empty: ReviewPlanFile(created: .now, findingsVersion: 0, requests: [],
                                                                                            placements: [])) { plan in
            guard let index = plan.requests.firstIndex(where: { $0.id == id }) else { throw Failure(message: "There is no request \(id).") }
            guard !plan.requests[index].isSent else { throw Failure(message: "\(id) was sent already.") }
            // Choosing a request again after a publish that may have gone through (R66): it can be sent once more.
            if plan.requests[index].isUncertain { plan.requests[index].sent = nil }
            if decision == .rejected, plan.requests[index].findingID != nil, reason == nil {
                throw Failure(message: "A rejected finding needs a reason: \(ReviewRequest.Reason.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            plan.requests[index].decision = decision
            plan.requests[index].reason = decision == .rejected ? reason : nil
            plan.requests[index].comment = comment.flatMap { $0.isEmpty ? nil : $0 }
            if let edited {
                let trimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
                plan.requests[index].edited = trimmed == plan.requests[index].proposed.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : trimmed
            }
        }
    }

    /// Moves an "only in AKit" finding inline by hand (label `missed-by-filter`) and plans again.
    public static func moveInline(_ folder: URL, finding id: String, env: HarnessEnvironment) async throws {
        try ReviewJSON.update(folder.appending(path: "forced-inline.json"), empty: [String]()) { ids in
            if !ids.contains(id) { ids.append(id) }
        }
        try await plan(folder, env: env)
    }

    /// Add Missed…: what the reviewer should have found (label `missed`); stays in AKit.
    @discardableResult
    public static func addMissed(_ folder: URL, file: String?, line: Int?, text: String) throws -> ReviewMissed {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure(message: "Say what was missed.") }
        return try ReviewJSON.update(folder.appending(path: "missed.json"), empty: [ReviewMissed]()) { list in
            let item = ReviewMissed(id: "m\(list.count + 1)", date: .now, file: file.flatMap { $0.isEmpty ? nil : $0 }, line: line,
                                    text: SecretFilter.masked(trimmed))
            list.append(item)
            return item
        }
    }

    public struct SendReport: Sendable {
        public var sent: [String] = []
        /// Request id → what GitLab (or AKit's safety check) said.
        public var failed: [(id: String, message: String)] = []
        /// Requests the GitLab MCP server can only publish at once (no draft notes, R66): they wait
        /// for Publish Now… (`send(…, publish: true)`). Each is in `failed` too.
        public var needsPublish: [String] = []
        /// The sent requests that were published at once, not added as drafts.
        public var published: [String] = []
        /// Said once for the whole send: Pi's answer, when it named none of the requests it skipped.
        public var note: String?

        public init() {}

        /// Publish Now… after a send: the later report over this one, so what the first sent stays.
        public func merged(with later: SendReport) -> SendReport {
            var merged = self
            let redone = Set(later.sent + later.failed.map(\.id))
            merged.sent += later.sent.filter { !merged.sent.contains($0) }
            merged.published += later.published.filter { !merged.published.contains($0) }
            merged.failed = merged.failed.filter { !redone.contains($0.id) } + later.failed
            merged.needsPublish = merged.needsPublish.filter { !redone.contains($0) } + later.needsPublish.filter { !merged.needsPublish.contains($0) }
            merged.note = later.note ?? merged.note
            return merged
        }
    }

    /// The message of a request that can only be published at once (R66).
    public static let needsPublishMessage = "Your GitLab MCP server has no draft notes: this comment can only be published right away."
    /// A publish call that started and didn't clearly fail (R66): it may be in the merge request.
    public static let uncertainMessage = "It may have been published: check the merge request in GitLab before you publish it again. "
        + "AKit sends it again only after you approve it again."
    /// The merge request's head moved since the review: a diff note would land on other lines (R66).
    public static let headMovedMessage = "The merge request changed since the review, so its lines may have moved. Review Again…, then publish."

    /// The merge request's head as GitLab has it now, read with git from the run's worktree (or
    /// its linked worktree, or AKit's clone): `git ls-remote origin refs/merge-requests/<iid>/head`.
    /// A published diff note lands on GitLab's latest diff, not on the reviewed commit (R66).
    static func remoteHead(_ run: Run, key: String?, iid: Int, env: HarnessEnvironment) async -> Result<String, Failure> {
        let tree: URL? = if let key {
            ReviewLinked.worktree(run.folder, key: key)
        } else {
            run.worktree ?? run.spec.repository.map { URL(filePath: $0.clone, directoryHint: .isDirectory) }
        }
        guard let tree, FileManager.default.fileExists(atPath: tree.appending(path: ".git").path) else {
            return .failure(Failure(message: "the run has no worktree or clone to ask git from"))
        }
        guard let git = env.findExecutable("git") else { return .failure(Failure(message: "git is not installed")) }
        var variables = env.gitVariables
        if variables["GIT_SSH_COMMAND"] == nil { variables["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        let result = await ProcessRunner.run(git, arguments: ["-C", tree.path, "-c", "core.hooksPath=/dev/null", "ls-remote", "origin",
                                                              "refs/merge-requests/\(iid)/head"], environment: variables, timeout: 30)
        guard let result, result.succeeded else {
            let said = result.map { String($0.output.split(whereSeparator: \.isNewline).first ?? "") } ?? ""
            return .failure(Failure(message: "git ls-remote failed" + (said.isEmpty ? "" : ": " + SecretFilter.masked(String(said.prefix(200))))))
        }
        let sha = result.output.split(whereSeparator: \.isNewline).first?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard sha.count == 40, sha.allSatisfy(\.isHexDigit) else {
            return .failure(Failure(message: "GitLab named no head for merge request !\(iid)"))
        }
        return .success(sha.lowercased())
    }

    static func publishHostsFile(_ env: HarnessEnvironment) -> URL {
        ReviewPaths(home: env.homeDirectory).folder.appending(path: "publish-hosts.json")
    }

    /// Whether AKit learned that the GitLab MCP server of `host` has no draft notes, so Send
    /// Drafts… asks to publish at once (R66).
    public static func publishesDirectly(host: String, env: HarnessEnvironment) -> Bool {
        (ReviewJSON.read([String].self, from: publishHostsFile(env)) ?? []).contains(host)
    }

    /// Remembers (or, with `false`, forgets: Try Drafts Again) that `host` publishes at once.
    public static func setPublishesDirectly(_ on: Bool, host: String, env: HarnessEnvironment) throws {
        try ReviewJSON.update(publishHostsFile(env), empty: [String]()) { hosts in
            hosts.removeAll { $0 == host }
            if on { hosts.append(host) }
        }
    }

    /// The model's line about one request in its last answer (`r1 — Not sent: …`), or the
    /// answer's start when the send carried only this request (`only`); masked. nil without either.
    static func piSaid(_ answer: String?, about id: String, only: Bool = true) -> String? {
        guard let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else { return nil }
        let word = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: id) + "(?![A-Za-z0-9_])"
        let line = answer.split(whereSeparator: \.isNewline).first { $0.range(of: word, options: .regularExpression) != nil }
        guard line != nil || only else { return nil }
        let text = (line.map(String.init) ?? answer).trimmingCharacters(in: .whitespacesAndNewlines)
        return "Pi: " + SecretFilter.masked(String(text.prefix(300)))
    }

    /// Sends the approved requests that weren't sent yet, as draft notes (R5: never publishes):
    /// a Pi send pass writes them through the user's GitLab MCP server, and the extension lets a
    /// call through only with an approved request's text, draft, thread, file and line
    /// (`ReviewExtension`). A draft to change must carry AKit's line and a thread to reply in must
    /// be AKit's, by what the run's fetch pass read (R12).
    /// `shown`: the requests the user saw when they pressed Send, by id, with the hash of their
    /// text (`ReviewNotes.textHash(request.text)`); one that changed since, or wasn't shown, waits.
    /// `publish` (R66, the user confirmed Publish Now…): a GitLab MCP server without draft notes
    /// may publish the comments at once through `save_merge_request_review`. Without it, such a
    /// call is blocked and the request is reported in `needsPublish`.
    public static func send(_ folder: URL, env: HarnessEnvironment, shown: [String: String]? = nil, publish: Bool = false,
                            options: ReviewPasses.Options = .init()) async throws -> SendReport {
        let run = try load(folder)
        guard run.spec.local == nil else { throw Failure(message: "\(run.id) is a local review: its findings stay in AKit, nothing goes to GitLab.") }
        guard let plan = run.plan else { throw Failure(message: "\(run.id) has no requests; plan it first.") }
        var report = SendReport()
        var approved: [JSONObject] = []
        /// The merge request a request goes to, its key (nil: the first) and what its fetch read.
        func target(_ request: ReviewRequest) -> (ref: MergeRequestRef, key: String?, snapshot: ReviewSnapshot?)? {
            guard let ref = request.mergeRequest, ref != run.spec.mergeRequest else { return (run.spec.mergeRequest, nil, run.snapshot) }
            guard let change = run.spec.linked?.first(where: { $0.mergeRequest == ref }) else { return nil }
            return (ref, change.key, run.linked[change.key])
        }
        var used: [MergeRequestRef] = []
        var bodies: [String: (body: String, request: ReviewRequest)] = [:]
        func fail(_ id: String, _ message: String) throws {
            report.failed.append((id, message))
            try ReviewJSON.update(folder.appending(path: "requests.json"), empty: plan) { file in
                if let index = file.requests.firstIndex(where: { $0.id == id }) {
                    file.requests[index].sent = ReviewRequest.Sent(date: .now, draftID: nil, error: message)
                }
            }
        }
        // The merge requests' heads as GitLab has them now, read once each before a publish (R66).
        var heads: [MergeRequestRef: Result<String, Failure>] = [:]
        // A publish that may have gone through waits until the user approves it again.
        for request in plan.requests where request.decision == .approved && !request.isSent && !request.isUncertain {
            if let shown, shown[request.id] != ReviewNotes.textHash(request.text) { continue }
            // Only Czech goes to GitLab, whatever the run's language or an edit (Translate never changes the text).
            if request.kind != .delete, !ReviewLanguage.isCzech(request.text, marker: run.spec.posting.marker.value) {
                try fail(request.id, "Not in Czech: AKit sends only Czech comments to GitLab. Edit it into Czech, then send it again.")
                continue
            }
            guard let goal = target(request) else {
                try fail(request.id, "Its merge request \(request.mergeRequest?.label ?? "?") isn't part of this run.")
                continue
            }
            let snapshot = goal.snapshot
            // The merge request every write must name: the project by path or GitLab's number.
            let projects: [Any] = [goal.ref.projectPath] + (snapshot?.mergeRequest.projectID.map { [$0] } ?? [])
            let mr: JSONObject = ["projects": projects, "iid": goal.ref.iid]
            let finding = run.finding(request.findingID)
            let meta: String = switch request.kind {
            case .summary: ReviewNotes.meta(fingerprint: "summary", role: "summary", severity: nil, run: run.id, kind: "summary",
                                            proposed: request.proposed)
            case .reply: ReviewNotes.meta(fingerprint: request.fingerprint ?? "", role: request.role ?? "", severity: nil, run: run.id, kind: "reply")
            default: ReviewNotes.meta(fingerprint: request.fingerprint ?? finding?.fingerprint ?? "", role: request.role ?? "",
                                      severity: request.severity, run: run.id, proposed: request.proposed)
            }
            let body = request.text + "\n" + meta
            func ours(_ id: Int?) -> Bool {
                guard let id, let draft = snapshot?.drafts.first(where: { $0.id == id }) else { return false }
                return ReviewNotes.parseMeta(draft.note) != nil
            }
            var entry: JSONObject = ["id": request.id, "body": body]
            switch request.kind {
            case .create:
                entry["action"] = "create"
            case .update:
                guard ours(request.draftID) else { try fail(request.id, "The draft is gone or isn't AKit's; plan again with a new run."); continue }
                entry["action"] = "update"
                entry["draft_id"] = request.draftID
            case .delete:
                guard ours(request.draftID) else { try fail(request.id, "The draft is gone or isn't AKit's; AKit leaves it alone."); continue }
                entry = ["id": request.id, "action": "delete", "draft_id": request.draftID as Any]
            case .summary:
                if let id = request.draftID {
                    guard ours(id) else { try fail(request.id, "The summary draft is gone or isn't AKit's; plan again with a new run."); continue }
                    entry["action"] = "update"
                    entry["draft_id"] = id
                } else {
                    entry["action"] = "create"
                }
            case .reply:
                guard let id = request.discussionID, let thread = snapshot?.discussions.first(where: { $0.id == id }),
                      let first = thread.notes.first(where: { !$0.system }), !(snapshot?.user ?? "").isEmpty, first.author == snapshot?.user,
                      ReviewNotes.parseMeta(first.body) != nil else {
                    try fail(request.id, "That thread isn't AKit's or is gone; AKit never writes in other people's threads.")
                    continue
                }
                guard !thread.isResolved else { try fail(request.id, "A person resolved that thread; AKit leaves it."); continue }
                entry["action"] = "create"
                entry["discussion_id"] = id
            }
            if entry["action"] as? String != "delete", let position = request.position {
                entry["position"] = position.json
                entry["path"] = position.newLine != nil || position.oldLine == nil ? position.newPath : position.oldPath
                entry["line"] = position.newLine ?? position.oldLine
                // A published diff note goes on GitLab's latest diff: only while that is still the reviewed head.
                if publish, entry["action"] as? String == "create", entry["discussion_id"] == nil {
                    if heads[goal.ref] == nil { heads[goal.ref] = await remoteHead(run, key: goal.key, iid: goal.ref.iid, env: env) }
                    switch heads[goal.ref] {
                    case .success(let head) where head == position.headSHA.lowercased(): break
                    case .success: try fail(request.id, headMovedMessage); continue
                    case .failure(let failure): try fail(request.id, "AKit couldn't check the merge request's head: \(failure.message). Review Again…, then publish."); continue
                    case nil: continue
                    }
                }
            }
            entry["mr"] = mr
            if !used.contains(goal.ref) { used.append(goal.ref) }
            approved.append(entry)
            bodies[request.id] = (body, request)
        }
        guard !approved.isEmpty else { return report }
        let sendFolder = folder.appending(path: "send", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sendFolder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: approved, options: [.prettyPrinted, .sortedKeys]).write(to: sendFolder.appending(path: "approved.json"))
        let logFile = sendFolder.appending(path: "log.jsonl")
        // Lines, not bytes: masking may rewrite a line after the pass.
        let before = ((try? Data(contentsOf: logFile)) ?? Data()).split(separator: 0x0A).count
        var passError: String?
        var answer: String?
        do {
            answer = try await ReviewPasses.send(folder: folder, spec: run.spec, count: approved.count, mergeRequests: used, publish: publish,
                                                 env: env, options: options)
        } catch {
            passError = error.localizedDescription
        }
        // What the extension saw GitLab answer, for each request this send carried.
        var outcome: [String: (draftID: Int?, error: String?, published: Bool)] = [:]
        var needsPublish = Set<String>()
        // Publish calls the extension let through, and those whose error may hide a published note.
        var started = Set<String>(), uncertain = Set<String>()
        let data = (try? Data(contentsOf: logFile)) ?? Data()
        for line in data.split(separator: 0x0A).dropFirst(before) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? JSONObject, let id = object.string("request"),
                  bodies[id] != nil else { continue }
            let text = object.string("text") ?? ""
            let viaPublish = (object.string("tool") ?? "").lowercased().hasSuffix("__" + ReviewMCPPolicy.publishTool)
            if object.bool("started") {
                if viaPublish { started.insert(id) }
            } else if object.bool("needsPublish") {
                // The extension blocked it: the server can only publish, and the user hasn't said yes.
                needsPublish.insert(id)
            } else if !object.bool("isError") {
                let answer = ReviewMCPCall.json(text) as? JSONObject
                    ?? text.firstIndex(of: "{").flatMap { ReviewMCPCall.json(String(text[$0...])) as? JSONObject }
                // A draft tool answers with the draft; GitLab's own server may wrap the note.
                let returned = viaPublish
                    ? answer?.object("note")?.int("id") ?? answer?.objects("notes").first?.int("id") ?? answer?.int("id")
                    : answer?.int("id")
                outcome[id] = (returned, nil, viaPublish)
                uncertain.remove(id)
            } else if viaPublish, text.range(of: #"(?<![0-9])4[0-9][0-9](?![0-9])"#, options: .regularExpression) == nil {
                // Not a clear refusal (a timeout, a dropped connection): the note may be there.
                if outcome[id]?.error == nil, outcome[id] != nil { continue }
                uncertain.insert(id)
                outcome[id] = (nil, uncertainMessage, true)
            } else if outcome[id] == nil || outcome[id]?.error != nil {
                // A retry that worked wins over the failure before it.
                outcome[id] = (nil, "GitLab: " + SecretFilter.masked(String(text.prefix(300))), viaPublish)
            }
        }
        // Drafts by merge request: nil key = the first.
        var drafts: [String?: [GitLabDraft]] = [nil: run.snapshot?.drafts ?? []]
        for (key, snapshot) in run.linked { drafts[key] = snapshot.drafts }
        var changed = Set<String?>()
        // The hosts whose GitLab MCP server turned out to have no drafts (R66).
        var publishedHosts = Set<String>()
        for entry in approved {
            guard let id = entry["id"] as? String, let (body, request) = bodies[id] else { continue }
            let key = target(request)?.key
            var sent = ReviewRequest.Sent(date: .now, draftID: request.draftID, error: nil)
            if let result = outcome[id], result.error == nil, result.published {
                // Published at once (R66): a note in the merge request, not a draft to remember.
                sent.published = true
                sent.noteID = result.draftID
                report.sent.append(id)
                report.published.append(id)
                if let host = target(request)?.ref.host { publishedHosts.insert(host) }
            } else if let result = outcome[id], result.error == nil {
                if let draftID = result.draftID { sent.draftID = draftID }
                report.sent.append(id)
                // The snapshot learns the drafts just sent, so a later plan (Move Inline, a
                // discussion) doesn't propose them again.
                changed.insert(key)
                switch entry["action"] as? String {
                case "delete": drafts[key, default: []].removeAll { $0.id == request.draftID }
                default:
                    if let draftID = sent.draftID {
                        drafts[key, default: []].removeAll { $0.id == draftID }
                        drafts[key, default: []].append(GitLabDraft(id: draftID, note: body, position: request.position,
                                                                    discussionID: request.discussionID))
                    }
                }
            } else if uncertain.contains(id) || (started.contains(id) && outcome[id] == nil) {
                sent.error = uncertainMessage
                sent.uncertain = true
                report.failed.append((id, uncertainMessage))
            } else if needsPublish.contains(id), outcome[id] == nil || outcome[id]?.error != nil {
                sent.error = needsPublishMessage
                report.failed.append((id, needsPublishMessage))
                report.needsPublish.append(id)
                if let host = target(request)?.ref.host { publishedHosts.insert(host) }
            } else {
                sent.error = outcome[id]?.error ?? passError ?? piSaid(answer, about: id, only: approved.count == 1) ?? "The send pass didn't send it."
                if sent.error == "The send pass didn't send it.", report.note == nil,
                   let said = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty {
                    report.note = "Pi's answer: " + SecretFilter.masked(String(said.prefix(300)))
                }
                report.failed.append((id, sent.error ?? ""))
            }
            try ReviewJSON.update(folder.appending(path: "requests.json"), empty: plan) { file in
                if let index = file.requests.firstIndex(where: { $0.id == id }) { file.requests[index].sent = sent }
            }
        }
        for key in changed {
            if let key {
                guard var snapshot = run.linked[key] else { continue }
                snapshot.drafts = drafts[key] ?? []
                try? ReviewJSON.write(snapshot, to: ReviewLinked.snapshotFile(folder, key: key))
            } else if var snapshot = run.snapshot {
                snapshot.drafts = drafts[nil] ?? []
                try? ReviewJSON.write(snapshot, to: folder.appending(path: "gitlab/snapshot.json"))
            }
        }
        for host in publishedHosts.sorted() { try? setPublishesDirectly(true, host: host, env: env) }
        return report
    }
}
