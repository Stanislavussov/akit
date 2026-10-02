import AKitErrorAnalysis
import AKitFoundation
import SwiftUI

/// The bootstrap's results: agreement with the model per notes version, the mapping of the
/// user's notes to modes, the first modes and the similar-case search with its finds.
struct BootstrapOverview: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(AppModel.self) private var model

    var body: some View {
        let data = analysis.data
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                metrics(data)
                mapping(data)
                similar(data)
                finds(data)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sessionTitle(_ key: String, data: AnalysisData) -> String {
        let transcript = data.labels[key]?.transcript
        return model.sessions.first { $0.file.path == transcript }?.title ?? data.notes(of: key)?.title ?? key
    }

    // MARK: Metrics

    private func metrics(_ data: AnalysisData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agreement with the model").font(.title3.bold())
            Text("Over labeled sessions with confirmed pairs, per notes model and prompt version. Recall is the share of your problems the model found; precision the share of its accepted notes you agree with.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if data.metrics.isEmpty {
                Text("No confirmed pairs yet: finish a session, review it with a model, then propose and confirm pairs.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Notes version")
                        Text("Sessions")
                        Text("Recall")
                        Text("Precision")
                        Text("Phase")
                        Text("±3 steps")
                        Text("Outcome")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(data.metrics, id: \.notesVersion) { m in
                        GridRow {
                            Text(m.notesVersion)
                            Text("\(m.sessions)")
                            Text(share(m.recall, m.recallCounts[0], m.recallCounts[1]))
                            Text(share(m.precision, m.precisionCounts[0], m.precisionCounts[1]))
                            Text(share(m.phaseAgreement, m.deviationCounts[0], m.deviationCounts[2]))
                            Text(share(m.stepAgreement, m.deviationCounts[1], m.deviationCounts[2]))
                            Text(share(m.outcomeAgreement, m.outcomeCounts[0], m.outcomeCounts[1]))
                        }
                        .monospacedDigit()
                    }
                }
                .textSelection(.enabled)
                Text("Phase and ±3 steps compare the decisive step. Recall and precision need more than a few sessions to mean much.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func share(_ value: Double?, _ k: Int, _ n: Int) -> String {
        n == 0 ? "—" : "\(AnalysisText.percent(value)) (\(k)/\(n))"
    }

    // MARK: Mapping

    private func mapping(_ data: AnalysisData) -> some View {
        let done = data.labels.values.filter { $0.labeledAt != nil && !$0.notes.isEmpty }.sorted { $0.sessionKey < $1.sessionKey }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your notes → modes").font(.title3.bold())
                Spacer()
                Button("First Modes…", systemImage: "circle.grid.3x3") { analysis.send = .firstModes(data) }
                    .disabled(data.labeledCount == 0)
                    .help("Cluster the labeled sessions' notes, yours and the model's, into candidate modes (a model call; the cost first)")
            }
            Text("Your notes become labels for checks only through this mapping. Unclear notes are kept as a source of new modes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if done.isEmpty {
                Text("Finish labeling a session to map its notes.").foregroundStyle(.secondary)
            }
            ForEach(done, id: \.sessionKey) { label in
                VStack(alignment: .leading, spacing: 8) {
                    Text(sessionTitle(label.sessionKey, data: data)).fontWeight(.semibold)
                    ForEach(label.notes) { note in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(note.id) · step #\(note.step)").font(.caption).foregroundStyle(.secondary)
                                Text(note.description).fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            ModePicker(key: "\(label.sessionKey)#\(note.id)", data: data)
                                .frame(width: 240)
                        }
                    }
                }
                .card()
            }
        }
    }

    // MARK: Similar cases

    @ViewBuilder private func similar(_ data: AnalysisData) -> some View {
        let mapped = Dictionary(grouping: data.book.mapping.filter { $0.value != LabelBook.unclear }, by: \.value)
            .compactMap { id, entries in data.mode(id).map { ($0, entries.count) } }
            .sorted { $0.0.name < $1.0.name }
        VStack(alignment: .leading, spacing: 10) {
            Text("Similar cases").font(.title3.bold())
            Text("The model searches the pool for cases like your notes of a mode; each find you accept or reject is a cheap label for its check.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if mapped.isEmpty {
                Text("Map some of your notes to modes first.").foregroundStyle(.secondary)
            }
            ForEach(mapped, id: \.0.id) { mode, count in
                HStack {
                    Text(mode.name)
                    Text("· \(AnalysisText.notes(count)) of yours").foregroundStyle(.secondary)
                    Spacer()
                    Button("Find Similar Cases…") { analysis.send = .similar(mode, data: data) }
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private func finds(_ data: AnalysisData) -> some View {
        if !data.book.finds.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Finds").font(.title3.bold())
                ForEach(data.book.finds, id: \.self) { find in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("For \(data.mode(find.modeID)?.name ?? find.modeID), found from your \(find.from.noteID)")
                            .font(.callout.weight(.medium))
                        PoolNoteView(ref: find.ref, data: data)
                        HStack {
                            if let accepted = find.accepted {
                                Label(accepted ? "Accepted" : "Rejected", systemImage: accepted ? "checkmark.circle" : "xmark.circle")
                                    .foregroundStyle(accepted ? .green : .secondary)
                            }
                            Button("Accept") { decide(find, true) }.disabled(find.accepted == true)
                            Button("Reject") { decide(find, false) }.disabled(find.accepted == false)
                        }
                        .controlSize(.small)
                    }
                    .card()
                }
            }
        }
    }

    private func decide(_ find: LabelBook.Find, _ accept: Bool) {
        analysis.act { env in
            _ = try LabelBookStore(env: env).update { book in
                guard let index = book.finds.firstIndex(where: { $0.ref == find.ref && $0.modeID == find.modeID }) else {
                    throw AnalysisFailure("The find is gone.")
                }
                book.finds[index].accepted = accept
            }
            return accept ? "Accepted: a positive label for the mode's check." : "Rejected: a negative label for the mode's check."
        }
    }
}

/// A note's mode: not mapped, a current mode, or unclear. Saved in the label book at once.
private struct ModePicker: View {
    @Environment(AnalysisModel.self) private var analysis
    let key: String
    let data: AnalysisData

    var body: some View {
        let current = data.book.mapping[key] ?? ""
        let modes = data.current + (data.mode(current).map { $0.isCurrent ? [] : [$0] } ?? [])
        Picker("Mode", selection: Binding(get: { current }, set: { save($0) })) {
            Text("Not mapped").tag("")
            ForEach(modes.sorted { $0.name < $1.name }) { Text($0.name).tag($0.id) }
            Divider()
            Text("Unclear").tag(LabelBook.unclear)
        }
        .labelsHidden()
    }

    private func save(_ value: String) {
        let key = key
        analysis.act { env in
            _ = try LabelBookStore(env: env).update { book in book.mapping[key] = value.isEmpty ? nil : value }
            return nil
        }
    }
}
