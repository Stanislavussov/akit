import AKitFoundation
import Foundation

/// One problem a role found (`docs/design/review.md`, "Findings"). The model fills it through
/// `akit_submit_findings`; AKit checks it and adds the fingerprint.
public struct ReviewFinding: Codable, Sendable, Hashable, Identifiable {
    public enum Side: String, Codable, Sendable { case new, old }

    /// `finding`: a problem in the code. `ac`: a row of the acceptance-criteria matrix
    /// (requirements role). `question`: something to ask the author.
    public enum Kind: String, Codable, Sendable { case finding, ac, question }

    public struct Verdict: Codable, Sendable, Hashable {
        public enum Value: String, Codable, Sendable, CaseIterable { case confirmed, rejected, question, merged }
        public var verdict: Value
        public var note: String
        /// For `merged`: the finding it went into.
        public var into: String?
        /// The verifier's own severity and confidence, when it changed them.
        public var severity: ReviewSeverity?
        public var confidence: Double?
        /// The verifier's say on whether the problem was there before the merge request.
        public var preExisting: Bool?

        public init(verdict: Value, note: String, into: String? = nil, severity: ReviewSeverity? = nil, confidence: Double? = nil,
                    preExisting: Bool? = nil) {
            self.verdict = verdict
            self.note = note
            self.into = into
            self.severity = severity
            self.confidence = confidence
            self.preExisting = preExisting
        }
    }

    public var id: String
    public var kind: Kind
    public var role: String
    public var file: String?
    public var side: Side
    public var line: Int?
    public var title: String
    public var evidence: String
    public var why: String
    public var severity: ReviewSeverity
    public var confidence: Double
    public var suggestion: String?
    public var related: [String]
    public var verifier: Verdict?
    /// Hash of the path and the anchor snippet, plus the title when there is no line to anchor
    /// to (`ReviewFingerprint`); set by AKit.
    public var fingerprint: String?
    /// The fingerprint by the first rule (always with the title), so drafts and threads written
    /// before the change still match. Nil when it is the same as `fingerprint`.
    public var previousFingerprint: String?
    /// Fingerprints of findings folded into this one (the same lines), so their drafts and
    /// threads still count as found.
    public var foldedFingerprints: [String]?
    /// Whether the quoted evidence is in the file at the reviewed commit; nil when AKit can't
    /// tell (a removed line, no worktree, no quote). Set by AKit.
    public var evidenceFound: Bool?
    /// The problem is already there at the base commit: the change didn't bring it (R23). It
    /// never goes to GitLab; the Review screen lists it under "Before this MR".
    public var preExisting: Bool?
    /// The earlier run this finding comes from in a rerun (R28): carried over, or checked again
    /// by the verifier. nil for a finding of this run's roles.
    public var carriedFrom: String?

    public init(id: String, kind: Kind = .finding, role: String, file: String?, side: Side = .new, line: Int?, title: String,
                evidence: String, why: String, severity: ReviewSeverity, confidence: Double, suggestion: String? = nil,
                related: [String] = [], verifier: Verdict? = nil, fingerprint: String? = nil) {
        self.id = id
        self.kind = kind
        self.role = role
        self.file = file
        self.side = side
        self.line = line
        self.title = title
        self.evidence = evidence
        self.why = why
        self.severity = severity
        self.confidence = confidence
        self.suggestion = suggestion
        self.related = related
        self.verifier = verifier
        self.fingerprint = fingerprint
    }

    /// Every fingerprint a draft or a thread of this finding may carry.
    public var fingerprints: [String] { [fingerprint, previousFingerprint].compactMap { $0 } + (foldedFingerprints ?? []) }

    /// The severity and confidence after the verifier.
    public var finalSeverity: ReviewSeverity { verifier?.severity ?? severity }
    public var finalConfidence: Double { verifier?.confidence ?? confidence }
    /// Whether the problem was there before the merge request, the verifier's say first.
    public var isPreExisting: Bool { verifier?.preExisting ?? preExisting ?? false }
}

/// Something the agent needed and the context pack didn't have (`akit_report_context_gap`),
/// or something Gather couldn't get.
public struct ContextGap: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// gitlab, azure-devops, repository, knowledge, tests, other.
    public var system: String
    public var needed: String
    public var why: String
    public var howToGet: String
    /// How the missing piece lowers confidence: which findings or checks it affects.
    public var effect: String
    /// `gather`, or the pass that reported it.
    public var reportedBy: String

    public init(id: String, system: String, needed: String, why: String, howToGet: String = "", effect: String = "", reportedBy: String) {
        self.id = id
        self.system = system
        self.needed = needed
        self.why = why
        self.howToGet = howToGet
        self.effect = effect
        self.reportedBy = reportedBy
    }
}

/// Fingerprint = hash of the path and the anchor snippet (±2 lines, whitespace normalized).
/// Not the line number, so it survives shifts; not the role, so one problem from two roles is
/// one finding (R12); not the title, which a model words differently on each run. Without lines
/// of the file (no checkout, an acceptance criterion) the normalized title is part of it.
public enum ReviewFingerprint {
    public static func make(path: String, snippet: String, title: String?) -> String {
        let text = "\(path)\n\(normalize(snippet))" + (title.map { "\n\(normalizeTitle($0))" } ?? "")
        return String(Checksum.sha256(Data(text.utf8)).prefix(16))
    }

    /// Lines `line-2 … line+2` of `fileLines` (1-based), nil when the line is outside.
    public static func snippet(_ fileLines: [String], line: Int, radius: Int = 2) -> String? {
        guard line >= 1, line <= fileLines.count else { return nil }
        let start = max(1, line - radius)
        let end = min(fileLines.count, line + radius)
        return fileLines[(start - 1)..<end].joined(separator: "\n")
    }

    static func normalize(_ snippet: String) -> String {
        snippet.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func normalizeTitle(_ title: String) -> String {
        title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map(String.init).joined()
            .split(separator: " ").joined(separator: " ")
    }
}
