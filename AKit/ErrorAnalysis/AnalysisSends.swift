import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import Foundation

/// The model calls of the Error Analysis screen, as the CLI makes them
/// (`akit analysis cluster|retro`, `akit analysis bootstrap pair|first-modes|similar`).
extension AnalysisSend {
    /// Groups the notes no mode fits into candidate modes.
    static func cluster(_ data: AnalysisData) -> AnalysisSend {
        let items = data.unmatchedItems()
        return AnalysisSend(
            title: "Cluster Unmatched Notes",
            detail: "One call over the \(AnalysisText.notes(items.count)) no mode fits: it proposes candidate modes. The candidates wait for you; one also becomes a mode when a later session matches it.",
            characters: items.map { $0.description.count + $0.quote.count + 60 }.reduce(0, +)
        ) { agent, gate, env in
            let store = ModeStore(env: env)
            let modes = try await store.list()
            let items = Clustering.unmatchedItems(NotesStore(env: env).all(), modes: modes)
            guard !items.isEmpty else { return "No notes to cluster." }
            let candidates = try await Clustering.cluster(items, existing: modes, rejected: try await store.rejectedNames(), agent: agent,
                                                          gate: gate, runID: nil, workFolder: AnalysisModel.workFolder(env), env: env)
            let created = try await Clustering.apply(candidates, store: store, env: env)
            return created.isEmpty ? "No new candidates." : "New: " + created.map { "\($0.name) (\($0.status.title))" }.joined(separator: ", ") + "."
        }
    }

    /// Routes the whole note pool against one mode (after it was confirmed).
    static func retro(_ mode: Mode, data: AnalysisData) -> AnalysisSend {
        let origins = Dictionary(data.pool.map { ($0.sessionKey, $0.origin) }, uniquingKeysWith: { first, _ in first })
        let parts = Matching.retroInput(mode: mode, pool: data.pool, origins: origins)
        let id = mode.id
        return AnalysisSend(
            title: "Retro-match the Note Pool",
            detail: "Asks whether each of the \(AnalysisText.notes(parts.flatMap(\.refs).count)) in the pool fits \(mode.name). A note with no mode moves to it; a note routed elsewhere gets a second route for you to decide.",
            characters: parts.map(\.text.count).reduce(0, +)
        ) { agent, gate, env in
            guard let mode = try await ModeStore(env: env).mode(id) else { throw AnalysisFailure( "There is no mode \(id).") }
            let pool = NotesStore(env: env).all()
            let origins = Dictionary(pool.map { ($0.sessionKey, $0.origin) }, uniquingKeysWith: { first, _ in first })
            let fits = try await Matching.retroMatch(mode: mode, pool: pool, origins: origins, agent: agent, gate: gate,
                                                     workFolder: AnalysisModel.workFolder(env), env: env)
            return "\(fits.count) notes fit \(mode.name)."
        }
    }

    /// The model proposes pairs of the user's notes and its own for one finished session.
    static func pairs(_ label: Bootstrap.Label, notes: SessionNotes) -> AnalysisSend {
        let key = label.sessionKey
        let characters: Int = (label.notes + notes.notes).map { (note: Note) -> Int in note.description.count + note.quote.count + 40 }
            .reduce(0, +)
        return AnalysisSend(
            title: "Propose Pairs",
            detail: "Sends your \(AnalysisText.notes(label.notes.count)) and the model's \(notes.notes.count) (descriptions, steps and quotes) so the model pairs the ones about the same problem. You confirm the pairs.",
            characters: characters
        ) { agent, gate, env in
            guard let label = Bootstrap.LabelStore(env: env).load(key), label.labeledAt != nil else {
                throw AnalysisFailure( "Finish labeling \(key) first.")
            }
            guard let notes = NotesStore(env: env).load(key) else { throw AnalysisFailure( "The model hasn't reviewed \(key) yet.") }
            let pairing = try await Bootstrap.proposePairs(label: label, notes: notes, agent: agent, gate: gate, origin: notes.origin,
                                                           workFolder: AnalysisModel.workFolder(env), env: env)
            return "The model proposed \(pairing.proposed.count) pairs. Check them and confirm."
        }
    }

    /// The first modes: one clustering call over the labeled sessions' notes, yours and the model's.
    static func firstModes(_ data: AnalysisData) -> AnalysisSend {
        let done = data.labels.values.filter { $0.labeledAt != nil }
        return AnalysisSend(
            title: "First Modes",
            detail: "Clusters the notes of your \(done.count) labeled sessions, yours and the model's, into candidate modes. Seeds are in the list already.",
            characters: done.flatMap(\.notes).map { $0.description.count + $0.quote.count + 60 }.reduce(0, +) * 2
        ) { agent, gate, env in
            let labels = Bootstrap.LabelStore(env: env).all().filter { $0.labeledAt != nil }
            guard !labels.isEmpty else { throw AnalysisFailure( "Label some sessions first.") }
            let store = ModeStore(env: env)
            let candidates = try await Bootstrap.firstModes(labels: labels, pool: NotesStore(env: env).all(), existing: try await store.list(),
                                                            rejected: try await store.rejectedNames(), agent: agent, gate: gate,
                                                            workFolder: AnalysisModel.workFolder(env), env: env)
            let created = try await Clustering.apply(candidates, store: store, env: env)
            return created.isEmpty ? "No new candidates." : "New: " + created.map(\.name).joined(separator: ", ") + ". Confirm or edit them, then map your notes."
        }
    }

    /// Searches the pool for cases like the user's notes mapped to `mode`.
    static func similar(_ mode: Mode, data: AnalysisData) -> AnalysisSend {
        let labeled = Set(data.labels.keys)
        let items = Clustering.items(data.pool.filter { !labeled.contains($0.sessionKey) })
        let id = mode.id
        return AnalysisSend(
            title: "Find Similar Cases",
            detail: "Sends your notes mapped to \(mode.name) and the \(AnalysisText.notes(items.count)) of other reviewed sessions; the model lists the ones that show the same mode. You accept or reject each find.",
            characters: items.map { $0.description.count + $0.quote.count + 60 }.reduce(0, +)
        ) { agent, gate, env in
            guard let mode = try await ModeStore(env: env).mode(id) else { throw AnalysisFailure( "There is no mode \(id).") }
            let finds = try await Bootstrap.findSimilar(mode: mode, labels: Bootstrap.LabelStore(env: env).all(), pool: NotesStore(env: env).all(),
                                                        book: LabelBookStore(env: env).load(), agent: agent, gate: gate,
                                                        workFolder: AnalysisModel.workFolder(env), env: env)
            return finds.isEmpty ? "No similar cases found." : "\(finds.count) possible cases of \(mode.name) wait for your verdict."
        }
    }
}
