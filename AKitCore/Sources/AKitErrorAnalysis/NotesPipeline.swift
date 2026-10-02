import AKitFoundation
import AKitLab
import AKitModel
import AKitSessions
import Foundation

/// Step 1 and the verifier for one session: blind notes, then a check of every quote in code
/// and of every claim by a second call. Only accepted notes enter the pool
/// (`docs/design/error-analysis.md`, "Step 1" and "Verifier").
public enum NotesPipeline {
    /// The session to review.
    public struct Target: Sendable {
        public var harness: HarnessID
        public var file: URL
        public var title: String?
        public var project: URL?

        public init(harness: HarnessID, file: URL, title: String? = nil, project: URL? = nil) {
            self.harness = harness
            self.file = file
            self.title = title
            self.project = project
        }

        public var summary: SessionSummary {
            let info = JSONLines.fileInfo(file)
            return SessionSummary(harness: harness, file: file, title: title ?? file.deletingPathExtension().lastPathComponent,
                                  project: project, started: nil, modified: info.modified, size: info.size)
        }
    }

    /// Who writes the notes and who verifies them. One default model for both; another
    /// replaces it only when validation shows it is better.
    public struct Config: Sendable {
        public var notes: LabAgent
        public var verifier: LabAgent
        public var language: LabLanguage

        public init(notes: LabAgent, verifier: LabAgent? = nil, language: LabLanguage = .english) {
            self.notes = notes
            self.verifier = verifier ?? notes
            self.language = language
        }

        var notesStep: StepConfig {
            StepConfig(step: "notes", harness: notes.harness.rawValue, model: notes.model, promptVersion: NotesPrompts.notesVersion,
                       scrubVersion: Scrubber.version, codeVersion: nil, extra: ["effort": notes.effort, "language": language.rawValue])
        }

        var verifierStep: StepConfig {
            StepConfig(step: "verifier", harness: verifier.harness.rawValue, model: verifier.model,
                       promptVersion: NotesPrompts.verifierVersion, scrubVersion: Scrubber.version, codeVersion: nil,
                       extra: ["effort": verifier.effort, "language": language.rawValue])
        }
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Reviews one session and saves `notes/<session-key>.json`, replacing an earlier review.
    /// A step whose done key is already there is skipped.
    @discardableResult
    public static func review(_ target: Target, config: Config, notesGate: SendGate, verifierGate: SendGate, runID: String?,
                              workFolder: URL, env: HarnessEnvironment, out: @escaping @Sendable (String) -> Void) async throws -> SessionNotes {
        guard let key = SessionKey.of(target.summary) else {
            throw Failure(message: "AKit can't name the session in \(target.file.path).")
        }
        let origin = SendOrigin.of(harness: target.harness, sessionFile: target.file)
        var (items, scrubbedCounts) = try scrubbedItems(target, gate: notesGate)
        let numbers = numbers(of: target, gate: notesGate)
        if let numbers { scrubbedCounts.merge(numbers.counts, uniquingKeysWith: +) }
        // The key holds what the notes call sends that comes from the session: the scrubbed
        // transcript and AKit's numbers, both computed from the transcript alone, so a Lab
        // review and a batch share notes.
        var input = Data(items.map { "[#\($0.id)] \($0.text)" }.joined(separator: "\n").utf8)
        if let numbers { input.append(Data("\n## AKit's numbers\n\(numbers.text)".utf8)) }
        let notesKey = DoneKey.make(input: input, configs: [config.notesStep])
        let verifierKey = DoneKey.make(input: input, configs: [config.notesStep, config.verifierStep])
        let store = NotesStore(env: env)
        let earlier = store.load(key.description)

        var draft: SessionNotes
        if let earlier, earlier.doneKeys["notes"] == notesKey {
            out("Notes for this session and model are already there; reusing them.")
            draft = earlier
        } else {
            out("Writing notes with \(config.notes.label)…")
            var request = ModelCall.Request(agent: config.notes, purpose: "notes", system: NotesPrompts.notesSystem + "\n" + config.language.instruction,
                                            input: try notesInput(numbers: numbers?.text, items: items, model: config.notes.model),
                                            schema: NotesPrompts.notesSchema, origin: origin, session: key.description, runID: runID)
            request.scrubbed = scrubbedCounts
            let answer = try await ModelCall.run(request, gate: notesGate, folder: workFolder, env: env)
            draft = try parseNotes(answer.text, items: items)
            draft.sessionKey = key.description
            draft.transcript = target.file.path
            draft.title = target.title
            draft.project = target.project?.path
            draft.notesConfig = config.notesStep
            draft.doneKeys = ["notes": notesKey]
            draft.runID = runID
        }

        if draft.doneKeys["verifier"] != verifierKey {
            draft = try await verify(draft, items: items, config: config, gate: verifierGate, origin: origin, runID: runID,
                                     workFolder: workFolder, env: env, out: out)
            draft.verifierConfig = config.verifierStep
            draft.doneKeys["verifier"] = verifierKey
            // The conclusion is this run's: the run that verified last owns the review.
            draft.runID = runID
        }
        try store.saveReview(draft)
        return store.load(key.description) ?? draft
    }

    /// The transcript as the model sees it: the session readers' masking, then the scrub with
    /// the user's own patterns. Quotes are matched against exactly this text.
    static func scrubbedItems(_ target: Target, gate: SendGate) throws -> (items: [TranscriptItem], counts: [String: Int]) {
        let transcript = try SessionReader.transcript(of: target.summary)
        var counts: [String: Int] = [:]
        let items = transcript.items.map { item -> TranscriptItem in
            let result = gate.scrub(item.text)
            counts.merge(result.counts, uniquingKeysWith: +)
            return TranscriptItem(id: item.id, kind: item.kind, text: result.text, timestamp: item.timestamp)
        }
        return (items, counts)
    }

    /// AKit's numbers for the notes call: the metrics of a Claude Code transcript (calls,
    /// tokens, errors, commits), scrubbed like the transcript; nil for other harnesses. From
    /// the transcript alone: whether a commit reached the main branch is left out, it changes
    /// with the repository, not with the session, and isn't in the log.
    static func numbers(of target: Target, gate: SendGate) -> (text: String, counts: [String: Int])? {
        guard target.harness == .claudeCode, let metrics = try? SessionAnalyzer.analyze(file: target.file),
              let json = try? LabStore.encoder.encode(metrics) else { return nil }
        let result = gate.scrub(String(decoding: json, as: UTF8.self))
        return (result.text, result.counts)
    }

    /// Why a session isn't sent in one `call`: its user turns and failed tool results alone pass
    /// `budget`. `BatchRunner.isTooLong` knows the message by its start.
    static func tooLong(call: String, budget: Int, model: String, caller: String) -> String {
        "The session is too long for one \(call): its user turns and failed tool results alone pass the "
            + "\(budget)-character budget of \(model.isEmpty ? "the default model" : model), so it isn't sent."
            + (budget < EvidenceDigest.largeBudget ? " A \(caller) with a 1M-token window may have room for it." : "")
    }

    /// The notes call's input: AKit's numbers and the transcript digest. The title isn't sent:
    /// callers know it or not, and the transcript's own user turns say what the session was.
    /// Refuses a session whose user turns and failed tool results alone pass the model's
    /// budget: they are never cut, and a call over the budget may not fit the window.
    static func notesInput(numbers: String?, items: [TranscriptItem], model: String) throws -> String {
        let budget = EvidenceDigest.budget(model: model)
        let digest = EvidenceDigest.text(SessionTranscript(items: items), budget: budget)
        guard !digest.overBudget else { throw Failure(message: tooLong(call: "call", budget: budget, model: model, caller: "model")) }
        let facts = numbers.map { "## AKit's numbers (computed from the transcript; trust them)\n\n\($0)\n\n" } ?? ""
        return """
            # Session

            \(facts)## Transcript digest

            \(digest.text)

            """
    }

    // MARK: Step 1

    struct NotesAnswer: Decodable {
        struct RawNote: Decodable {
            let id: String
            let description: String
            let step: Int
            let quote: String
            let severity: Severity?
            let faultLayer: FaultLayer?
            let symptomOf: String?
            let costSteps: Int?
            let costTokens: Int?
            let phase: Phase?
        }

        struct RawAdvice: Decodable {
            let title: String
            let evidence: String?
            let detail: String
            let noteIds: [String]?
        }

        let requirements: [String]
        let outcome: Outcome
        let notes: [RawNote]
        let decisiveStep: Int?
        let observedStep: Int?
        let paragraph: String
        let advice: [RawAdvice]
    }

    /// The model's answer as notes. Phases come from code; the model may only say understand
    /// or plan. Invalid output is an error, never an empty review.
    static func parseNotes(_ text: String, items: [TranscriptItem]) throws -> SessionNotes {
        guard let json = ModelCall.jsonObject(in: text), let answer = try? JSONDecoder().decode(NotesAnswer.self, from: json) else {
            throw Failure(message: "The notes answer isn't the JSON asked for.")
        }
        let phases = PhaseClassifier.phases(of: items)
        var seen = Set<String>()
        let notes = answer.notes.enumerated().map { index, raw -> Note in
            // Ids must be unique: advice and symptoms point at them.
            let id = seen.insert(raw.id).inserted ? raw.id : "n\(index + 1)-\(UUID().uuidString.prefix(4))"
            let modelPhase = raw.phase.flatMap { [.understand, .plan].contains($0) ? $0 : nil }
            return Note(id: id, source: .model, description: SecretFilter.masked(raw.description), step: raw.step,
                        quote: SecretFilter.masked(raw.quote), severity: raw.severity, faultLayer: raw.faultLayer,
                        symptomOf: raw.symptomOf.flatMap { $0.isEmpty ? nil : $0 }, costTokens: raw.costTokens,
                        costSteps: raw.costSteps, phase: modelPhase ?? phases[raw.step])
        }
        let advice = answer.advice.prefix(3).map {
            Advice(title: SecretFilter.masked($0.title), evidence: SecretFilter.masked($0.evidence ?? ""),
                   detail: SecretFilter.masked($0.detail), noteIDs: $0.noteIds ?? [])
        }
        return SessionNotes(sessionKey: "", transcript: "", title: nil, project: nil,
                            requirements: answer.requirements.map(SecretFilter.masked), outcome: answer.outcome, notes: notes,
                            deviation: Deviation(decisiveStep: answer.decisiveStep, observedStep: answer.observedStep),
                            paragraph: SecretFilter.masked(answer.paragraph.trimmingCharacters(in: .whitespacesAndNewlines)),
                            advice: Array(advice), notesConfig: StepConfig(step: "notes"), verifierConfig: nil, doneKeys: [:], runID: nil)
    }

    // MARK: Verifier

    /// Quotes first, in code, against the full scrubbed transcript; then one call for the claims
    /// whose quotes were found, which also writes the conclusion. Advice whose notes are all
    /// rejected is dropped.
    static func verify(_ notes: SessionNotes, items: [TranscriptItem], config: Config, gate: SendGate, origin: SendOrigin, runID: String?,
                       workFolder: URL, env: HarnessEnvironment, out: @escaping @Sendable (String) -> Void) async throws -> SessionNotes {
        var result = notes
        // Reused notes carry the verdicts of an earlier verifier: this one decides afresh.
        for index in result.notes.indices where result.notes[index].source == .model { result.notes[index].verdict = nil }
        result.conclusion = nil
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var toAsk: [Note] = []
        for index in result.notes.indices where result.notes[index].source == .model {
            let note = result.notes[index]
            // One long part anchors the quote in its step, and the others must follow it there;
            // "error … ok" is two words that match almost anywhere.
            if (QuoteMatcher.parts(of: note.quote).map(\.count).max() ?? 0) < minimumQuote {
                result.notes[index].verdict = Verdict(accepted: false, reason: "The quote is too short to show anything.", by: .code)
            } else if let item = byID[note.step], QuoteMatcher.matches(quote: note.quote, in: item.text) {
                toAsk.append(note)
            } else {
                result.notes[index].verdict = Verdict(accepted: false, reason: byID[note.step] == nil
                                                      ? "There is no step #\(note.step)."
                                                      : "The quote isn't in step #\(note.step).", by: .code)
            }
        }
        if !toAsk.isEmpty {
            out("Verifying \(toAsk.count) notes with \(config.verifier.label)…")
            let answer = try await ModelCall.run(
                ModelCall.Request(agent: config.verifier, purpose: "verifier",
                                  system: NotesPrompts.verifierSystem + "\nWrite the conclusion in \(config.language.name).",
                                  input: verifierInput(toAsk, items: items, byID: byID, review: result), schema: NotesPrompts.verifierSchema,
                                  origin: origin, session: notes.sessionKey, runID: runID),
                gate: gate, folder: workFolder, env: env)
            let parsed = try parseVerifier(answer.text)
            let verdicts = parsed.verdicts
            result.conclusion = parsed.conclusion.map(SecretFilter.masked)
            for index in result.notes.indices where result.notes[index].verdict == nil && result.notes[index].source == .model {
                let id = result.notes[index].id
                guard let verdict = verdicts[id] else {
                    result.notes[index].verdict = Verdict(accepted: false, reason: "The verifier gave no verdict.", by: .model)
                    continue
                }
                let high = result.notes[index].severity == .high
                if high, (verdict.steelman ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    result.notes[index].verdict = Verdict(accepted: false, reason: "No steelman for a high-severity note.", by: .model)
                } else {
                    result.notes[index].verdict = Verdict(accepted: verdict.supported, reason: SecretFilter.masked(verdict.reason),
                                                          by: .model, steelman: verdict.steelman.map(SecretFilter.masked))
                }
            }
        }
        let accepted = Set(result.accepted.map(\.id))
        result.advice = result.advice.filter { !Set($0.noteIDs).isDisjoint(with: accepted) }
        let kept = result.accepted.count
        out("Verifier: \(kept) of \(result.notes.count) notes accepted.")
        return result
    }

    /// A quote this short ("null", "ok"), or one whose parts between elisions are all this
    /// short, matches almost any step and proves nothing.
    static let minimumQuote = 8

    /// Steps shown around the cited one, before and after.
    static let neighbours = 3

    static func verifierInput(_ notes: [Note], items: [TranscriptItem], byID: [Int: TranscriptItem], review: SessionNotes? = nil) -> String {
        let users = items.filter { if case .user = $0.kind { true } else { false } }
            .map { "[#\($0.id) user] \($0.text)" }.joined(separator: "\n")
        let parts = notes.map { note -> String in
            let step = byID[note.step].map { "[#\($0.id) \(label($0.kind))] \(around(note.quote, in: $0.text))" } ?? ""
            let index = items.firstIndex { $0.id == note.step }
            // Neighbouring steps cut as the digest cuts them (thinking left out).
            func context(_ range: Range<Int>) -> String {
                range.clamped(to: items.indices).compactMap { EvidenceDigest.line(items[$0], cap: 1200) }.joined(separator: "\n")
            }
            let before = index.map { context(($0 - neighbours)..<$0) } ?? ""
            let after = index.map { context(($0 + 1)..<($0 + 1 + neighbours)) } ?? ""
            return """
                ### \(note.id) (severity \(note.severity?.rawValue ?? "unknown"))
                Claim: \(note.description)
                Quote: \(note.quote)
                Before:
                \(before)
                Step:
                \(step)
                After:
                \(after)
                """
        }
        return "## User turns\n\n\(users)\n\n## Notes\n\n" + parts.joined(separator: "\n\n") + "\n"
            + (review.map { "\n" + reviewInput($0) } ?? "")
    }

    /// For the conclusion: the outcome, the paragraph, the advice and the notes rejected in
    /// code, which the conclusion must leave out.
    static func reviewInput(_ review: SessionNotes) -> String {
        let rejected = review.notes.filter { $0.source == .model && $0.verdict?.accepted == false }
            .map { "- \($0.id): \($0.description) (\($0.verdict?.reason ?? "rejected"))" }
        let advice = review.advice.map { "- \($0.title) (rests on \($0.noteIDs.joined(separator: ", ")))" }
        return """
            ## Review to conclude

            Outcome: \(review.outcome.rawValue)

            Paragraph: \(review.paragraph)

            Advice:
            \(advice.isEmpty ? "(none)" : advice.joined(separator: "\n"))

            Notes rejected before you:
            \(rejected.isEmpty ? "(none)" : rejected.joined(separator: "\n"))

            """
    }

    /// Up to ~6000 characters of a step, centred on the quote, so long outputs stay readable.
    static func around(_ quote: String, in text: String, limit: Int = 6000) -> String {
        guard text.count > limit else { return text }
        let anchor = quote.split(separator: "…").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? quote
        let start: String.Index
        if !anchor.isEmpty, let found = text.range(of: String(anchor.prefix(60))) {
            start = text.index(found.lowerBound, offsetBy: -min(limit / 2, text.distance(from: text.startIndex, to: found.lowerBound)))
        } else {
            start = text.startIndex
        }
        let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "[…] " : "") + String(text[start..<end]) + (end < text.endIndex ? " […]" : "")
    }

    static func label(_ kind: TranscriptItem.Kind) -> String {
        switch kind {
        case .user: "user"
        case .assistant: "assistant"
        case .thinking: "thinking"
        case .toolCall(let name): "call \(name)"
        case .toolResult(let name, let isError): "\(isError ? "error" : "result")\(name.map { " \($0)" } ?? "")"
        case .event(let title): "event \(title)"
        }
    }

    struct RawVerdict: Decodable {
        let id: String
        let steelman: String?
        let supported: Bool
        let reason: String
    }

    /// The verdicts by note id and the conclusion (nil when missing or blank).
    static func parseVerifier(_ text: String) throws -> (verdicts: [String: RawVerdict], conclusion: String?) {
        struct Answer: Decodable {
            let verdicts: [RawVerdict]
            let conclusion: String?
        }
        guard let json = ModelCall.jsonObject(in: text), let answer = try? JSONDecoder().decode(Answer.self, from: json) else {
            throw Failure(message: "The verifier's answer isn't the JSON asked for.")
        }
        let conclusion = answer.conclusion?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (Dictionary(answer.verdicts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                conclusion?.isEmpty == false ? conclusion : nil)
    }
}

/// `notes/<session-key>.json` files.
public struct NotesStore: Sendable {
    let paths: AnalysisPaths
    let env: HarnessEnvironment

    public init(env: HarnessEnvironment) {
        paths = AnalysisPaths(env: env)
        self.env = env
    }

    public func load(_ sessionKey: String) -> SessionNotes? {
        guard let data = try? Data(contentsOf: paths.notes(of: sessionKey)) else { return nil }
        return try? AnalysisJSON.decoder.decode(SessionNotes.self, from: data)
    }

    /// Changes a session's notes as they are on disk now, under its lock.
    @discardableResult
    public func update(_ sessionKey: String, _ change: (inout SessionNotes) throws -> Void) throws -> SessionNotes {
        let url = paths.notes(of: sessionKey)
        return try JSONFile.locked(url) {
            guard var notes = JSONFile.read(SessionNotes.self, from: url) else {
                throw JSONFile.Failure(message: "No notes for \(sessionKey).")
            }
            try change(&notes)
            try AnalysisJSON.encoder.encode(notes).write(to: url, options: .atomic)
            return notes
        }
    }

    /// Saves a new review; when the notes on disk are the same notes (same done key), the
    /// routes written since this review began (the user's verdicts, clustering) are kept.
    /// New notes (a grown session, another model) keep the user's verdicts on the notes that
    /// are still there: a note is the same when its step and quote are. The bootstrap pairing
    /// and the spot checks, which name model notes by id, move along the same way.
    func saveReview(_ review: SessionNotes) throws {
        let url = paths.notes(of: review.sessionKey)
        try JSONFile.locked(url) {
            var saved = review
            let current = JSONFile.read(SessionNotes.self, from: url)
            if let current, current.doneKeys["notes"] == review.doneKeys["notes"] {
                saved.routes = current.routes
                saved.doneKeys["matching"] = current.doneKeys["matching"]
            } else if let current {
                let carried = Self.userRoutes(of: current, carriedTo: review)
                if !carried.isEmpty { saved.routes = (review.routes ?? []) + carried }
            }
            try AnalysisJSON.encoder.encode(saved).write(to: url, options: .atomic)
            if current?.doneKeys["notes"] != review.doneKeys["notes"] {
                try moveReferences(of: review.sessionKey, renamed: current.map { Self.renamed(from: $0, to: review) } ?? [:],
                                   from: current?.doneKeys["notes"], to: review.doneKeys["notes"],
                                   notesVersion: Bootstrap.notesVersion(review.notesConfig))
            }
        }
    }

    /// A model note is the same note in another review when its step and quote are.
    static func identity(_ note: Note) -> String { "\(note.step)|\(QuoteMatcher.parts(of: note.quote).joined(separator: "…"))" }

    /// Old model note id → the id of the same note in `new`; notes that are gone are left out.
    static func renamed(from old: SessionNotes, to new: SessionNotes) -> [String: String] {
        let newIDs = Dictionary(new.notes.filter { $0.source == .model }.map { (identity($0), $0.id) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(old.notes.filter { $0.source == .model }.compactMap { note in newIDs[identity(note)].map { (note.id, $0) } },
                          uniquingKeysWith: { first, _ in first })
    }

    /// The bootstrap pairing made on the old notes and the spot checks of this session, moved
    /// to the new notes' ids; what was about a note that is gone is dropped. A pairing made on
    /// still older notes, or for another notes model or prompt, is left alone: the metrics
    /// ignore it, and its version's metrics stay about that version's notes.
    func moveReferences(of sessionKey: String, renamed: [String: String], from oldKey: String?, to newKey: String?,
                        notesVersion: String) throws {
        try Bootstrap.PairingStore(env: env).update(sessionKey) { pairing in
            guard pairing.notesKey == nil || pairing.notesKey == oldKey, pairing.notesVersion == notesVersion else { return }
            func move(_ pairs: [Bootstrap.Pairing.Pair]) -> [Bootstrap.Pairing.Pair] {
                pairs.compactMap { pair in renamed[pair.model].map { Bootstrap.Pairing.Pair(human: pair.human, model: $0) } }
            }
            pairing.notesKey = newKey
            pairing.proposed = move(pairing.proposed)
            pairing.confirmed = pairing.confirmed.map(move)
            pairing.agreed = pairing.agreed?.compactMap { renamed[$0] }
        }
        let book = LabelBookStore(env: env)
        func ofSession(_ key: String) -> NoteRef? { NoteRef(parsing: key).flatMap { $0.sessionKey == sessionKey ? $0 : nil } }
        guard book.load().spotChecks.keys.contains(where: { ofSession($0) != nil }) else { return }
        _ = try book.update { book in
            var moved: [String: Bool] = [:]
            for (key, agrees) in book.spotChecks {
                guard let ref = ofSession(key) else {
                    moved[key] = agrees
                    continue
                }
                if let id = renamed[ref.noteID] { moved[NoteRef(sessionKey: sessionKey, noteID: id).description] = agrees }
            }
            book.spotChecks = moved
        }
    }

    /// The routes the user reviewed or made in `old`, moved to the ids of the same notes in
    /// `new`; routes of notes that are gone are dropped. Matching keeps them and routes only the rest.
    static func userRoutes(of old: SessionNotes, carriedTo new: SessionNotes) -> [Route] {
        let renamed = renamed(from: old, to: new)
        return (old.routes ?? []).filter { $0.review != nil || $0.by == .human }.compactMap { route in
            guard let id = renamed[route.noteID] else { return nil }
            var moved = route
            moved.noteID = id
            return moved
        }
    }

    /// Every reviewed session.
    public func all() -> [SessionNotes] {
        FileWalk.children(of: paths.notes).filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? AnalysisJSON.decoder.decode(SessionNotes.self, from: $0) } }
    }
}

/// JSON of the analysis folder: sorted keys and ISO dates with milliseconds, so files diff
/// well and a saved value reads back equal.
public enum AnalysisJSON {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = JSONLines.date(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
            }
            return date
        }
        return decoder
    }()
}
