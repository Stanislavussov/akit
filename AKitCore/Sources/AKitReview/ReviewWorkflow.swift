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
        return Run(folder: folder, spec: spec, status: ReviewJSON.read(ReviewRunStatus.self, from: folder.appending(path: "status.json")),
                   passes: ReviewJSON.read(ReviewPassLog.self, from: folder.appending(path: "passes.json")),
                   findings: ReviewJSON.read(ReviewFindingsFile.self, from: folder.appending(path: "findings.json")),
                   gaps: ReviewJSON.read([ContextGap].self, from: folder.appending(path: "gaps.json")) ?? [],
                   plan: ReviewJSON.read(ReviewPlanFile.self, from: folder.appending(path: "requests.json")),
                   snapshot: ReviewJSON.read(ReviewSnapshot.self, from: folder.appending(path: "gitlab/snapshot.json")),
                   missed: ReviewJSON.read([ReviewMissed].self, from: folder.appending(path: "missed.json")) ?? [])
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
        var plan = ReviewPlanner.plan(.init(spec: run.spec, findings: findings.findings, gaps: run.gaps, diffs: snapshot.diffs, refs: refs,
                                            drafts: snapshot.drafts, discussions: snapshot.discussions, user: snapshot.user,
                                            scrub: LabSettings.load(env: env).scrub, forcedInline: forced,
                                            keptFingerprints: Set(ReviewJSON.read([String].self, from: folder.appending(path: "rerun-kept.json")) ?? [])),
                                      findingsVersion: findings.version)
        if let old = run.plan {
            for index in plan.requests.indices {
                let new = plan.requests[index]
                guard let previous = old.requests.first(where: { $0.kind == new.kind && $0.fingerprint == new.fingerprint
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

    /// Approve or reject one request, with the edited text and the reason (a rejected
    /// finding needs one, R16).
    public static func decide(_ folder: URL, request id: String, decision: ReviewRequest.Decision, edited: String? = nil,
                              reason: ReviewRequest.Reason? = nil, comment: String? = nil) throws {
        try ReviewJSON.update(folder.appending(path: "requests.json"), empty: ReviewPlanFile(created: .now, findingsVersion: 0, requests: [],
                                                                                            placements: [])) { plan in
            guard let index = plan.requests.firstIndex(where: { $0.id == id }) else { throw Failure(message: "There is no request \(id).") }
            guard !plan.requests[index].isSent else { throw Failure(message: "\(id) was sent already.") }
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
    public static func addMissed(_ folder: URL, file: String?, line: Int?, text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure(message: "Say what was missed.") }
        try ReviewJSON.update(folder.appending(path: "missed.json"), empty: [ReviewMissed]()) { list in
            list.append(ReviewMissed(id: "m\(list.count + 1)", date: .now, file: file.flatMap { $0.isEmpty ? nil : $0 }, line: line,
                                     text: SecretFilter.masked(trimmed)))
        }
    }

    public struct SendReport: Sendable {
        public var sent: [String] = []
        /// Request id → what GitLab (or AKit's safety check) said.
        public var failed: [(id: String, message: String)] = []
    }

    /// Sends the approved requests that weren't sent yet, as draft notes (R5: never publishes):
    /// a Pi send pass writes them through the user's GitLab MCP server, and the extension lets a
    /// call through only with an approved request's text, draft, thread, file and line
    /// (`ReviewExtension`). A draft to change must carry AKit's line and a thread to reply in must
    /// be AKit's, by what the run's fetch pass read (R12).
    /// `shown`: the requests the user saw when they pressed Send, by id, with the hash of their
    /// text (`ReviewNotes.textHash(request.text)`); one that changed since, or wasn't shown, waits.
    public static func send(_ folder: URL, env: HarnessEnvironment, shown: [String: String]? = nil,
                            options: ReviewPasses.Options = .init()) async throws -> SendReport {
        let run = try load(folder)
        guard run.spec.local == nil else { throw Failure(message: "\(run.id) is a local review: its findings stay in AKit, nothing goes to GitLab.") }
        guard let plan = run.plan else { throw Failure(message: "\(run.id) has no requests; plan it first.") }
        let snapshot = run.snapshot
        var report = SendReport()
        var approved: [JSONObject] = []
        // The merge request every write must name: the project by path or GitLab's number.
        let projects: [Any] = [run.spec.mergeRequest.projectPath] + (snapshot?.mergeRequest.projectID.map { [$0] } ?? [])
        let mr: JSONObject = ["projects": projects, "iid": run.spec.mergeRequest.iid]
        var bodies: [String: (body: String, request: ReviewRequest)] = [:]
        func fail(_ id: String, _ message: String) throws {
            report.failed.append((id, message))
            try ReviewJSON.update(folder.appending(path: "requests.json"), empty: plan) { file in
                if let index = file.requests.firstIndex(where: { $0.id == id }) {
                    file.requests[index].sent = ReviewRequest.Sent(date: .now, draftID: nil, error: message)
                }
            }
        }
        for request in plan.requests where request.decision == .approved && !request.isSent {
            if let shown, shown[request.id] != ReviewNotes.textHash(request.text) { continue }
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
            }
            entry["mr"] = mr
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
        do {
            try await ReviewPasses.send(folder: folder, spec: run.spec, count: approved.count, env: env, options: options)
        } catch {
            passError = error.localizedDescription
        }
        // What the extension saw GitLab answer, for each request this send carried.
        var outcome: [String: (draftID: Int?, error: String?)] = [:]
        let data = (try? Data(contentsOf: logFile)) ?? Data()
        for line in data.split(separator: 0x0A).dropFirst(before) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? JSONObject, let id = object.string("request"),
                  bodies[id] != nil else { continue }
            let text = object.string("text") ?? ""
            if !object.bool("isError") {
                let answer = ReviewMCPCall.json(text) as? JSONObject
                    ?? text.firstIndex(of: "{").flatMap { ReviewMCPCall.json(String(text[$0...])) as? JSONObject }
                outcome[id] = (answer?.int("id"), nil)
            } else if outcome[id] == nil || outcome[id]?.error != nil {
                // A retry that worked wins over the failure before it.
                outcome[id] = (nil, "GitLab: " + SecretFilter.masked(String(text.prefix(300))))
            }
        }
        var drafts = snapshot?.drafts ?? []
        for entry in approved {
            guard let id = entry["id"] as? String, let (body, request) = bodies[id] else { continue }
            var sent = ReviewRequest.Sent(date: .now, draftID: request.draftID, error: nil)
            if let result = outcome[id], result.error == nil {
                if let draftID = result.draftID { sent.draftID = draftID }
                report.sent.append(id)
                // The snapshot learns the drafts just sent, so a later plan (Move Inline, a
                // discussion) doesn't propose them again.
                switch entry["action"] as? String {
                case "delete": drafts.removeAll { $0.id == request.draftID }
                default:
                    if let draftID = sent.draftID {
                        drafts.removeAll { $0.id == draftID }
                        drafts.append(GitLabDraft(id: draftID, note: body, position: request.position, discussionID: request.discussionID))
                    }
                }
            } else {
                sent.error = outcome[id]?.error ?? passError ?? "The send pass didn't send it."
                report.failed.append((id, sent.error ?? ""))
            }
            try ReviewJSON.update(folder.appending(path: "requests.json"), empty: plan) { file in
                if let index = file.requests.firstIndex(where: { $0.id == id }) { file.requests[index].sent = sent }
            }
        }
        if !report.sent.isEmpty, var snapshot {
            snapshot.drafts = drafts
            try? ReviewJSON.write(snapshot, to: folder.appending(path: "gitlab/snapshot.json"))
        }
        return report
    }
}
