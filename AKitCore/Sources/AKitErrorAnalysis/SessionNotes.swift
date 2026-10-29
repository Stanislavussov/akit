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

/// Why something went wrong, from a fixed list, so a review names a cause instead of retelling
/// the session (`docs/design/error-analysis.md`, "Diagnosis"). The model picks the deepest one
/// the transcript shows: `weakModel` only when the task, the context and the setup were fine.
public enum RootCause: String, Codable, Sendable, CaseIterable {
    /// The request lacked what the agent needed, or changed later.
    case unclearTask = "unclear-task"
    /// The request or a rule was clear, and the agent did something else.
    case ignoredInstruction = "ignored-instruction"
    /// The agent didn't read or look up what it needed (code, docs, the current state).
    case missingContext = "missing-context"
    /// No skill, rule or doc in the setup gave the knowledge this task needed.
    case missingSkill = "missing-skill"
    /// A skill, rule, CLAUDE.md or AGENTS.md led the agent the wrong way.
    case wrongSkill = "wrong-skill"
    /// Invented APIs, files or facts, or claimed work or checks that didn't happen.
    case hallucination
    /// No test, build or check before saying "done", or a failed check ignored.
    case noVerification = "no-verification"
    /// Clear task, right context, fitting setup, and still wrong reasoning or no solution.
    case weakModel = "weak-model"
    /// A tool, the machine or the network failed.
    case toolEnvironment = "tool-environment"
    /// Did more than asked, or something else than asked.
    case scopeDrift = "scope-drift"
    /// Nothing went wrong here.
    case none

    public var title: String {
        switch self {
        case .unclearTask: "Unclear task"
        case .ignoredInstruction: "Ignored instruction"
        case .missingContext: "Missing context"
        case .missingSkill: "Missing skill or rule"
        case .wrongSkill: "Misleading skill or rule"
        case .hallucination: "Hallucination"
        case .noVerification: "No verification"
        case .weakModel: "Weak model"
        case .toolEnvironment: "Tool or environment"
        case .scopeDrift: "Scope drift"
        case .none: "No problem"
        }
    }

    /// A model's value, read leniently: `unclear_task` and `Unclear-Task` count; anything else is nil.
    static func parse(_ text: String?) -> RootCause? {
        guard let text else { return nil }
        return RootCause(rawValue: text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "-"))
    }

    /// What usually fixes this cause: the kind of change, for the reader who skims.
    public var fixKind: String {
        switch self {
        case .unclearTask: "Say more in the request: goal, limits, how to check it."
        case .ignoredInstruction: "Make the rule shorter and louder, or enforce it with a hook."
        case .missingContext: "Point the agent at the code or docs to read first."
        case .missingSkill: "Add a skill or a rule with the missing knowledge."
        case .wrongSkill: "Fix or remove the skill or rule that misled the agent."
        case .hallucination: "Ask for evidence: run it, show the output, cite the file."
        case .noVerification: "Require a test or check before \"done\" (rule or hook)."
        case .weakModel: "Use a stronger model or split the task into smaller steps."
        case .toolEnvironment: "Fix the tool or the machine; it isn't the agent's fault."
        case .scopeDrift: "State the scope and what not to touch."
        case .none: ""
        }
    }
}

/// The review in one look: the main problem, its cause, why it happened and the one fix.
public struct Diagnosis: Codable, Hashable, Sendable {
    /// One plain sentence: what went wrong (or that nothing did).
    public var headline: String
    public var cause: RootCause
    /// The chain: what the user wanted → what the agent thought → what it did.
    public var why: String
    /// The one change worth making.
    public var fix: String
    /// The steps that prove it.
    public var steps: [Int]

    public init(headline: String, cause: RootCause, why: String, fix: String, steps: [Int] = []) {
        self.headline = headline
        self.cause = cause
        self.why = why
        self.fix = fix
        self.steps = steps
    }
}

/// The review's reading of one user reaction: what the user wanted there, what the agent did and
/// thought before it, and why it went that way.
public struct Checkpoint: Codable, Hashable, Sendable {
    /// The reaction's id (`r1`, …).
    public var id: String
    public var wanted: String
    public var agentDid: String
    /// From the agent's thinking and text before the reaction; "not visible" when the log
    /// doesn't show it.
    public var agentThought: String
    public var cause: RootCause
    public var fix: String?

    public init(id: String, wanted: String, agentDid: String, agentThought: String, cause: RootCause, fix: String? = nil) {
        self.id = id
        self.wanted = wanted
        self.agentDid = agentDid
        self.agentThought = agentThought
        self.cause = cause
        self.fix = fix
    }
}

/// A run of attempts that kept failing the same way, and where it really started.
public struct Loop: Codable, Hashable, Sendable {
    public var fromStep: Int
    public var toStep: Int
    /// What repeated, and how many times.
    public var what: String
    /// The step whose decision caused the loop (often before `fromStep`).
    public var rootStep: Int?
    public var cause: RootCause

    public init(fromStep: Int, toStep: Int, what: String, rootStep: Int? = nil, cause: RootCause) {
        self.fromStep = fromStep
        self.toStep = toStep
        self.what = what
        self.rootStep = rootStep
        self.cause = cause
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
    /// Why it happened (notes prompt 2 on); nil in older reviews and the user's notes.
    public var cause: RootCause?
    public var verdict: Verdict?

    public init(id: String, source: Source, description: String, step: Int, quote: String, severity: Severity? = nil,
                faultLayer: FaultLayer? = nil, symptomOf: String? = nil, costTokens: Int? = nil, costSteps: Int? = nil,
                phase: Phase? = nil, cause: RootCause? = nil, verdict: Verdict? = nil) {
        self.cause = cause
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

    public init(title: String, evidence: String, detail: String, noteIDs: [String]) {
        self.title = title
        self.evidence = evidence
        self.detail = detail
        self.noteIDs = noteIDs
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
    /// What happened, written with the notes, before the verifier: it may still mention a
    /// note the verifier rejected.
    public var paragraph: String
    /// The review's conclusion in one or two plain sentences, written by the verifier from the
    /// notes it accepted; nil before verifier prompt 3, when no note reached the verifier, or
    /// when the verifier left it blank.
    public var conclusion: String?
    public var advice: [Advice]
    /// The user's reactions found by code: the checkpoints the review explains (notes prompt 2
    /// on; nil in older reviews).
    public var reactions: [UserReaction]?
    /// The main problem and its cause, written with the notes.
    public var diagnosis: Diagnosis?
    /// The verifier's doubt about the diagnosis: nil when it holds or wasn't checked.
    public var diagnosisDoubt: String?
    /// One reading per reaction, by its id.
    public var checkpoints: [Checkpoint]?
    public var loops: [Loop]?
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

    /// The diagnosis as plain text for the run's summary and log: "Cause: … — headline", why, fix.
    public var diagnosisText: String? {
        guard let diagnosis else { return nil }
        var lines = ["\(diagnosis.cause.title): \(diagnosis.headline)"]
        if !diagnosis.why.isEmpty { lines.append("Why: \(diagnosis.why)") }
        if !diagnosis.fix.isEmpty { lines.append("Fix: \(diagnosis.fix)") }
        if let diagnosisDoubt { lines.append("The verifier doubts it: \(diagnosisDoubt)") }
        return lines.joined(separator: "\n")
    }

    /// The checkpoint of a reaction, if the review wrote one.
    public func checkpoint(of reaction: UserReaction) -> Checkpoint? {
        checkpoints?.first { $0.id == reaction.id }
    }

    /// Where the session's data came from, for the sending policy of calls over its notes.
    public var origin: SendOrigin { Self.origin(sessionKey: sessionKey, transcript: transcript) }

    /// Notes in the pool: accepted by the verifier.
    public var accepted: [Note] { notes.filter(\.isAccepted) }
    public var rejected: [Note] { notes.filter { !$0.isAccepted } }
    /// "Checked, no failures": it still counts in denominators.
    public var noFailures: Bool { accepted.isEmpty }

    /// Each routed note's mode as the mode pages count it: the current route
    /// (`Matching.currentRoutes`), merges followed. nil mode: "none fits". Unconfirmed: a
    /// low-confidence route the user hasn't reviewed, which "seen in k notes" leaves out.
    public func noteModes(_ modes: [Mode]) -> [String: (modeID: String?, confirmed: Bool)] {
        Matching.currentRoutes(self).mapValues { route in
            (route.modeID.map { ModeStore.resolve($0, in: modes) },
             route.review != nil || route.by == .human || route.confidence >= Matching.lowConfidence)
        }
    }
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
    /// The Lab run whose matching made it: a batch counts only its own routes as matches.
    public var runID: String?

    public init(noteID: String, modeID: String?, confidence: Double, reason: String? = nil, by: Source, modesVersion: String? = nil,
                review: Review? = nil, reviewedAt: Date? = nil, runID: String? = nil) {
        self.runID = runID
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
