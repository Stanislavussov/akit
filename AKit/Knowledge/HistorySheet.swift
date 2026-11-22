import AKitKnowledge
import SwiftUI

/// History… of a note or a map (K40): every version from the base's git, newest first, renames
/// followed. The selected one shows what Restore would change, or its whole text; Restore… writes
/// it back as a new commit after a confirmation, so the version before stays in the history.
struct HistorySheet: View {
    @Environment(KnowledgeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var history: Result<KnowledgeHistory, KnowledgeBase.Failure>?
    @State private var selection: KnowledgeHistory.Version.ID?
    @State private var showing = Showing.changes
    @State private var plan: Result<KnowledgeRestorePlan, KnowledgeBase.Failure>?
    @State private var text = ""
    @State private var confirming = false
    @State private var working = false

    enum Showing: String, CaseIterable { case changes = "Changes", text = "Text" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("History of \(KnowledgeModel.historyName(id))").font(.title3.bold())
            switch history {
            case nil:
                ProgressView().frame(maxWidth: .infinity, minHeight: 360)
            case .failure(let failure)?:
                Text(failure.message).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
            case .success(let history)?:
                Text(KnowledgeModel.summary(of: history) + ". Every version stays here: a restore is a new version too.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HSplitView {
                    List(history.versions, selection: $selection) { version in
                        VersionRow(version: version)
                    }
                    .frame(minWidth: 260, idealWidth: 300)
                    detail(history)
                        .frame(minWidth: 380)
                }
                .frame(height: 380)
            }
            HStack {
                if case .success(let plan)? = plan, plan.history.kind == .map {
                    Text("A map's changes show as its blocks and arrows.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                Button("Restore This Version…") { confirming = true }
                    .disabled(working || restorable == nil)
                    .help("Put the \(kindName) back as it was in this version: the version now is backed up and stays in the history")
            }
        }
        .padding(20)
        .frame(width: 820)
        .task {
            let loaded = await model.loadHistory(of: id)
            history = loaded
            if case .success(let history) = loaded {
                selection = history.versions.dropFirst(history.pending ? 0 : 1).first { $0.change != .deleted }?.id ?? history.versions.first?.id
            }
        }
        .task(id: selection) { await loadSelection() }
        .confirmationDialog("Restore \(KnowledgeModel.historyName(id)) to this version?", isPresented: $confirming) {
            Button("Restore") {
                guard let restorable else { return }
                working = true
                Task {
                    if await model.restore(restorable) { dismiss() }
                    working = false
                }
            }
        } message: {
            if let restorable {
                Text("Writes the version of \(restorable.version.date.formatted(date: .abbreviated, time: .shortened)) (\(restorable.version.message)) and commits it. Your edits not committed yet are committed first; the \(kindName) as it is now is backed up in ~/.akit/local/backups/knowledge and stays in the history.")
            }
        }
    }

    private var kindName: String {
        if case .success(let history)? = history, history.kind == .map { return "map" }
        return "note"
    }

    /// The plan of the selected version when it changes something.
    private var restorable: KnowledgeRestorePlan? {
        if case .success(let plan)? = plan, plan.changes { return plan }
        return nil
    }

    @ViewBuilder private func detail(_ history: KnowledgeHistory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Show", selection: $showing) {
                ForEach(Showing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Changes: what Restore would change in the \(kindName) as it is now. Text: the whole \(kindName) in this version")
            GroupBox {
                ScrollView {
                    Text(detailText)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, 8)
    }

    private var detailText: String {
        guard let version = selectedVersion else { return "Pick a version." }
        if version.change == .deleted { return "This version removed the \(kindName): pick the one before it to bring it back." }
        if showing == .text { return text }
        switch plan {
        case nil: return ""
        case .failure(let failure)?: return failure.message
        case .success(let plan)?: return plan.changes ? plan.diff : "The \(kindName) is the same as this version now."
        }
    }

    private var selectedVersion: KnowledgeHistory.Version? {
        guard case .success(let history)? = history else { return nil }
        return history.versions.first { $0.id == selection }
    }

    private func loadSelection() async {
        (plan, text) = (nil, "")
        guard let version = selectedVersion, version.change != .deleted else { return }
        plan = await model.planRestore(id, to: version)
        text = await model.contents(of: version)
    }
}

/// One version in History…: its date, the commit's message, the short hash and what it did.
private struct VersionRow: View {
    let version: KnowledgeHistory.Version

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(version.date.formatted(date: .abbreviated, time: .shortened)).font(.callout.weight(.medium))
                Spacer()
                Text(version.short).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(version.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let change {
                Text(change).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .help("\(version.commit)\n\(version.path)")
    }

    private var change: String? {
        switch version.change {
        case .added: "Created"
        case .deleted: "Removed"
        case .renamed: "Renamed from \(version.from.map { String($0.dropFirst("areas/".count)) } ?? "?")"
        case .changed: nil
        }
    }
}

extension KnowledgeModel {
    /// A note's name or a map's, for titles.
    static func historyName(_ id: String) -> String {
        id.contains("/maps/") ? mapName(id) : String(id.split(separator: "/").last ?? Substring(id))
    }

    /// "Changed 22 Nov 2026 at 16:32 · created 3 Nov 2026 · 7 versions", and edits not committed yet.
    static func summary(of history: KnowledgeHistory) -> String {
        var parts: [String] = []
        if let changed = history.changed { parts.append("Changed " + changed.formatted(date: .abbreviated, time: .shortened)) }
        if let created = history.created { parts.append("created " + created.formatted(date: .abbreviated, time: .omitted)) }
        parts.append(history.versions.count == 1 ? "1 version" : "\(history.versions.count) versions")
        if history.pending { parts.append("edits not committed yet") }
        return parts.joined(separator: " · ")
    }
}
