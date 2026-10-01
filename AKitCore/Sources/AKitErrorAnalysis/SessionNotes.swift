import AKitFoundation
import AKitLab
import Foundation

/// Did the session reach the user's goal, judged from what the user saw: their messages and
/// the final state they were told about.
public enum Outcome: String, Codable, Sendable, CaseIterable {
    case achieved, partly, no, unclear

    public var title: String {
        switch self {
        case .achieved: "Achieved"
        case .partly: "Partly"
        case .no: "Not achieved"
        case .unclear: "Unclear"
        }
    }
}

public enum Severity: String, Codable, Sendable, CaseIterable {
    case low, medium, high
}

/// Where a problem comes from. An environment blocker is a fault layer, not a mode.
public enum FaultLayer: String, Codable, Sendable, CaseIterable {
    /// The model's own decisions.
    case agent
    /// CLAUDE.md, skills, hooks, MCP: the setup the user controls.
    case harness
    /// Tools, the machine, the network.
    case environment
    /// The user's request.
    case taskSpec = "task-spec"
    /// Whatever judged the work (rare in real sessions).
    case grader

    public var title: String {
        switch self {
        case .agent: "Agent"
        case .harness: "Harness setup"
        case .environment: "Environment"
        case .taskSpec: "Task spec"
        case .grader: "Grader"
        }
    }
}

/// The verifier's verdict on one note. Rejected notes are kept with the reason and stay out
/// of the pool.
public struct Verdict: Codable, Hashable, Sendable {
    public enum Checker: String, Codable, Sendable {
        /// The quote isn't at the step: decided in code, no model call.
        case code
        case model
    }

    public var accepted: Bool
    public var reason: String
    public var by: Checker
    /// For high-severity notes: the argument "there is no problem here", written first.
    public var steelman: String?

    public init(accepted: Bool, reason: String, by: Checker, steelman: String? = nil) {
        self.accepted = accepted
        self.reason = reason
        self.by = by
        self.steelman = steelman
    }
}

/// One problem seen in one session (open coding), by the model or by the user.
public struct Note: Codable, Hashable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable {
        case model, human
    }

    /// `n1`, `n2`, … within the session (`h1`, … for the user's).
    public var id: String
    public var source: Source
    public var description: String
    /// The transcript step (`#n`) the quote is from.
    public var step: Int
    public var quote: String
    public var severity: Severity?
    public var faultLayer: FaultLayer?
    /// nil = a root problem; else the id of the note it is a symptom of.
    public var symptomOf: String?
    /// What the problem cost, as the model estimated it.
    public var costTokens: Int?
    public var costSteps: Int?
    /// Where in the work it happened. Code derives it from the step; the model may only say
    /// understand or plan, which code can't see.
    public var phase: Phase?
    public var verdict: Verdict?

    public init(id: String, source: Source, description: String, step: Int, quote: String, severity: Severity? = nil,
                faultLayer: FaultLayer? = nil, symptomOf: String? = nil, costTokens: Int? = nil, costSteps: Int? = nil,
                phase: Phase? = nil, verdict: Verdict? = nil) {
        self.id = id
        self.source = source
        self.description = description
        self.step = step
        self.quote = quote
        self.severity = severity
        self.faultLayer = faultLayer
        self.symptomOf = symptomOf
        self.costTokens = costTokens
        self.costSteps = costSteps
        self.phase = phase
        self.verdict = verdict
    }

    /// In the pool: written by the user, or accepted by the verifier.
    public var isAccepted: Bool { source == .human || verdict?.accepted == true }
}

/// The session's first point of deviation, both approximate: shown as "about here".
public struct Deviation: Codable, Hashable, Sendable {
    /// The error that decided the outcome.
    public var decisiveStep: Int?
    /// The first moment the problem became visible in the transcript or to the user.
    public var observedStep: Int?

    public init(decisiveStep: Int? = nil, observedStep: Int? = nil) {
        self.decisiveStep = decisiveStep
        self.observedStep = observedStep
    }
}

/// One improvement: generic advice resting on notes of the session.
public struct Advice: Codable, Hashable, Sendable {
    public var title: String
    public var evidence: String
    public var detail: String
    /// The notes it rests on; advice whose notes were all rejected is dropped.
    public var noteIDs: [String]
    /// Whether a claim about a tool's behaviour was checked by repeating the step. A
    /// one-call review never repeats steps.
    public var checkedByRepeating: Bool

    public init(title: String, evidence: String, detail: String, noteIDs: [String], checkedByRepeating: Bool = false) {
        self.title = title
        self.evidence = evidence
        self.detail = detail
        self.noteIDs = noteIDs
        self.checkedByRepeating = checkedByRepeating
    }
}

/// `notes/<session-key>.json`: one session's review. Re-reviewing replaces it.
public struct SessionNotes: Codable, Hashable, Sendable {
    public var schema = 1
    public var sessionKey: String
    public var transcript: String
    public var title: String?
    public var project: String?
    public var createdAt: Date
    /// The task's requirements, written from the verbatim user turns before any note.
    public var requirements: [String]
    public var outcome: Outcome
    public var notes: [Note]
    public var deviation: Deviation
    public var paragraph: String
    public var advice: [Advice]
    /// Who wrote the notes and who verified them, and the done keys of both steps.
    public var notesConfig: StepConfig
    public var verifierConfig: StepConfig?
    public var doneKeys: [String: String]
    /// Lab run that wrote it, if any.
    public var runID: String?
    /// Where matching routed each accepted note (missing in reviews before matching).
    public var routes: [Route]?

    public init(sessionKey: String, transcript: String, title: String?, project: String?, createdAt: Date = .now,
                requirements: [String], outcome: Outcome, notes: [Note], deviation: Deviation, paragraph: String, advice: [Advice],
                notesConfig: StepConfig, verifierConfig: StepConfig?, doneKeys: [String: String], runID: String?) {
        self.sessionKey = sessionKey
        self.transcript = transcript
        self.title = title
        self.project = project
        self.createdAt = createdAt
        self.requirements = requirements
        self.outcome = outcome
        self.notes = notes
        self.deviation = deviation
        self.paragraph = paragraph
        self.advice = advice
        self.notesConfig = notesConfig
        self.verifierConfig = verifierConfig
        self.doneKeys = doneKeys
        self.runID = runID
    }

    /// Where the session's data came from, for the sending policy of calls over its notes.
    public var origin: SendOrigin { Self.origin(sessionKey: sessionKey, transcript: transcript) }

    /// The route of a note, if matching has routed it.
    public func route(of noteID: String) -> Route? { routes?.first { $0.noteID == noteID } }

    /// Notes in the pool: accepted by the verifier.
    public var accepted: [Note] { notes.filter(\.isAccepted) }
    public var rejected: [Note] { notes.filter { !$0.isAccepted } }
    /// "Checked, no failures": it still counts in denominators.
    public var noFailures: Bool { accepted.isEmpty }
}

/// Where matching sent one note: a mode, a candidate, or "none fits". Matching is a router: it
/// maintains the list of modes and never feeds a frequency.
public struct Route: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// The matching call of a session.
        case matching
        /// Clustering made a candidate mode out of unmatched notes.
        case clustering
        /// Retro-matching of the pool against a newly confirmed mode.
        case retro
        /// The user moved the note.
        case human
    }

    public enum Review: String, Codable, Sendable {
        case accepted, rejected
    }

    public var noteID: String
    /// nil: none of the modes fits.
    public var modeID: String?
    public var confidence: Double
    public var reason: String?
    public var by: Source
    /// The list of modes it was routed against (a hash of their definitions).
    public var modesVersion: String?
    /// The user's verdict, the source of route acceptance.
    public var review: Review?
    public var reviewedAt: Date?

    public init(noteID: String, modeID: String?, confidence: Double, reason: String? = nil, by: Source, modesVersion: String? = nil,
                review: Review? = nil, reviewedAt: Date? = nil) {
        self.noteID = noteID
        self.modeID = modeID
        self.confidence = confidence
        self.reason = reason
        self.by = by
        self.modesVersion = modesVersion
        self.review = review
        self.reviewedAt = reviewedAt
    }
}

/// A note anywhere in the pool: `<session-key>#<note-id>`.
public struct NoteRef: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public var sessionKey: String
    public var noteID: String

    public init(sessionKey: String, noteID: String) {
        self.sessionKey = sessionKey
        self.noteID = noteID
    }

    public init?(parsing text: String) {
        guard let hash = text.lastIndex(of: "#") else { return nil }
        sessionKey = String(text[..<hash])
        noteID = String(text[text.index(after: hash)...])
        guard !sessionKey.isEmpty, !noteID.isEmpty else { return nil }
    }

    public var description: String { "\(sessionKey)#\(noteID)" }

    public static func < (a: NoteRef, b: NoteRef) -> Bool { a.description < b.description }
}
