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

    /// Plans the requests from the findings. `gitlab` given: the user's drafts and the threads
    /// are read again first (a rerun, or before sending); else Gather's snapshot is used.
    /// Decisions and edits of requests that are planned again are kept.
    @discardableResult
    public static func plan(_ folder: URL, gitlab: GitLabClient? = nil, env: HarnessEnvironment) async throws -> ReviewPlanFile {
        let run = try load(folder)
        guard let findings = run.findings else { throw Failure(message: "\(run.id) has no findings yet; run the passes first.") }
        guard var snapshot = run.snapshot, let refs = snapshot.refs else { throw Failure(message: "\(run.id) has no GitLab snapshot.") }
        if let gitlab {
            snapshot.drafts = try await gitlab.drafts(run.spec.mergeRequest)
            snapshot.discussions = try await gitlab.discussions(run.spec.mergeRequest)
            try ReviewJSON.write(snapshot, to: folder.appending(path: "gitlab/snapshot.json"))
        }
        let forced = Set(ReviewJSON.read([String].self, from: folder.appending(path: "forced-inline.json")) ?? [])
        var plan = ReviewPlanner.plan(.init(spec: run.spec, findings: findings.findings, gaps: run.gaps, diffs: snapshot.diffs, refs: refs,
                                            drafts: snapshot.drafts, discussions: snapshot.discussions, user: snapshot.user,
                                            scrub: LabSettings.load(env: env).scrub, forcedInline: forced),
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

    /// Sends the approved requests that weren't sent yet, as draft notes (R5: never publishes).
    /// The drafts and threads are read again first: a draft to change must still exist and
    /// carry AKit's line, a thread to reply in must be AKit's (R12).
    /// `shown`: the requests the user saw when they pressed Send, by id, with the hash of their
    /// text (`ReviewNotes.textHash(request.text)`); one that changed since, or wasn't shown, waits.
    public static func send(_ folder: URL, gitlab: GitLabClient, shown: [String: String]? = nil) async throws -> SendReport {
        let run = try load(folder)
        guard let plan = run.plan else { throw Failure(message: "\(run.id) has no requests; plan it first.") }
        let ref = run.spec.mergeRequest
        let drafts = try await gitlab.drafts(ref)
        let discussions = try await gitlab.discussions(ref)
        let user = try await gitlab.currentUser()
        var report = SendReport()
        for request in plan.requests where request.decision == .approved && !request.isSent {
            if let shown, shown[request.id] != ReviewNotes.textHash(request.text) { continue }
            var sent = ReviewRequest.Sent(date: .now, draftID: request.draftID, error: nil)
            do {
                let finding = run.finding(request.findingID)
                let meta: String = switch request.kind {
                case .summary: ReviewNotes.meta(fingerprint: "summary", role: "summary", severity: nil, run: run.id, kind: "summary",
                                                proposed: request.proposed)
                case .reply: ReviewNotes.meta(fingerprint: request.fingerprint ?? "", role: request.role ?? "", severity: nil, run: run.id,
                                              kind: "reply")
                default: ReviewNotes.meta(fingerprint: request.fingerprint ?? finding?.fingerprint ?? "", role: request.role ?? "",
                                          severity: request.severity, run: run.id, proposed: request.proposed)
                }
                let body = request.text + "\n" + meta
                func ours(_ id: Int?) throws -> GitLabDraft {
                    guard let id, let draft = drafts.first(where: { $0.id == id }) else {
                        throw Failure(message: "The draft is gone from GitLab (published or deleted); plan again.")
                    }
                    guard ReviewNotes.parseMeta(draft.note) != nil else { throw Failure(message: "That draft isn't AKit's; AKit leaves it alone.") }
                    return draft
                }
                switch request.kind {
                case .create:
                    sent.draftID = try await gitlab.createDraft(ref, note: body, position: request.position).id
                case .update:
                    let draft = try ours(request.draftID)
                    try await gitlab.updateDraft(ref, id: draft.id, note: body, position: request.position ?? draft.position)
                case .delete:
                    let draft = try ours(request.draftID)
                    try await gitlab.deleteDraft(ref, id: draft.id)
                case .summary:
                    if let id = request.draftID {
                        _ = try ours(id)
                        try await gitlab.updateDraft(ref, id: id, note: body, position: nil)
                    } else {
                        sent.draftID = try await gitlab.createDraft(ref, note: body, position: nil).id
                    }
                case .reply:
                    guard let id = request.discussionID, let thread = discussions.first(where: { $0.id == id }),
                          let first = thread.notes.first(where: { !$0.system }), first.author == user,
                          ReviewNotes.parseMeta(first.body) != nil else {
                        throw Failure(message: "That thread isn't AKit's or is gone; AKit never writes in other people's threads.")
                    }
                    guard !thread.isResolved else { throw Failure(message: "A person resolved that thread; AKit leaves it.") }
                    sent.draftID = try await gitlab.createDraftReply(ref, discussionID: id, note: body).id
                }
                report.sent.append(request.id)
            } catch {
                sent.error = error.localizedDescription
                report.failed.append((request.id, error.localizedDescription))
            }
            try ReviewJSON.update(folder.appending(path: "requests.json"), empty: plan) { file in
                if let index = file.requests.firstIndex(where: { $0.id == request.id }) { file.requests[index].sent = sent }
            }
        }
        // The snapshot learns what GitLab holds now, so a later plan (Move Inline, a discussion)
        // sees the drafts just sent instead of proposing them again.
        if !report.sent.isEmpty, var snapshot = run.snapshot {
            snapshot.drafts = (try? await gitlab.drafts(ref)) ?? snapshot.drafts
            snapshot.discussions = (try? await gitlab.discussions(ref)) ?? snapshot.discussions
            try? ReviewJSON.write(snapshot, to: folder.appending(path: "gitlab/snapshot.json"))
        }
        return report
    }

    /// The GitLab client of a run's host, with the token from `tokens`.
    public static func gitlab(for run: Run, tokens: (String) throws -> String?, fetch: @escaping ReviewFetch = ReviewHTTP.network) throws -> GitLabClient {
        let host = run.spec.mergeRequest.host
        guard ReviewTokens.origin(.gitlab, host) != nil else { throw Failure(message: "\(host) is not https: AKit sends tokens only over https.") }
        guard let token = try tokens(ReviewTokens.account(.gitlab, for: host)) else {
            throw Failure(message: "There is no GitLab token for \(host).")
        }
        return GitLabClient(host: host, token: token, fetch: fetch)
    }
}
