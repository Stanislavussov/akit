import AKitFoundation
import AKitLab
import AKitModel
import Foundation

/// The Lab runs error analysis does (`LabWorker.run`'s `execute`): the one-call session
/// review, which is Step 1 and the verifier for one session.
public enum AnalysisRuns {
    public static let execute: LabWorker.Execute = { run, env, phase, out in
        // Every review, also an agent's, keeps away from sessions reserved for blind labeling.
        if run.spec.kind == .review { try refuseReserved(run, env: env) }
        switch run.spec.kind {
        case .review where run.spec.agent?.mode == .call:
            return try await review(run, env: env, phase: phase, out: out)
        case .analysis:
            return try await BatchRunner.execute(run, env: env, phase: phase, out: out)
        case .control:
            return try await ControlRuns.execute(run, env: env, phase: phase, out: out)
        default:
            return nil
        }
    }

    static func refuseReserved(_ run: LabRun, env: HarnessEnvironment) throws {
        let file = try ReviewRun.reviewedFile(run)
        let summary = NotesPipeline.Target(harness: run.spec.reviewedHarness, file: file).summary
        if let key = SessionKey.of(summary), BootstrapReservations(env: env).isReserved(key.description) {
            throw LabWorker.Failure(message: "This session is reserved for bootstrap labeling; review it after you have labeled it.")
        }
    }

    /// Notes, verifier, then what the Lab screen shows: the paragraph as `summary.md` and the
    /// advice as `review.json`. A refused send or a missing account stops the run with the
    /// reason; a model that fails or answers badly is kept as the run's agent error.
    static func review(_ run: LabRun, env: HarnessEnvironment, phase: @escaping @Sendable (RunState.Phase) -> Void,
                       out: @escaping @Sendable (String) -> Void) async throws -> RunResult {
        let file = try ReviewRun.reviewedFile(run)
        let agent = run.spec.agent ?? LabRuns.defaultAgent(.claudeCode, env: env)
        let target = NotesPipeline.Target(harness: run.spec.reviewedHarness, file: file, title: run.spec.reviewedTitle,
                                          project: LabPaths.folder(ofTranscript: file))
        let gate = try await SendGate.open(agent: agent, env: env)
        // The run's analysis.json for the Lab screen; the notes call computes its own numbers
        // from the transcript, as a batch does, so both share notes.
        _ = try await ReviewRun.prepare(run, transcript: file, env: env)
        guard !Cancellation.isCancelled else { throw CancellationError() }

        phase(.agent)
        let config = NotesPipeline.Config(notes: agent, language: run.spec.language ?? .english)
        let notes: SessionNotes
        do {
            notes = try await NotesPipeline.review(target, config: config, notesGate: gate, verifierGate: gate, runID: run.id,
                                                   workFolder: run.folder, env: env, out: out)
        } catch let failure as ModelCall.Failure {
            return RunResult(review: .missing, agentError: failure.message)
        } catch let failure as NotesPipeline.Failure {
            return RunResult(review: .invalid, agentError: failure.message)
        }
        // Matching right after the verifier: the notes go into the pool routed to modes. A failed
        // matching call leaves them unrouted; it doesn't fail the review.
        var routed = notes
        do {
            let store = ModeStore(env: env)
            let modes = try await store.list()
            var exemplars: [String: [Exemplar]] = [:]
            for mode in Matching.routable(modes) { exemplars[mode.id] = try store.exemplars(of: mode.id) }
            routed = try await Matching.route(notes, modes: modes, exemplars: exemplars, agent: agent, gate: gate, origin: notes.origin,
                                              runID: run.id, workFolder: run.folder, env: env)
            try await Clustering.promoteCandidates(store: store, env: env)
        } catch {
            out("Matching didn't run: \(error.localizedDescription)")
        }
        let routedCount = Matching.currentRoutes(routed).values.filter { $0.modeID != nil }.count
        if routedCount > 0 { out("Matched \(routedCount) notes to modes.") }
        try ReviewRun.write(summary: notes.paragraph,
                            findings: notes.advice.map { Review.Finding(title: $0.title, evidence: $0.evidence, detail: $0.detail) },
                            to: run.folder)
        out("")
        out("Outcome: \(notes.outcome.title). \(notes.accepted.count) notes accepted, \(notes.rejected.count) rejected.")
        out(notes.paragraph)
        for (index, advice) in notes.advice.enumerated() { out("\(index + 1). \(advice.title)") }
        phase(.metrics)
        return RunResult(review: ReviewRun.status(in: run.folder))
    }
}
