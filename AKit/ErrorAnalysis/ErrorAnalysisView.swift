import AKitErrorAnalysis
import SwiftUI

/// Error Analysis: the list of failure modes, the user's review queue, and bootstrap
/// labeling (`docs/design/error-analysis.md`). Everything here is local; model calls show
/// their cost first and go through the sending policy.
struct ErrorAnalysisView: View {
    enum Tab: String, CaseIterable {
        case modes, review, bootstrap

        var title: String {
            switch self {
            case .modes: "Modes"
            case .review: "Review"
            case .bootstrap: "Bootstrap"
            }
        }
    }

    @State private var analysis = AnalysisModel()
    /// Snapshots: `--tab modes|review|bootstrap`.
    @State private var tab = DebugSnapshot.options?.tab.flatMap(Tab.init(rawValue:)) ?? .modes
    @State private var modeAction: ModeAction?

    var body: some View {
        @Bindable var analysis = analysis
        Group {
            switch tab {
            case .modes: ModesTab(action: $modeAction)
            case .review: ReviewQueueTab(action: $modeAction)
            case .bootstrap: BootstrapTab()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { statusBar }
        .navigationTitle("Error Analysis")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab == .review && analysis.data.queue.count > 0 ? "Review (\(analysis.data.queue.count))" : tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Modes: the list of failure modes. Review: what waits for you. Bootstrap: your own notes on 30+ sessions.")
            }
            ToolbarItem {
                Button("History", systemImage: "clock.arrow.circlepath") { modeAction = .history }
                    .help("Every change to the list of modes (a local git repository)")
            }
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") { Task { await analysis.reload() } }
                    .help("Read ~/.akit/lab/analysis again")
            }
        }
        .sheet(item: $modeAction) { ModeActionSheet(action: $0) }
        .sheet(item: $analysis.send) { AnalysisSendSheet(send: $0) }
        .environment(analysis)
        .task {
            await analysis.reload()
            // Snapshots: `--tab review --add` opens the clustering confirmation.
            if DebugSnapshot.options?.add == true, tab == .review { analysis.send = .cluster(analysis.data) }
        }
        // Reviews finish outside AKit: their notes join the pool.
        .onChange(of: finishedReviews) { Task { await analysis.reload() } }
    }

    @Environment(AppModel.self) private var model

    private var finishedReviews: Int { model.labRuns.filter { $0.spec.kind == .review && $0.status == .finished }.count }

    private var subtitle: String {
        let data = analysis.data
        return "\(data.current.count) current modes · \(data.pool.count) reviewed sessions"
    }

    @ViewBuilder private var statusBar: some View {
        if let progress = analysis.progress {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress)
            }
            .font(.callout)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.1))
        } else if let error = analysis.error {
            bar(error, icon: "exclamationmark.triangle", tint: .orange) { analysis.error = nil }
        } else if let message = analysis.message {
            bar(message, icon: "checkmark.circle", tint: .green) { analysis.message = nil }
        }
    }

    private func bar(_ text: String, icon: String, tint: Color, close: @escaping () -> Void) -> some View {
        HStack {
            Label(text, systemImage: icon)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(8)
        .background(tint.opacity(0.15))
    }
}

/// A mode's status as a colored capsule.
struct ModeStatusBadge: View {
    let mode: Mode

    var body: some View {
        Text(mode.mergedInto != nil ? "merged" : mode.status.title)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        if mode.mergedInto != nil { return .secondary }
        switch mode.status {
        case .seedInactive: return .secondary
        case .candidate: return .orange
        case .active: return .green
        case .rejected: return .red
        }
    }
}

/// One pool note: session and step, the description and the quote.
struct PoolNoteView: View {
    let ref: NoteRef
    let data: AnalysisData

    var body: some View {
        if let found = data.note(ref) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(found.session.title ?? ref.sessionKey) · step #\(found.note.step) · \(ref.noteID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(found.note.description).fixedSize(horizontal: false, vertical: true)
                QuoteText(text: found.note.quote)
            }
            .textSelection(.enabled)
        } else if let note = data.anyNote(ref) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(ref.sessionKey) · step #\(note.step) · yours").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(note.description).fixedSize(horizontal: false, vertical: true)
                QuoteText(text: note.quote)
            }
            .textSelection(.enabled)
        } else {
            Text("\(ref.description): the note is no longer in the pool").foregroundStyle(.secondary)
        }
    }
}
