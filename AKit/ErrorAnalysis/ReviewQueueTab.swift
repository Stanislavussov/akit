import AKitErrorAnalysis
import AKitFoundation
import SwiftUI

/// What waits for the user after each run (`docs/design/error-analysis.md`, "Human in the
/// loop"): candidate modes, low-confidence routes, checks' tough calls, spot checks and
/// seeds that may be umbrellas; then the unclear bucket.
struct ReviewQueueTab: View {
    @Environment(AnalysisModel.self) private var analysis
    @Binding var action: ModeAction?
    /// The candidate just confirmed here: its follow-ups show above the queue.
    @State private var confirmed: Mode.ID?

    var body: some View {
        let data = analysis.data
        let queue = data.queue
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(data)
                if let id = confirmed, let mode = data.mode(id), mode.status == .active {
                    ConfirmedFollowUps(mode: mode) { confirmed = nil }
                }
                if queue.isEmpty {
                    Label("Nothing waits for you.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                if !queue.candidates.isEmpty {
                    section("Candidate modes", count: queue.candidates.count,
                            help: "Found in the notes. Confirm the ones that are real and specific; merge or reject the rest.") {
                        ForEach(queue.candidates) { mode in CandidateCard(mode: mode, action: $action) { confirmed = mode.id } }
                    }
                }
                if !queue.routes.isEmpty {
                    section("Low-confidence routes", count: queue.routes.count,
                            help: "Matching wasn't sure where these notes belong. Your verdicts are the route acceptance.") {
                        ForEach(queue.routes, id: \.ref) { item in RouteCard(ref: item.ref, route: item.route) }
                    }
                }
                if !queue.toughCalls.isEmpty {
                    section("Tough calls", count: queue.toughCalls.count,
                            help: "Borderline check verdicts: left out of the check's TPR and TNR until you decide.") {
                        ForEach(queue.toughCalls, id: \.self) { ToughCallCard(call: $0) }
                    }
                }
                if !queue.spotChecks.isEmpty {
                    section("Spot checks", count: queue.spotChecks.count,
                            help: "Random accepted notes of the latest batch: is each a real problem? This measures the notes' precision.") {
                        ForEach(queue.spotChecks, id: \.self) { SpotCheckCard(ref: $0) }
                    }
                }
                if !queue.umbrellas.isEmpty {
                    section("Seeds that may be umbrellas", count: queue.umbrellas.count,
                            help: "A seed that takes more than \(Int(ReviewQueue.umbrellaShare * 100))% of the routed notes may be too broad: narrow or split it.") {
                        ForEach(queue.umbrellas, id: \.self) { UmbrellaCard(umbrella: $0, action: $action) }
                    }
                }
                unclear(data)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ data: AnalysisData) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Route acceptance: \(data.accepted) of \(data.reviewed) accepted").font(.headline)
                Text("Matching's one metric: the share of the routes you reviewed that you accepted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cluster Unmatched Notes… (\(data.unmatched.count))", systemImage: "circle.grid.3x3") {
                analysis.send = .cluster(data)
            }
            .disabled(data.unmatched.isEmpty)
            .help("Group the notes no mode fits into candidate modes (a model call; the cost first)")
        }
    }

    private func section(_ title: String, count: Int, help: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.bold())
                Text("\(count)").foregroundStyle(.secondary)
            }
            Text(help).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    @ViewBuilder private func unclear(_ data: AnalysisData) -> some View {
        section("Unclear", count: data.unclear.count,
                help: "Notes you couldn't place in any mode. They are kept: they are the main source of future modes.") {
            if data.unclear.isEmpty {
                Text("Empty.").foregroundStyle(.secondary)
            }
            ForEach(data.unclear, id: \.self) { entry in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(data.notes(of: entry.sessionKey)?.title ?? entry.sessionKey) · \(entry.noteID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.text).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Remove") {
                        analysis.act { env in
                            try UnclearNotes(env: env).remove(sessionKey: entry.sessionKey, noteID: entry.noteID)
                            return "Removed from the unclear bucket."
                        }
                    }
                    .controlSize(.small)
                }
                .card()
            }
        }
    }
}

private struct CandidateCard: View {
    @Environment(AnalysisModel.self) private var analysis
    let mode: Mode
    @Binding var action: ModeAction?
    let confirmed: () -> Void

    var body: some View {
        let seen = analysis.data.seenByMode[mode.id]?.count ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(mode.name).fontWeight(.semibold)
                Text("\(mode.kind.rawValue) · seen in \(seen) \(seen == 1 ? "note" : "notes")").font(.callout).foregroundStyle(.secondary)
            }
            Text(mode.definition).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Confirm", systemImage: "checkmark.circle") {
                    let mode = mode
                    // As on the mode page: the check runs at once, and the follow-ups show above.
                    Task { if await analysis.confirm(mode) { confirmed() } }
                }
                Button("Rename…") { action = .rename(mode) }
                Button("Merge into…") { action = .merge(mode) }
                Button("Reject…", role: .destructive) { action = .reject(mode) }
            }
            .controlSize(.small)
        }
        .card()
    }
}

private struct RouteCard: View {
    @Environment(AnalysisModel.self) private var analysis
    let ref: NoteRef
    let route: Route

    var body: some View {
        let data = analysis.data
        VStack(alignment: .leading, spacing: 6) {
            PoolNoteView(ref: ref, data: data)
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                Text(route.modeID.flatMap { data.mode($0)?.name ?? $0 } ?? "None fits").fontWeight(.medium)
                Text(String(format: "confidence %.2f", route.confidence)).foregroundStyle(.secondary).monospacedDigit()
            }
            if let reason = route.reason, !reason.isEmpty {
                Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            RouteActions(ref: ref, route: route)
        }
        .card()
    }
}

/// Accept, Reject and Move to… for one route of a note (`akit analysis review`): on the
/// Review tab for low-confidence routes, on a mode page for the notes routed to it.
struct RouteActions: View {
    @Environment(AnalysisModel.self) private var analysis
    let ref: NoteRef
    let route: Route

    var body: some View {
        HStack {
            // A route you accepted or moved yourself has nothing left to accept.
            if route.review == nil, route.by != .human {
                Button("Accept", systemImage: "checkmark") { review(accept: true) }
            }
            Button("Reject", systemImage: "xmark") { review(accept: false) }
            Menu("Move to…") {
                ForEach(analysis.data.current.filter { $0.id != route.modeID }) { mode in
                    Button(mode.name) { review(accept: false, moveTo: .some(mode.id)) }
                }
                Divider()
                Button("None Fits") { review(accept: false, moveTo: .some(nil)) }
                Button("Unclear") { review(accept: false, moveTo: .some(nil), unclear: true) }
            }
            .fixedSize()
        }
        .controlSize(.small)
    }

    private func review(accept: Bool, moveTo: String?? = nil, unclear: Bool = false) {
        let ref = ref, route = route
        let text = analysis.data.note(ref)?.note.description ?? ""
        analysis.act { env in
            try Matching.review(ref, route: route, accept: accept, moveTo: moveTo, env: env)
            // A note the user moved to a candidate may be its second independent case.
            try await Clustering.promoteCandidates(store: ModeStore(env: env), env: env)
            if unclear { try UnclearNotes(env: env).add(UnclearNotes.Entry(sessionKey: ref.sessionKey, noteID: ref.noteID, text: text)) }
            let acceptance = Matching.acceptance(NotesStore(env: env).all())
            return "\(accept ? "Accepted" : "Rejected") the route. Route acceptance: \(acceptance.accepted) of \(acceptance.reviewed)."
        }
    }
}

private struct ToughCallCard: View {
    @Environment(AnalysisModel.self) private var analysis
    let call: ReviewQueue.ToughCall

    var body: some View {
        let data = analysis.data
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(data.mode(call.modeID)?.name ?? call.modeID).fontWeight(.semibold)
                Text("in \(data.notes(of: call.sessionKey)?.title ?? call.sessionKey)").foregroundStyle(.secondary).lineLimit(1)
            }
            Text(verdictText).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Present") { decide(true) }
                Button("Not Present") { decide(false) }
            }
            .controlSize(.small)
        }
        .card()
    }

    /// "The check says present at #16: done with no check after the last edit."
    private var verdictText: String {
        let verdict = call.verdict
        var text = "The check says " + (verdict.positive ? "present" : "absent")
        if !verdict.steps.isEmpty { text += " at " + verdict.steps.map { "#\($0)" }.joined(separator: ", ") }
        if let detail = verdict.detail { text += ": " + detail }
        return text + "."
    }

    private func decide(_ present: Bool) {
        let key = "\(call.modeID)|\(call.sessionKey)"
        analysis.act { env in
            _ = try LabelBookStore(env: env).update { $0.toughCalls[key] = present }
            return "Noted: \(present ? "present" : "not present")."
        }
    }
}

private struct SpotCheckCard: View {
    @Environment(AnalysisModel.self) private var analysis
    let ref: NoteRef

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PoolNoteView(ref: ref, data: analysis.data)
            HStack {
                Button("Agree", systemImage: "hand.thumbsup") { decide(true) }
                Button("Disagree", systemImage: "hand.thumbsdown") { decide(false) }
            }
            .controlSize(.small)
        }
        .card()
    }

    private func decide(_ agree: Bool) {
        let key = ref.description
        analysis.act { env in
            _ = try LabelBookStore(env: env).update { $0.spotChecks[key] = agree }
            return "Noted."
        }
    }
}

private struct UmbrellaCard: View {
    @Environment(AnalysisModel.self) private var analysis
    let umbrella: ReviewQueue.Umbrella
    @Binding var action: ModeAction?

    var body: some View {
        let mode = analysis.data.mode(umbrella.modeID)
        VStack(alignment: .leading, spacing: 6) {
            Text(mode?.name ?? umbrella.modeID).fontWeight(.semibold)
            Text(String(format: "Takes %.0f%% of the routed notes (%d).", umbrella.share * 100, umbrella.notes))
            if let mode {
                HStack {
                    Button("Edit…") { action = .edit(mode) }
                    Button("Split…") { action = .split(mode) }
                }
                .controlSize(.small)
            }
        }
        .card()
    }
}

extension View {
    /// A queue item: padded, on a light rounded background.
    func card() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
