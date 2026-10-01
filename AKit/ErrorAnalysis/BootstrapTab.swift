import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import SwiftUI

/// Bootstrap labeling (`docs/design/error-analysis.md`, "Bootstrap labeling"): the user's
/// own notes on 30+ reserved sessions, written blind, then compared with the model's.
struct BootstrapTab: View {
    enum Selection: Hashable {
        case overview
        case session(String)
    }

    @Environment(AnalysisModel.self) private var analysis
    @Environment(AppModel.self) private var model
    /// Snapshots: `--select <session key>` opens its labeling view.
    @State private var selection: Selection? = DebugSnapshot.options?.select.map(Selection.session) ?? .overview
    @State private var showPick = false
    @State private var showNotes = false

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            Group {
                switch selection {
                case .session(let key):
                    if let entry = analysis.data.reservations.first(where: { $0.sessionKey == key }) {
                        if entry.labeledAt == nil {
                            BootstrapLabelingView(entry: entry, title: title(of: entry)).id(key)
                        } else {
                            BootstrapFinishedView(entry: entry, title: title(of: entry)).id(key)
                        }
                    } else {
                        ContentUnavailableView("Not reserved", systemImage: "questionmark.folder",
                                               description: Text("This session isn't reserved for the bootstrap."))
                    }
                case .overview, nil:
                    BootstrapOverview()
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showPick) { PickSessionsSheet() }
        .sheet(isPresented: $showNotes) { QueueModelNotesSheet() }
    }

    private func title(of entry: BootstrapReservations.Entry) -> String {
        model.sessions.first { $0.file.path == entry.transcript }?.title ?? entry.sessionKey
    }

    private var sidebar: some View {
        let data = analysis.data
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(data.labeledCount) of \(data.reservations.count) labeled").font(.headline)
                Text("At least \(Bootstrap.minimumSessions) are needed.").foregroundStyle(.secondary)
                Text("Since the list of modes last changed: \(data.sinceLastChange) (stop after \(Bootstrap.stopAfter))")
                    .foregroundStyle(data.sinceLastChange >= Bootstrap.stopAfter ? .green : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Pick Sessions…", systemImage: "plus") { showPick = true }
                        .help("Reserve sessions to label: cluster representatives and random ones")
                    Button("Queue Model Notes…", systemImage: "flask") { showNotes = true }
                        .disabled(data.labeledCount == 0)
                        .help("One Lab batch: the model's notes on every labeled session, to pair with yours")
                }
                .controlSize(.small)
            }
            .font(.callout)
            .padding(12)
            List(selection: $selection) {
                Label("Metrics and Mapping", systemImage: "chart.bar.doc.horizontal").tag(Selection.overview)
                Section("Reserved sessions") {
                    ForEach(data.reservations, id: \.sessionKey) { entry in
                        HStack {
                            Text(title(of: entry)).lineLimit(1)
                            Spacer()
                            stateBadge(entry, label: data.labels[entry.sessionKey])
                        }
                        .tag(Selection.session(entry.sessionKey))
                    }
                }
            }
            .overlay {
                if data.reservations.isEmpty, analysis.loaded {
                    ContentUnavailableView("No sessions reserved", systemImage: "tray",
                                           description: Text("Pick Sessions… reserves sessions from the session index for you to label first."))
                }
            }
        }
    }

    private func stateBadge(_ entry: BootstrapReservations.Entry, label: Bootstrap.Label?) -> some View {
        let (text, color): (String, Color) = entry.labeledAt != nil ? ("labeled", .green) : label == nil ? ("to label", .secondary) : ("draft", .orange)
        return Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Reserves sessions for labeling: half cluster representatives, half random. They stay out
/// of reviews and batches until labeled.
private struct PickSessionsSheet: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(\.dismiss) private var dismiss
    @State private var count = Bootstrap.minimumSessions
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick Sessions to Label").font(.title2.bold())
            Text("From the session index: half are representatives of its clusters (project × kind of session), the rest random. Picked sessions stay out of reviews and batches until you have labeled them, so your labels stay blind.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Stepper("Sessions: \(count)", value: $count, in: 1...100)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Reserve", action: pick).keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func pick() {
        busy = true
        error = nil
        let count = count
        Task {
            do {
                try await analysis.run { env in
                    let entries = try Bootstrap.pick(count: count, env: env)
                    return "Reserved \(entries.count) sessions for labeling."
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
