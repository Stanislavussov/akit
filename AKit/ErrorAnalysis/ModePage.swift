import AKitErrorAnalysis
import AKitFoundation
import SwiftUI

/// One mode: definition and criteria, exemplars, the notes routed to it, its code check
/// and fix status, with every action on it.
struct ModePage: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(AppModel.self) private var model
    let id: String
    @Binding var action: ModeAction?
    /// Opens another mode's page (the one it was merged into).
    let select: (String) -> Void
    @State private var justConfirmed = false
    @State private var showAllNotes = false
    @State private var addExemplar = false

    var body: some View {
        if let mode = analysis.data.mode(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(mode)
                    if justConfirmed, mode.status == .active { followUps(mode) }
                    definition(mode)
                    check(mode)
                    exemplars(mode)
                    routed(mode)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sheet(isPresented: $addExemplar) { AddExemplarSheet(mode: mode) }
        }
    }

    private func header(_ mode: Mode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(mode.name).font(.title2.bold()).textSelection(.enabled)
                ModeStatusBadge(mode: mode)
                Spacer()
            }
            Text("\(mode.id) · \(mode.kind.rawValue) · \(mode.origin.title) · \(mode.scope.description) · v\(mode.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                ModeActions(mode: mode, action: $action) { justConfirmed = true }
                if mode.isCurrent {
                    Button("Retro-match…", systemImage: "arrow.counterclockwise") {
                        analysis.send = .retro(mode, data: analysis.data)
                    }
                    .help("Route the whole note pool against this mode (a model call; the cost first)")
                }
            }
            .controlSize(.small)
        }
    }

    /// After Confirm: the mode's check and retro-matching, as the design offers them.
    private func followUps(_ mode: Mode) -> some View {
        HStack {
            Label("\(mode.name) is active. Next: count it over your sessions and find it in the notes already reviewed.",
                  systemImage: "checkmark.seal")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if CodeChecks.check(for: mode.id) != nil {
                Button("Run Check") { analysis.runCheck(mode) }
            }
            Button("Retro-match the Note Pool…") { analysis.send = .retro(mode, data: analysis.data) }
        }
        .controlSize(.small)
        .padding(10)
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func definition(_ mode: Mode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode.definition).fixedSize(horizontal: false, vertical: true)
            if !mode.include.isEmpty {
                criteria("Include", mode.include, icon: "plus.circle", tint: .green)
            }
            if !mode.exclude.isEmpty {
                criteria("Exclude", mode.exclude, icon: "minus.circle", tint: .red)
            }
            if let reason = mode.rejectedReason {
                Label("Rejected: \(reason)", systemImage: "xmark.circle").foregroundStyle(.red)
            }
            if let target = mode.mergedInto {
                HStack {
                    Label("Merged into \(analysis.data.mode(target)?.name ?? target); its notes count there.", systemImage: "arrow.triangle.merge")
                        .foregroundStyle(.secondary)
                    Button("Show") { select(target) }.controlSize(.small)
                }
            }
            if mode.kind.takesFixes {
                Text("Fix: \(mode.fix?.title ?? "none yet")").foregroundStyle(.secondary)
            } else {
                Text("A success mode: a strategy to keep, so it takes no fix.").foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    private func criteria(_ title: String, _ items: [String], icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label { Text(item).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: icon).foregroundStyle(tint)
                }
            }
        }
    }

    @ViewBuilder private func check(_ mode: Mode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Code check").font(.title3.bold())
            if let check = CodeChecks.check(for: mode.id) {
                let results = analysis.data.checks[mode.id]
                let seen = analysis.data.seenByMode[mode.id]?.count ?? 0
                Text(check.summary).fixedSize(horizontal: false, vertical: true)
                Text(check.kind == .mechanical
                     ? "Mechanical: the check is the definition, exact by construction, so its rate is the mode's frequency."
                     : "Heuristic — not validated: until it is, the mode's frequency is \"seen in \(seen) notes\", not this rate.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let results, let rate = AnalysisText.rate(results) {
                    Text("Over indexed sessions: \(rate)").monospacedDigit()
                    if let version = results.modeVersion, version != mode.version {
                        Text("Made for v\(version); the mode is v\(mode.version) now. Run it again.").foregroundStyle(.orange)
                    }
                } else {
                    Text("Not run yet.").foregroundStyle(.secondary)
                }
                Button("Run Check", systemImage: "play") { analysis.runCheck(mode) }
                    .controlSize(.small)
                    .disabled(analysis.progress != nil)
                    .help("Run the check over every indexed session, here on this Mac; nothing is sent")
            } else {
                Text("No code check for this mode: its frequency is \"seen in \(analysis.data.seenByMode[mode.id]?.count ?? 0) notes\".")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func exemplars(_ mode: Mode) -> some View {
        let exemplars = analysis.data.exemplars[mode.id] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Exemplars").font(.title3.bold())
                Text("\(exemplars.count) of \(ModeStore.maxExemplars)").foregroundStyle(.secondary)
                Spacer()
                Button("Add from the Pool…", systemImage: "plus") { addExemplar = true }
                    .controlSize(.small)
                    .disabled(exemplars.count >= ModeStore.maxExemplars)
            }
            Text("They go into every matching call. A session in a test set is never one.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(exemplars, id: \.self) { exemplar in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(exemplar.sessionKey) · step #\(exemplar.step)").font(.caption).foregroundStyle(.secondary)
                        QuoteText(text: exemplar.quote)
                    }
                    Button("Remove", systemImage: "minus.circle") {
                        analysis.act { env in
                            try await ModeStore(env: env).removeExemplar(exemplar)
                            return "Removed the exemplar."
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Remove this exemplar")
                }
            }
        }
    }

    private func routed(_ mode: Mode) -> some View {
        let refs = (analysis.data.seenByMode[mode.id] ?? []).sorted()
        let shown = showAllNotes ? refs : Array(refs.prefix(20))
        let exemplars = analysis.data.exemplars[mode.id] ?? []
        return VStack(alignment: .leading, spacing: 12) {
            Text("Seen in \(refs.count) \(refs.count == 1 ? "note" : "notes")").font(.title3.bold())
            if refs.isEmpty {
                Text("No accepted note is routed here yet.").foregroundStyle(.secondary)
            }
            ForEach(shown, id: \.self) { ref in
                let found = analysis.data.note(ref)
                HStack(alignment: .top) {
                    PoolNoteView(ref: ref, data: analysis.data)
                    VStack(alignment: .trailing, spacing: 4) {
                        if let runID = found?.session.runID, model.labRuns.contains(where: { $0.id == runID }) {
                            Button("Show Review") {
                                model.revealLabRun = runID
                                model.section = .lab
                            }
                        }
                        if let found, exemplars.count < ModeStore.maxExemplars,
                           !exemplars.contains(where: { $0.sessionKey == ref.sessionKey && $0.step == found.note.step }) {
                            Button("Make Exemplar") { add(found.note, of: ref.sessionKey, to: mode) }
                                .disabled(analysis.data.testSessions.contains(ref.sessionKey))
                        }
                    }
                    .controlSize(.small)
                }
            }
            if refs.count > shown.count {
                Button("Show all \(refs.count)") { showAllNotes = true }.buttonStyle(.link)
            }
        }
    }

    private func add(_ note: Note, of sessionKey: String, to mode: Mode) {
        let exemplar = Exemplar(modeID: mode.id, sessionKey: sessionKey, step: note.step, quote: note.quote, noteID: note.id)
        let tests = analysis.data.testSessions
        analysis.act { env in
            let list = try await ModeStore(env: env).addExemplar(exemplar, testSessions: tests)
            return "\(list.count) exemplars."
        }
    }
}

/// Picks an exemplar among the accepted notes of the pool; notes routed to the mode first.
private struct AddExemplarSheet: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var query = ""
    @State private var error: String?

    private var refs: [NoteRef] {
        let routed = Set(analysis.data.seenByMode[mode.id] ?? [])
        let all = analysis.data.pool.flatMap { session in session.accepted.map { NoteRef(sessionKey: session.sessionKey, noteID: $0.id) } }
        let filtered = query.isEmpty ? all : all.filter { ref in
            guard let note = analysis.data.note(ref)?.note else { return false }
            return note.description.localizedCaseInsensitiveContains(query) || note.quote.localizedCaseInsensitiveContains(query)
        }
        return filtered.sorted { (routed.contains($0) ? 0 : 1, $0) < (routed.contains($1) ? 0 : 1, $1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an Exemplar to \(mode.name)").font(.title2.bold())
            TextField("Search notes", text: $query).textFieldStyle(.roundedBorder)
            List(refs, id: \.self) { ref in
                HStack(alignment: .top) {
                    PoolNoteView(ref: ref, data: analysis.data)
                    Button("Add") { add(ref) }
                        .disabled(analysis.data.testSessions.contains(ref.sessionKey))
                        .help(analysis.data.testSessions.contains(ref.sessionKey) ? "This session is in a test set" : "Add this note's quote")
                }
                .padding(.vertical, 4)
            }
            .frame(height: 380)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func add(_ ref: NoteRef) {
        guard let note = analysis.data.note(ref)?.note else { return }
        let exemplar = Exemplar(modeID: mode.id, sessionKey: ref.sessionKey, step: note.step, quote: note.quote, noteID: note.id)
        let tests = analysis.data.testSessions
        error = nil
        Task {
            do {
                try await analysis.run { env in
                    let list = try await ModeStore(env: env).addExemplar(exemplar, testSessions: tests)
                    return "\(list.count) exemplars."
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
