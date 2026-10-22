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

        public init(spec: ReviewRunSpec, findings: [ReviewFinding], gaps: [ContextGap], diffs: [GitLabFileDiff],
                    refs: GitLabMergeRequest.DiffRefs, drafts: [GitLabDraft], discussions: [GitLabDiscussion], user: String,
                    scrub: Scrubber.OwnPatterns, forcedInline: Set<String> = []) {
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
                guard posting.nitpicks.value || finding.finalSeverity != .nit else {
                    place(.onlyInAKit, "A nitpick; nitpicks are off.")
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
            if let file = finding.file, ignored.contains(where: { ReviewGlob.matches($0, file) }) {
                place(.onlyInAKit, "\(file) is ignored by the project's path instructions.")
                continue
            }
            guard let position = position(for: finding, diffs: input.diffs, refs: input.refs) else {
                overCap.append(finding)
                place(.summary, finding.file == nil ? "Not tied to a line: in the summary."
                                : "GitLab can't hold a comment there (outside the diff or over its limits): in the summary.")
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
        for (index, candidate) in inlineCandidates.enumerated() {
            if index < posting.maxInline.value || input.forcedInline.contains(candidate.0.id) {
                inline.append((candidate.0, candidate.1))
                placements.append(ReviewPlacement(findingID: candidate.0.id, place: .inline,
                                                  reason: input.forcedInline.contains(candidate.0.id) ? "Moved inline by you." : "Confirmed and over the thresholds."))
            } else {
                overCap.append(candidate.0)
                placements.append(ReviewPlacement(findingID: candidate.0.id, place: .summary,
                                                  reason: "Over the cap of \(posting.maxInline.value) inline comments: one line in the summary."))
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
        for (fp, draft) in ourDrafts.sorted(by: { $0.value.id < $1.value.id }) where !kept.contains(fp) {
            let meta = ReviewNotes.parseMeta(draft.note) ?? [:]
            add(ReviewRequest(id: "", kind: .delete, fingerprint: fp, role: meta["role"], file: draft.position?.newPath,
                              line: draft.position?.newLine ?? draft.position?.oldLine, position: draft.position,
                              proposed: ReviewNotes.withoutMeta(draft.note), draftID: draft.id))
        }
        // Gone means no finding of this run has it, whatever its place: one held back by a threshold
        // is still there. A thread that has AKit's reply already gets no second one.
        let current = Set(input.findings.flatMap(\.fingerprints))
        for (fp, discussion) in published.sorted(by: { $0.key < $1.key }) where !discussion.isResolved && !current.contains(fp) {
            let replied = discussion.notes.contains { $0.author == input.user && ReviewNotes.parseMeta($0.body)?["kind"] == "reply" }
            if replied { continue }
            let first = discussion.notes.first { !$0.system }
            add(ReviewRequest(id: "", kind: .reply, fingerprint: fp, role: first.flatMap { ReviewNotes.parseMeta($0.body)?["role"] },
                              file: first?.position?.newPath, line: first?.position?.newLine,
                              proposed: scrubbed("🤖 Looks fixed in \(spec.headSHA.map { String($0.prefix(10)) } ?? "the latest commit").",
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

    /// Every draft passes the scrubber before the Review screen shows it. A scrubbed
    /// suggestion would post a mask as code, so a block that changed loses its code.
    static func scrubbed(_ text: String, scrub: Scrubber.OwnPatterns) -> String {
        var text = text
        if let start = text.range(of: "```suggestion\n"),
           let end = text.range(of: "\n```", range: start.upperBound..<text.endIndex) {
            let code = String(text[start.upperBound..<end.lowerBound])
            if Scrubber.scrub(SecretFilter.masked(code), own: scrub).text != code {
                text.replaceSubrange(start.lowerBound..<end.upperBound, with: "_(The suggestion held a secret and was left out.)_")
            }
        }
        return Scrubber.scrub(SecretFilter.masked(text), own: scrub).text
    }

    static func inlineBody(_ finding: ReviewFinding, spec: ReviewRunSpec) -> String {
        var text = "\(spec.posting.marker.value) · `\(finding.role)` · **\(finding.finalSeverity.rawValue)** · confidence "
            + String(format: "%.2f", finding.finalConfidence) + "\n\n**\(finding.title)**\n\n\(finding.why)"
        if let suggestion = finding.suggestion, finding.side == .new, !suggestion.contains("```") {
            text += "\n\n```suggestion\n\(suggestion)\n```"
        }
        return text
    }

    static func summaryBody(spec: ReviewRunSpec, inline: [ReviewFinding], overCap: [ReviewFinding], questions: [ReviewFinding],
                            matrix: [ReviewFinding], dismissed: [ReviewFinding], gaps: [ContextGap]) -> String {
        func place(_ finding: ReviewFinding) -> String {
            finding.file.map { "`\($0)" + (finding.line.map { ":\($0)" } ?? "") + "`" } ?? "the merge request"
        }
        var text = "\(spec.posting.marker.value) · summary · scenario **\(spec.scenario.value)** · roles "
            + (spec.roles.map(\.id) + (spec.steps ?? []).map(\.id)).map { "`\($0)`" }.joined(separator: ", ") + "\n\n"
        text += inline.isEmpty ? "No inline comments." : "\(inline.count) inline comment\(inline.count == 1 ? "" : "s") on the diff."
        if !overCap.isEmpty {
            text += "\n\n### More findings\n\n" + overCap.map { "- \(place($0)): \($0.title) (`\($0.role)`, \($0.finalSeverity.rawValue))" }
                .joined(separator: "\n")
        }
        if !questions.isEmpty {
            text += "\n\n### Questions to the author\n\n" + questions.map { finding in
                "- \(place(finding)): \(finding.title)" + (finding.verifier?.note.isEmpty == false ? " — \(finding.verifier!.note)" : "")
            }.joined(separator: "\n")
        }
        if !matrix.isEmpty {
            text += "\n\n### Acceptance criteria\n\n| Criterion | Status |\n|---|---|\n" + matrix.map {
                "| \($0.title.replacingOccurrences(of: "|", with: "\\|")) | \($0.why.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")) |"
            }.joined(separator: "\n")
        }
        if !dismissed.isEmpty {
            text += "\n\n### Already dismissed\n\n" + dismissed.map { "- \(place($0)): \($0.title)" }.joined(separator: "\n")
        }
        if !gaps.isEmpty {
            text += "\n\n### What was missing\n\n" + gaps.map { "- \($0.needed): \($0.why)" }.joined(separator: "\n")
        }
        text += "\n\n<sub>Reviewed commit \(spec.headSHA.map { String($0.prefix(10)) } ?? "?").</sub>"
        return text
    }
}
