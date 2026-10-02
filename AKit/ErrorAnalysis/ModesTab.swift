import AKitErrorAnalysis
import SwiftUI

/// The list of modes as a table; the selected mode's page below it.
struct ModesTab: View {
    @Environment(AnalysisModel.self) private var analysis
    @Binding var action: ModeAction?
    /// Snapshots: `--select <mode id>` opens its page.
    @State private var selection: Mode.ID? = DebugSnapshot.options?.select
    @State private var showAll = false

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                header
                table
            }
            .frame(maxWidth: .infinity, minHeight: 180, idealHeight: 280)
            Group {
                if let id = selection, analysis.data.mode(id) != nil {
                    ModePage(id: id, action: $action) { selection = $0 }
                        .id(id)
                } else {
                    ContentUnavailableView("Select a Mode", systemImage: "list.bullet.clipboard",
                                           description: Text("A mode is a pattern with a definition and criteria, seen in reviewed sessions. Its page shows the notes routed to it and its code check."))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
        }
    }

    private var modes: [Mode] {
        let modes = showAll ? analysis.data.modes : analysis.data.current
        // Active first, then candidates, inactive seeds, and the ones that left the list.
        func rank(_ mode: Mode) -> Int {
            if mode.mergedInto != nil { return 4 }
            switch mode.status {
            case .active: return 0
            case .candidate: return 1
            case .seedInactive: return 2
            case .rejected: return 3
            }
        }
        return modes.sorted { (rank($0), $0.name) < (rank($1), $1.name) }
    }

    private var header: some View {
        HStack {
            Picker("Show", selection: $showAll) {
                Text("Current").tag(false)
                Text("All").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Current: neither merged nor rejected. All: every mode ever made; modes are never deleted.")
            let unmatched = analysis.data.unmatched.count
            Text("\(modes.count) modes · \(unmatched) \(unmatched == 1 ? "note fits" : "notes fit") none")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var table: some View {
        let data = analysis.data
        return Table(modes, selection: $selection) {
            TableColumn("Name") { mode in
                Text(mode.name).help(mode.definition)
            }
            .width(min: 160, ideal: 230)
            TableColumn("Status") { mode in ModeStatusBadge(mode: mode) }
                .width(min: 70, ideal: 90)
            TableColumn("Kind") { mode in Text(mode.kind.rawValue) }
                .width(min: 50, ideal: 70)
            TableColumn("Origin") { mode in Text(mode.origin.title).foregroundStyle(.secondary) }
                .width(min: 50, ideal: 100)
            TableColumn("Scope") { mode in Text(mode.scope.description).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 50, ideal: 70)
            TableColumn("Ver.") { mode in Text("v\(mode.version)").monospacedDigit() }
                .width(min: 30, ideal: 36)
            TableColumn("Seen in") { mode in
                let count = data.seenByMode[mode.id]?.count ?? 0
                Text("\(count) \(count == 1 ? "note" : "notes")").monospacedDigit()
                    .foregroundStyle(count == 0 ? .secondary : .primary)
            }
            .width(min: 60, ideal: 70)
            TableColumn("Code check") { mode in CheckCell(mode: mode, results: data.checks[mode.id]) }
                .width(min: 120, ideal: 210)
        }
        .contextMenu(forSelectionType: Mode.ID.self) { ids in
            if let id = ids.first, let mode = data.mode(id) {
                ModeActions(mode: mode, action: $action, menu: true)
            }
        }
    }
}

/// "3 of 40 (95% 2–20%) · mechanical", or "heuristic — not validated".
private struct CheckCell: View {
    let mode: Mode
    let results: CheckResults?

    var body: some View {
        if let check = CodeChecks.check(for: mode.id) {
            HStack(spacing: 4) {
                if let results, let rate = AnalysisText.rate(results) {
                    Text(rate).monospacedDigit()
                } else {
                    Text("not run").foregroundStyle(.secondary)
                }
                Text(check.kind == .mechanical ? "· mechanical" : "· heuristic — not validated")
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .help(check.summary)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}

extension Mode.Origin {
    var title: String {
        switch self {
        case .seedPrior: "seed (ours)"
        case .seedLiterature: "seed (studies)"
        case .emergent: "emergent"
        }
    }
}

/// The actions on one mode, as buttons on its page or items of a context menu.
struct ModeActions: View {
    @Environment(AnalysisModel.self) private var analysis
    let mode: Mode
    @Binding var action: ModeAction?
    var menu = false
    /// Called after Confirm, so the page can offer the follow-ups.
    var confirmed: (() -> Void)?

    var body: some View {
        let id = mode.id
        if mode.isCurrent, mode.status == .candidate || mode.status == .seedInactive {
            Button("Confirm", systemImage: "checkmark.circle") {
                let mode = mode
                Task {
                    do {
                        try await analysis.run { env in
                            let mode = try await ModeStore(env: env).confirm(id)
                            return "\(mode.name) is active."
                        }
                    } catch {
                        analysis.error = error.localizedDescription
                        return
                    }
                    // A confirmed mode's code check runs over every indexed session at once.
                    analysis.runCheck(mode)
                    confirmed?()
                }
            }
            .help("Make it an active mode: it shows in reports and gets a check")
        }
        Button("Rename…", systemImage: "pencil") { action = .rename(mode) }
        if mode.mergedInto == nil {
            Button("Edit…", systemImage: "square.and.pencil") { action = .edit(mode) }
                .help("Definition, criteria and kind; bumps the version")
        }
        Button("Scope…", systemImage: "scope") { action = .scope(mode) }
        if mode.isCurrent {
            Button("Merge into…", systemImage: "arrow.triangle.merge") { action = .merge(mode) }
            Button("Split…", systemImage: "arrow.triangle.branch") { action = .split(mode) }
        }
        if menu { Divider() }
        if mode.status == .rejected {
            Button("Restore", systemImage: "arrow.uturn.backward") {
                analysis.act { env in "\(id) is \(try await ModeStore(env: env).restore(id).status.title) again." }
            }
        } else {
            Button("Reject…", systemImage: "xmark.circle", role: .destructive) { action = .reject(mode) }
        }
    }
}
