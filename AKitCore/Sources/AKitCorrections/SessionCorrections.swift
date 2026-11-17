import AKitErrorAnalysis
import AKitFoundation
import AKitInsights
import AKitSessions
import Foundation

extension CorrectedSession {
    /// The corrections of one session counted by code from its file, without the index: for a
    /// session the index leaves out, such as a flow step's (Runs → Corrections, D27).
    public static func of(_ session: SessionSummary) throws -> CorrectedSession {
        let transcript = try SessionReader.transcript(of: session)
        let signals = SignalScanner.scan(transcript.items, fallbackModel: transcript.models.last, harness: session.harness.rawValue).signals
        let id = session.file.deletingPathExtension().lastPathComponent
        return CorrectedSession(key: "\(session.origin ?? session.harness.rawValue):\(id)", harness: session.harness.rawValue,
                                file: session.file.path, cwd: session.project?.path, project: nil, started: session.started,
                                harnessVersion: session.harnessVersion, model: transcript.models.last,
                                interrupts: signals.interrupts, pushbacks: signals.pushbacks, refusals: signals.userRefusals,
                                badRatings: transcript.ratings.filter { !$0.isGood }.count)
    }
}
