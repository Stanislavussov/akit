import AKitFoundation
import AKitLab
import AKitModel
import Foundation

/// The Lab runs error analysis does (`LabWorker.run`'s `execute`): the one-call session
/// review, which is Step 1 and the verifier for one session.
public enum AnalysisRuns {
    public static let execute: LabWorker.Execute = { run, env, phase, out in
        switch run.spec.kind {
        case .review where run.spec.agent?.mode == .call:
            return try await review(run, env: env, phase: phase, out: out)
        default:
            return nil
        }
    }

    /// Notes, verifier, then what the Lab screen shows: the paragraph as `summary.md` and the
    /// advice as `review.json`. A refused send or a missing account stops the run with the
    /// reason; a model that fails or answers badly is kept as the run's agent error.
    static func review(_ run: LabRun, env: HarnessEnvironment, phase: @escaping @Sendable (RunState.Phase) -> Void,
                       out: @escaping @Sendable (String) -> Void) async throws -> RunResult {
        let file = try ReviewRun.reviewedFile(run)
        let agent = run.spec.agent ?? LabRuns.defaultAgent(.claudeCode, env: env)
        var target = NotesPipeline.Target(harness: run.spec.reviewedHarness, file: file, title: run.spec.reviewedTitle,
                                          project: LabPaths.folder(ofTranscript: file))
        if let key = SessionKey.of(target.summary), BootstrapReservations(env: env).isReserved(key.description) {
            throw LabWorker.Failure(message: "This session is reserved for bootstrap labeling; review it after you have labeled it.")
        }
        let gate = try await SendGate.open(agent: agent, env: env)
        let metrics = try await ReviewRun.prepare(run, transcript: file, env: env).metrics
        target.numbers = metrics.flatMap { try? String(decoding: LabStore.encoder.encode($0), as: UTF8.self) }
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
