import AKitFoundation
import Foundation

/// One write AKit may make to GitLab, waiting for the user's decision (R4).
public struct ReviewRequest: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A new inline draft.
        case create
        /// New text for one of AKit's drafts that is still pending.
        case update
        /// One of AKit's pending drafts whose finding is gone.
        case delete
        /// The summary draft (created or updated).
        case summary
        /// "Looks fixed in <sha>" in one of AKit's published threads, as a draft reply.
        case reply
    }

    public enum Decision: String, Codable, Sendable {
        case pending, approved, rejected
    }

    /// Why a finding was rejected at approval (R16).
    public enum Reason: String, Codable, Sendable, CaseIterable {
        case falsePositive = "false-positive"
        case noContext = "no-context"
        case styleNit = "style-nit"
        case wrongAnchor = "wrong-anchor"
        case alreadyHandled = "already-handled"
        case wrongRequirement = "wrong-requirement"
        case outOfScope = "out-of-scope"

        public var title: String {
            switch self {
            case .falsePositive: "False positive"
            case .noContext: "Lacked context"
            case .styleNit: "Style nit"
            case .wrongAnchor: "Wrong line"
            case .alreadyHandled: "Already handled"
            case .wrongRequirement: "Wrong requirement"
            case .outOfScope: "Out of scope"
            }
        }
    }

    public struct Sent: Codable, Sendable, Hashable {
        public var date: Date
        public var draftID: Int?
        /// What GitLab answered when it refused; nil when it worked.
        public var error: String?
    }

    public var id: String
    public var kind: Kind
    public var findingID: String?
    public var fingerprint: String?
    public var role: String?
    public var severity: ReviewSeverity?
    public var confidence: Double?
    public var file: String?
    public var line: Int?
    public var position: GitLabPosition?
    /// The text as AKit wrote it, scrubbed; the hidden meta line is added at sending.
    public var proposed: String
    /// The text the user edited it to; nil = unchanged.
    public var edited: String?
    /// The draft or thread it changes (update, delete, reply, an existing summary).
    public var draftID: Int?
    public var discussionID: String?
    public var decision: Decision = .pending
    public var reason: Reason?
    public var comment: String?
    /// The user moved an "only in AKit" finding inline (label `missed-by-filter`).
    public var movedByUser = false
    public var sent: Sent?
    /// The linked merge request it goes to (`ReviewRunSpec.linked`); nil = the run's first one.
    public var mergeRequest: MergeRequestRef?

    public var text: String { edited ?? proposed }
    public var isSent: Bool { sent != nil && sent?.error == nil }
}

/// Why a finding isn't an inline draft (`docs/design/review.md`, "Where each finding goes").
public struct ReviewPlacement: Codable, Sendable, Hashable {
    public enum Place: String, Codable, Sendable {
        case inline
        /// Confirmed, over the inline cap or not placeable in the diff: one line in the summary.
        case summary
        /// Not enough context: "Questions to the author".
        case question
        /// A row of the acceptance-criteria matrix.
        case matrix
        /// Already raised and resolved by a person: "already dismissed" in the summary.
        case dismissed
        /// Stays in AKit with the reason.
        case onlyInAKit
        /// The problem was there before the merge request (R23): never in GitLab, listed under
        /// "Before this MR" for a task of its own.
        case preExisting
    }

    public var findingID: String
    public var place: Place
    public var reason: String
}

/// `<run>/requests.json`: the requests of the latest plan and where every finding went.
public struct ReviewPlanFile: Codable, Sendable, Hashable {
    public var created: Date
    public var findingsVersion: Int
    public var requests: [ReviewRequest]
    public var placements: [ReviewPlacement]
}

/// Findings → requests by the noise rules (R13) and the rerun rules (R12). Pure: it reads only
/// what it's given, so a run can be planned again (after Discuss in Pi…, or a fresh read of
/// GitLab) and tests can check every rule.
public enum ReviewPlanner {
    public struct Input: Sendable {
        public var spec: ReviewRunSpec
        public var findings: [ReviewFinding]
        public var gaps: [ContextGap]
        public var diffs: [GitLabFileDiff]
        public var refs: GitLabMergeRequest.DiffRefs
        /// The user's draft notes now (AKit's are found by the meta line).
        public var drafts: [GitLabDraft]
        public var discussions: [GitLabDiscussion]
        /// The token's user: a thread is AKit's only when this user wrote it with AKit's line
        /// (anyone can paste the line into their own comment).
        public var user: String
        public var scrub: Scrubber.OwnPatterns
        /// Findings the user moved inline by hand, by id.
        public var forcedInline: Set<String> = []
        /// A rerun's fingerprints of earlier findings it didn't carry, on lines the push didn't
        /// touch (`rerun-kept.json`): their threads aren't fixed.
        public var keptFingerprints: Set<String> = []

        public init(spec: ReviewRunSpec, findings: [ReviewFinding], gaps: [ContextGap], diffs: [GitLabFileDiff],
                    refs: GitLabMergeRequest.DiffRefs, drafts: [GitLabDraft], discussions: [GitLabDiscussion], user: String,
                    scrub: Scrubber.OwnPatterns, forcedInline: Set<String> = [], keptFingerprints: Set<String> = []) {
            self.keptFingerprints = keptFingerprints
            self.spec = spec
            self.findings = findings
            self.gaps = gaps
            self.diffs = diffs
            self.refs = refs
            self.drafts = drafts
            self.discussions = discussions
            self.user = user
            self.scrub = scrub
            self.forcedInline = forcedInline
        }
    }

    public static func plan(_ input: Input, findingsVersion: Int = 1, now: Date = .now) -> ReviewPlanFile {
        let spec = input.spec
        let posting = spec.posting
        var placements: [ReviewPlacement] = []
        var inline: [(finding: ReviewFinding, position: GitLabPosition)] = []
        var overCap: [ReviewFinding] = []
        var questions: [ReviewFinding] = []
        var matrix: [ReviewFinding] = []
        var dismissed: [ReviewFinding] = []

        // AKit's published threads by fingerprint: open or resolved by a person.
        var published: [String: GitLabDiscussion] = [:]
        for discussion in input.discussions {
            guard let first = discussion.notes.first(where: { !$0.system }), first.author == input.user,
                  let meta = ReviewNotes.parseMeta(first.body), meta["kind"] == "finding", let fp = meta["fp"] else { continue }
            published[fp] = discussion
        }
        let ignored = spec.pathInstructions.filter(\.ignore).flatMap(\.paths)

        var inlineCandidates: [(ReviewFinding, GitLabPosition)] = []
        for finding in input.findings {
            func place(_ where_: ReviewPlacement.Place, _ reason: String) {
                placements.append(ReviewPlacement(findingID: finding.id, place: where_, reason: reason))
            }
            let verdict = finding.verifier?.verdict
            if finding.kind == .ac {
                matrix.append(finding)
                place(.matrix, "A row of the acceptance-criteria matrix.")
                continue
            }
            if verdict == .rejected {
                place(.onlyInAKit, "Rejected by the verifier: \(finding.verifier?.note ?? "")")
                continue
            }
            if verdict == .merged {
                place(.onlyInAKit, "Merged into \(finding.verifier?.into ?? "another finding").")
                continue
            }
            if let thread = finding.fingerprints.lazy.compactMap({ published[$0] }).first, thread.isResolved {
                dismissed.append(finding)
                place(.dismissed, "Already raised by AKit and resolved by a person: never raised again.")
                continue
            }
            if finding.isPreExisting, !input.forcedInline.contains(finding.id) {
                place(.preExisting, "Already there before this merge request: not the author's change. Move it inline to post it anyway.")
                continue
            }
            // A rerun (R28) reviews only what changed since the last review; earlier findings carry over.
            if let rerun = spec.rerun, finding.carriedFrom == nil, finding.role != ReviewScan.role, !input.forcedInline.contains(finding.id),
               finding.verifier?.note != ReviewDiscuss.addedNote, !rerun.touches(file: finding.file, line: finding.line) {
                place(.onlyInAKit, "Not on a line changed since the last review (\(rerun.previousHead.prefix(10))): a rerun raises only "
                      + "what the push changed. Move it inline to post it anyway.")
                continue
            }
            // From a commit: the developer asked about the lines after it only.
            if let since = spec.since, finding.carriedFrom == nil, finding.role != ReviewScan.role, !input.forcedInline.contains(finding.id),
               finding.verifier?.note != ReviewDiscuss.addedNote, !since.touches(file: finding.file, line: finding.line) {
                place(.onlyInAKit, "Not on a line changed after \(since.asked): you asked to review only what came after it. "
                      + "Move it inline to post it anyway.")
                continue
            }
            if finding.kind == .question || verdict == .question {
                questions.append(finding)
                place(.question, "Not enough context: a question to the author.")
                continue
            }
            let forced = input.forcedInline.contains(finding.id)
            if !forced {
                guard verdict == .confirmed else {
                    place(.onlyInAKit, "Not confirmed by the verifier.")
                    continue
                }
                guard finding.finalSeverity >= posting.severityThreshold.value else {
                    place(.onlyInAKit, "Severity \(finding.finalSeverity.rawValue) is below \(posting.severityThreshold.value.rawValue).")
                    continue
                }
                guard finding.finalConfidence >= posting.confidenceThreshold.value else {
                    place(.onlyInAKit, String(format: "Confidence %.2f is below %.2f.", finding.finalConfidence, posting.confidenceThreshold.value))
                    continue
                }
            }
            // Checks without a model: the quote must be in the file, and a person's thread on the
            // same lines already says something there.
            if !forced, finding.evidenceFound == false {
                place(.onlyInAKit, "The quoted code isn't in \(finding.file ?? "the file") at the reviewed commit, so the finding can't be tied to the code.")
                continue
            }
            // A secret is reported whatever else is said on those lines or about the path.
            let secret = finding.role == ReviewScan.role
            if !forced, !secret, let author = personThread(near: finding, in: input.discussions, head: spec.headSHA) {
                place(.onlyInAKit, "\(author) already has an open thread on these lines: not raised again. Move it inline to post it anyway.")
                continue
            }
            if !secret, let file = finding.file, ignored.contains(where: { ReviewGlob.matches($0, file) }) {
                place(.onlyInAKit, "\(file) is ignored by the project's path instructions.")
                continue
            }
            guard let position = position(for: finding, diffs: input.diffs, refs: input.refs) else {
                overCap.append(finding)
                place(.summary, finding.file == nil ? "Not tied to a line: in the summary."
                                : "GitLab can't hold a comment there (outside the diff or over its limits): in the summary.")
                continue
            }
            // Inline only on lines the change touches (added, removed, or the context GitLab shows).
            if !forced, !onChangedLine(finding, diffs: input.diffs) {
                overCap.append(finding)
                place(.summary, "Not on a line the change touches: in the summary.")
                continue
            }
            inlineCandidates.append((finding, position))
        }
        // The strongest first, up to the cap; the user's own picks always go inline.
        inlineCandidates.sort { a, b in
            let forcedA = input.forcedInline.contains(a.0.id), forcedB = input.forcedInline.contains(b.0.id)
            if forcedA != forcedB { return forcedA }
            if a.0.finalSeverity != b.0.finalSeverity { return a.0.finalSeverity > b.0.finalSeverity }
            return a.0.finalConfidence > b.0.finalConfidence
        }
        // `medium` has a cap of its own inside the inline cap (R26).
        var taken = 0, takenMedium = 0
        for candidate in inlineCandidates {
            let forced = input.forcedInline.contains(candidate.0.id)
            let medium = candidate.0.finalSeverity <= .medium
            let mediumCap = posting.maxInlineMedium?.value
            if forced || (taken < posting.maxInline.value && !(medium && mediumCap.map { takenMedium >= $0 } == true)) {
                // The user's own picks go inline over the caps, and still take their places in them.
                taken += 1
                if medium { takenMedium += 1 }
                inline.append((candidate.0, candidate.1))
                placements.append(ReviewPlacement(findingID: candidate.0.id, place: .inline,
                                                  reason: forced ? "Moved inline by you." : "Confirmed and over the thresholds."))
            } else {
                overCap.append(candidate.0)
                let reason = taken >= posting.maxInline.value
                    ? "Over the cap of \(posting.maxInline.value) inline comments: one line in the summary."
                    : "Over the cap of \(mediumCap ?? 0) inline comments of medium severity or lower: one line in the summary."
                placements.append(ReviewPlacement(findingID: candidate.0.id, place: .summary, reason: reason))
            }
        }

        // Requests, by the rerun table.
        var requests: [ReviewRequest] = []
        func add(_ request: ReviewRequest) {
            var request = request
            request.id = "r\(requests.count + 1)"
            requests.append(request)
        }
        var ourDrafts: [String: GitLabDraft] = [:]
        var summaryDraft: GitLabDraft?
        for draft in input.drafts {
            guard let meta = ReviewNotes.parseMeta(draft.note) else { continue }
            if meta["kind"] == "summary" { summaryDraft = summaryDraft ?? draft } else if let fp = meta["fp"] { ourDrafts[fp] = draft }
        }
        var kept = Set<String>()
        for (finding, position) in inline {
            let body = scrubbed(inlineBody(finding, spec: spec), scrub: input.scrub)
            var request = ReviewRequest(id: "", kind: .create, findingID: finding.id, fingerprint: finding.fingerprint, role: finding.role,
                                        severity: finding.finalSeverity, confidence: finding.finalConfidence, file: finding.file,
                                        line: finding.line, position: position, proposed: body,
                                        movedByUser: input.forcedInline.contains(finding.id))
            if let fp = finding.fingerprints.first(where: { ourDrafts[$0] != nil }), let draft = ourDrafts[fp] {
                kept.insert(fp)
                // AKit would propose the same text (the user may have edited the draft since) at the
                // same place: nothing to do.
                let same = ReviewNotes.parseMeta(draft.note)?["th"] == ReviewNotes.textHash(body)
                    || ReviewNotes.withoutMeta(draft.note) == body
                guard !same || draft.position?.newLine != position.newLine || draft.position?.oldLine != position.oldLine else { continue }
                request.kind = .update
                request.draftID = draft.id
            } else if finding.fingerprints.contains(where: { published[$0] != nil }) {
                // An open published thread already says it.
                continue
            }
            add(request)
        }
        // From a commit: AKit's drafts and threads off the reviewed lines weren't looked at, so they
        // are neither gone nor fixed.
        func unreviewed(_ position: GitLabPosition?) -> Bool {
            guard let since = spec.since else { return false }
            guard let position else { return true }
            return position.newLine != nil ? !since.touches(file: position.newPath, line: position.newLine)
                : !since.touches(file: position.oldPath, line: nil)
        }
        for (fp, draft) in ourDrafts.sorted(by: { $0.value.id < $1.value.id }) where !kept.contains(fp) && !unreviewed(draft.position) {
            let meta = ReviewNotes.parseMeta(draft.note) ?? [:]
            add(ReviewRequest(id: "", kind: .delete, fingerprint: fp, role: meta["role"], file: draft.position?.newPath,
                              line: draft.position?.newLine ?? draft.position?.oldLine, position: draft.position,
                              proposed: ReviewNotes.withoutMeta(draft.note), draftID: draft.id))
        }
        // Gone means no finding of this run has it, whatever its place: one held back by a threshold
        // is still there. A thread that has AKit's reply already gets no second one.
        // An earlier finding the verifier checked again and rejected (R28) is fixed: gone too.
        let current = Set(input.findings.filter { !$0.isFixed(on: spec.rerun) }.flatMap(\.fingerprints)).union(input.keptFingerprints)
        for (fp, discussion) in published.sorted(by: { $0.key < $1.key }) where !discussion.isResolved && !current.contains(fp)
            && !unreviewed(discussion.notes.first { !$0.system }?.position) {
            let replied = discussion.notes.contains { $0.author == input.user && ReviewNotes.parseMeta($0.body)?["kind"] == "reply" }
            if replied { continue }
            let first = discussion.notes.first { !$0.system }
            add(ReviewRequest(id: "", kind: .reply, fingerprint: fp, role: first.flatMap { ReviewNotes.parseMeta($0.body)?["role"] },
                              file: first?.position?.newPath, line: first?.position?.newLine,
                              proposed: scrubbed("🤖 Zdá se, že je to opraveno v \(spec.headSHA.map { "commitu " + String($0.prefix(10)) } ?? "posledním commitu").",
                                                 scrub: input.scrub),
                              discussionID: discussion.id))
        }
        let summary = scrubbed(summaryBody(spec: spec, inline: inline.map(\.finding), overCap: overCap, questions: questions,
                                           matrix: matrix, dismissed: dismissed, gaps: input.gaps), scrub: input.scrub)
        if let draft = summaryDraft {
            if ReviewNotes.parseMeta(draft.note)?["th"] != ReviewNotes.textHash(summary), ReviewNotes.withoutMeta(draft.note) != summary {
                add(ReviewRequest(id: "", kind: .summary, proposed: summary, draftID: draft.id))
            }
        } else {
            add(ReviewRequest(id: "", kind: .summary, proposed: summary))
        }
        return ReviewPlanFile(created: now, findingsVersion: findingsVersion, requests: requests, placements: placements)
    }

    // MARK: - Positions

    /// The author of a person's open thread (not one of AKit's) within two lines of the finding:
    /// the talk there is still going on. Resolved threads are the prompt's and the verifier's.
    /// Only threads on the reviewed commit: an older version's line numbers point elsewhere.
    static func personThread(near finding: ReviewFinding, in discussions: [GitLabDiscussion], head: String?) -> String? {
        guard let file = finding.file, let line = finding.line else { return nil }
        for discussion in discussions {
            guard !discussion.isResolved, let first = discussion.notes.first(where: { !$0.system }), !ReviewNotes.hasMeta(first.body),
                  let position = first.position, head == nil || position.headSHA == head else { continue }
            let (path, near) = finding.side == .old ? (position.oldPath, position.oldLine) : (position.newPath, position.newLine)
            if path == file, let near, abs(near - line) <= 2 { return first.author }
        }
        return nil
    }

    static func onChangedLine(_ finding: ReviewFinding, diffs: [GitLabFileDiff]) -> Bool {
        guard let file = finding.file, let line = finding.line,
              let diff = diffs.first(where: { $0.newPath == file || $0.oldPath == file }) else { return false }
        return DiffPositions(diff: diff.diff).isInDiff(line, side: finding.side)
    }

    static func position(for finding: ReviewFinding, diffs: [GitLabFileDiff], refs: GitLabMergeRequest.DiffRefs) -> GitLabPosition? {
        guard let file = finding.file, let line = finding.line else { return nil }
        guard let diff = diffs.first(where: { $0.newPath == file || $0.oldPath == file }), !diff.tooLarge else { return nil }
        guard let lines = DiffPositions(diff: diff.diff).lines(for: line, side: finding.side) else { return nil }
        if diff.newFile, lines.new == nil { return nil }
        if diff.deletedFile, lines.old == nil { return nil }
        return GitLabPosition(baseSHA: refs.baseSHA, startSHA: refs.startSHA, headSHA: refs.headSHA, oldPath: diff.oldPath,
                              newPath: diff.newPath, oldLine: diff.newFile ? nil : lines.old, newLine: diff.deletedFile ? nil : lines.new)
    }

    // MARK: - Texts

    // The drafts' own words are Czech: Send lets only Czech go to GitLab (`ReviewLanguage`).

    static func czech(_ severity: ReviewSeverity) -> String {
        switch severity {
        case .critical: "kritická"
        case .high: "vysoká"
        case .medium: "střední"
        case .low: "nízká"
        case .nit: "drobnost"
        }
    }

    /// Every draft passes the scrubber before the Review screen shows it. A scrubbed
    /// suggestion would post a mask as code, so a block that changed loses its code.
    static func scrubbed(_ text: String, scrub: Scrubber.OwnPatterns) -> String {
        var text = text
        if let start = text.range(of: "```suggestion\n"),
           let end = text.range(of: "\n```", range: start.upperBound..<text.endIndex) {
            let code = String(text[start.upperBound..<end.lowerBound])
            if Scrubber.scrub(SecretFilter.masked(code), own: scrub).text != code {
                text.replaceSubrange(start.lowerBound..<end.upperBound, with: "_(Návrh obsahoval tajný údaj, proto byl vynechán.)_")
            }
        }
        return Scrubber.scrub(SecretFilter.masked(text), own: scrub).text
    }

    static func inlineBody(_ finding: ReviewFinding, spec: ReviewRunSpec) -> String {
        var text = "\(spec.posting.marker.value) · `\(finding.role)` · **\(czech(finding.finalSeverity))** · jistota "
            + String(format: "%.2f", finding.finalConfidence).replacingOccurrences(of: ".", with: ",") + "\n\n**\(finding.title)**\n\n\(finding.why)"
        if let suggestion = finding.suggestion, finding.side == .new, !suggestion.contains("```") {
            text += "\n\n```suggestion\n\(suggestion)\n```"
        }
        return text
    }

    static func summaryBody(spec: ReviewRunSpec, inline: [ReviewFinding], overCap: [ReviewFinding], questions: [ReviewFinding],
                            matrix: [ReviewFinding], dismissed: [ReviewFinding], gaps: [ContextGap]) -> String {
        func place(_ finding: ReviewFinding) -> String {
            finding.file.map { "`\($0)" + (finding.line.map { ":\($0)" } ?? "") + "`" } ?? "merge request"
        }
        var text = "\(spec.posting.marker.value) · souhrn · scénář **\(spec.scenario.value)** · role "
            + (spec.roles.map(\.id) + (spec.steps ?? []).map(\.id)).map { "`\($0)`" }.joined(separator: ", ") + "\n\n"
        let count = inline.count
        text += count == 0 ? "Žádné komentáře k řádkům diffu."
            : "\(count) \(count == 1 ? "komentář" : (2...4).contains(count) ? "komentáře" : "komentářů") k řádkům diffu."
        if !overCap.isEmpty {
            text += "\n\n### Další nálezy\n\n" + overCap.map { "- \(place($0)): \($0.title) (`\($0.role)`, \(czech($0.finalSeverity)))" }
                .joined(separator: "\n")
        }
        if !questions.isEmpty {
            text += "\n\n### Otázky pro autora\n\n" + questions.map { finding in
                "- \(place(finding)): \(finding.title)" + (finding.verifier?.note.isEmpty == false ? " — \(finding.verifier!.note)" : "")
            }.joined(separator: "\n")
        }
        if !matrix.isEmpty {
            text += "\n\n### Akceptační kritéria\n\n| Kritérium | Stav |\n|---|---|\n" + matrix.map {
                "| \($0.title.replacingOccurrences(of: "|", with: "\\|")) | \($0.why.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")) |"
            }.joined(separator: "\n")
        }
        if !dismissed.isEmpty {
            text += "\n\n### Už zamítnuté\n\n" + dismissed.map { "- \(place($0)): \($0.title)" }.joined(separator: "\n")
        }
        // Gaps AKit's own Gather found are about this Mac's setup, in English: they stay in AKit.
        let gaps = gaps.filter { $0.reportedBy != "gather" }
        if !gaps.isEmpty {
            text += "\n\n### Co chybělo\n\n" + gaps.map { "- \($0.needed): \($0.why)" }.joined(separator: "\n")
        }
        text += "\n\n<sub>Zkontrolovaný commit \(spec.headSHA.map { String($0.prefix(10)) } ?? "?").</sub>"
        return text
    }
}
