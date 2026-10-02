import Foundation
@testable import AKitErrorAnalysis

/// Whole-file writes for test fixtures only. AKit itself changes these files by
/// read-modify-write under their locks (`update`, `saveReview`).
extension NotesStore {
    func save(_ notes: SessionNotes) throws {
        try JSONFile.write(notes, to: paths.notes(of: notes.sessionKey))
    }
}

extension CheckStore {
    func save(_ results: CheckResults) throws {
        try JSONFile.write(results, to: paths.check(of: results.modeID))
    }
}
