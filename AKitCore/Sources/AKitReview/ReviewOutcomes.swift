import AKitFoundation
import Foundation

/// What became of each published 🤖 thread in GitLab (`docs/design/review.md`, R31): fixed,
/// dismissed, ignored, or still open, with the author's replies. Every plan of a run and
/// **Sync Outcomes** write `<run>/outcomes.json`; the Quality page shows the share accepted
/// by role and model.
public struct ReviewOutcome: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Resolved after a later push, and the finding isn't found again.
        case fixed
        /// Resolved without a change to it (or the finding is still there).
        case dismissed
        /// The merge request was merged with the thread still open.
        case ignored
        /// Still open on an open merge request.
        case open
    }

    public var mergeRequest: String
    public var fingerprint: String
    public var discussionID: String
    public var role: String?
    /// The run that wrote the thread (`run=` of the hidden line) and its passes' model.
    public var run: String?
    public var model: String
    public var kind: Kind
    /// The replies of people other than the user, masked and cut.
    public var replies: [String]
    public var file: String?
    public var line: Int?
    public var checked: Date
}

public enum ReviewOutcomes {
    /// The outcome of every AKit thread of `user` in `discussions`. `stillFound`: fingerprints a
    /// run of `reviewedHead` still finds; they say "not fixed" only when that is the current
    /// head (a run of an older head finds what the push may have fixed since).
    public static func compute(discussions: [GitLabDiscussion], user: String, mergeRequest: GitLabMergeRequest, url: String, head: String,
                               stillFound: Set<String>, reviewedHead: String? = nil, models: [String: String], now: Date = .now) -> [ReviewOutcome] {
        guard !user.isEmpty else { return [] }
        var result: [ReviewOutcome] = []
        for discussion in discussions {
            let notes = discussion.notes.filter { !$0.system }
            guard let first = notes.first, first.author == user, let meta = ReviewNotes.parseMeta(first.body), meta["kind"] == "finding",
                  let fp = meta["fp"] else { continue }
            let kind: ReviewOutcome.Kind
            let found = (reviewedHead ?? head) == head && stillFound.contains(fp)
            // AKit's own "Looks fixed" reply: a later run checked it gone (AKit never resolves).
            let lookedFixed = notes.contains { $0.author == user && ReviewNotes.parseMeta($0.body)?["kind"] == "reply" }
            if discussion.isResolved {
                let pushedSince = first.position.map { $0.headSHA != head } ?? false
                kind = (pushedSince || lookedFixed) && !found ? .fixed : .dismissed
            } else if lookedFixed, !found {
                kind = .fixed
            } else {
                kind = mergeRequest.state == "merged" ? .ignored : .open
            }
            let replies = notes.dropFirst().filter { $0.author != user }.map { note in
                note.author + ": " + String(SecretFilter.masked(ReviewNotes.withoutMeta(note.body)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            }
            let run = meta["run"]
            result.append(ReviewOutcome(mergeRequest: url, fingerprint: fp, discussionID: discussion.id, role: meta["role"], run: run,
                                        model: run.flatMap { models[$0] } ?? "unknown", kind: kind, replies: replies,
                                        file: first.position?.newPath, line: first.position?.newLine ?? first.position?.oldLine, checked: now))
        }
        return result
    }

    /// The passes' model of each run, by id, as the outcomes name it.
    static func models(home: URL) -> [String: String] {
        Dictionary(ReviewRuns.list(home: home).map { ($0.id, $0.spec.passes.value.model.isEmpty ? "Pi's default" : $0.spec.passes.value.model) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// The outcomes of one run's snapshot against its findings: written on every plan.
    /// `checked`: when GitLab said this (the snapshot's or the sync's time). Outcomes from newer
    /// data are never replaced by older ones; threads the read missed keep their earlier outcome.
    static func write(folder: URL, run: ReviewWorkflow.Run, discussions: [GitLabDiscussion], mergeRequest: GitLabMergeRequest, head: String,
                      user: String, home: URL, checked: Date) throws {
        let file = folder.appending(path: "outcomes.json")
        let existing = ReviewJSON.read([ReviewOutcome].self, from: file) ?? []
        if let newest = existing.map(\.checked).max(), newest > checked { return }
        let still = Set((run.findings?.findings ?? []).filter { !$0.isFixed(on: run.spec.rerun) }.flatMap(\.fingerprints))
        let fresh = compute(discussions: discussions, user: user, mergeRequest: mergeRequest, url: run.spec.mergeRequest.url, head: head,
                            stillFound: still, reviewedHead: run.spec.headSHA, models: models(home: home), now: checked)
        let ids = Set(fresh.map(\.discussionID))
        try ReviewJSON.write(existing.filter { !ids.contains($0.discussionID) } + fresh, to: file)
    }

    /// The latest outcome of every thread, over all runs (a thread is checked again by each run
    /// of its merge request).
    public static func all(home: URL) -> [ReviewOutcome] {
        var latest: [String: ReviewOutcome] = [:]
        for run in ReviewRuns.list(home: home) {
            for outcome in ReviewJSON.read([ReviewOutcome].self, from: ReviewPaths(home: home).run(run.id).appending(path: "outcomes.json")) ?? [] {
                let key = outcome.mergeRequest + "#" + outcome.discussionID
                if let known = latest[key], known.checked >= outcome.checked { continue }
                latest[key] = outcome
            }
        }
        return latest.values.sorted { ($0.mergeRequest, $0.discussionID) < ($1.mergeRequest, $1.discussionID) }
    }

    /// Accepted = fixed / (fixed + dismissed + ignored); open threads don't count yet.
    public struct Rate: Sendable, Hashable {
        public var key: String
        public var fixed = 0
        public var dismissed = 0
        public var ignored = 0
        public var open = 0
        public var accepted: Double? {
            let decided = fixed + dismissed + ignored
            return decided == 0 ? nil : Double(fixed) / Double(decided)
        }
    }

    public static func rates(_ outcomes: [ReviewOutcome]) -> (roles: [Rate], models: [Rate]) {
        func group(_ key: (ReviewOutcome) -> String) -> [Rate] {
            var table: [String: Rate] = [:]
            for outcome in outcomes {
                let name = key(outcome)
                var rate = table[name] ?? Rate(key: name)
                switch outcome.kind {
                case .fixed: rate.fixed += 1
                case .dismissed: rate.dismissed += 1
                case .ignored: rate.ignored += 1
                case .open: rate.open += 1
                }
                table[name] = rate
            }
            return table.values.sorted { $0.key < $1.key }
        }
        return (group { $0.role ?? "?" }, group(\.model))
    }

    /// Sync Outcomes: a short fetch pass reads the merge request and its threads again, and the
    /// run's outcomes are written from that fresh read. Costs one small pass.
    @discardableResult
    public static func sync(folder: URL, env: HarnessEnvironment, options: ReviewPasses.Options = .init()) async throws -> [ReviewOutcome] {
        let run = try ReviewWorkflow.load(folder)
        guard run.spec.local == nil else { throw ReviewPasses.Failure(message: "A local review has no threads in GitLab.") }
        guard let snapshot = run.snapshot else { throw ReviewPasses.Failure(message: "\(run.id) has no GitLab snapshot yet; gather it first.") }
        try await ReviewPasses.sync(folder: folder, spec: run.spec, env: env, options: options)
        let data = ReviewMCPData.read(ReviewMCPData.calls(in: folder).filter { $0.pass.hasPrefix("sync") && run.spec.access.answeredByBase($0) },
                                      iid: run.spec.mergeRequest.iid, project: run.spec.mergeRequest.projectPath)
        guard !data.discussions.isEmpty else {
            throw ReviewPasses.Failure(message: "The sync pass read no threads of \(run.spec.mergeRequest.label)"
                                       + (data.failures.isEmpty ? "." : ": " + data.failures.prefix(3).joined(separator: "; ")))
        }
        let mr = data.mergeRequest ?? snapshot.mergeRequest
        let head = data.mergeRequest.flatMap { $0.diffRefs?.headSHA } ?? run.spec.headSHA ?? ""
        // The user who wrote AKit's threads is the one the run's own fetch read.
        try write(folder: folder, run: run, discussions: data.discussions, mergeRequest: mr, head: head,
                  user: snapshot.user.isEmpty ? (data.user ?? "") : snapshot.user, home: env.homeDirectory, checked: .now)
        return ReviewJSON.read([ReviewOutcome].self, from: folder.appending(path: "outcomes.json")) ?? []
    }
}
