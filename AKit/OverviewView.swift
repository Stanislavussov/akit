import AKitCore
import AppKit
import SwiftUI

/// Overview screen: which harnesses were found and where their configs live.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: EditTarget?

    /// Which sheet is open: a new harness or an existing custom one.
    enum EditTarget: Identifiable {
        case new
        case existing(CustomHarness)
        var id: String {
            switch self {
            case .new: "new"
            case .existing(let harness): "edit:" + harness.id
            }
        }
    }

    var body: some View {
        Group {
            if model.installations.isEmpty && !model.isScanning {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "No harnesses found",
                        systemImage: "questionmark.folder",
                        description: Text("Use + to describe a harness AKit doesn't know yet.")
                    )
                    footer.padding(20)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.installations) { item in
                            HarnessCard(installation: item, version: model.versions[item.id],
                                        onEdit: customDefinition(item).map { harness in { editing = .existing(harness) } })
                        }
                        footer
                    }
                    .padding(20)
                    .frame(maxWidth: 900, alignment: .leading)
                }
            }
        }
        .navigationTitle("Overview")
        .sheet(item: $editing) { target in
            switch target {
            case .new: HarnessEditorView()
            case .existing(let harness): HarnessEditorView(harness: harness)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Add Harness…", systemImage: "plus") { editing = .new }
                    .help("Describe another harness (OpenCode, Goose, …) so AKit can show it")
            }
            ToolbarItem {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                    .help("Re-detect harnesses (⌘R)")
                }
            }
        }
    }

    private func customDefinition(_ installation: HarnessInstallation) -> CustomHarness? {
        guard installation.isCustom else { return nil }
        return model.customHarnesses.first { $0.harnessID == installation.id }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Only installed harnesses are shown. Checked: \(model.checkedAdapters.joined(separator: ", ")).")
            let missing = model.customHarnesses.filter { harness in
                !model.installations.contains { $0.id == harness.harnessID }
            }
            if !missing.isEmpty {
                HStack(spacing: 8) {
                    Text("Your harnesses not found on this Mac:")
                    ForEach(missing) { harness in
                        Button(harness.name) { editing = .existing(harness) }
                            .buttonStyle(.link)
                    }
                }
            }
            if let error = model.customHarnessError {
                Label("~/.akit/harnesses.json can't be read: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

private struct HarnessCard: View {
    @Environment(AppModel.self) private var model
    let installation: HarnessInstallation
    let version: String?
    /// Set for harnesses described by the user.
    let onEdit: (() -> Void)?
    @State private var confirmRemove = false
    @State private var removeError: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let exe = installation.executableURL {
                    InfoRow(label: "Executable", value: exe.tildePath)
                } else {
                    InfoRow(label: "Executable", value: "not found in PATH, only the config folder exists")
                }
                InfoRow(label: "Config", value: installation.configRoot.tildePath)

                Divider()

                ForEach(installation.locations) { location in
                    LocationRow(location: location)
                }
            }
            .padding(6)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(installation.displayName).font(.title2.bold())
                if let version {
                    Text(version).font(.callout).foregroundStyle(.secondary)
                }
                if let onEdit {
                    Text("Custom").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit…", action: onEdit).controlSize(.small)
                    Button("Remove…", role: .destructive) { confirmRemove = true }.controlSize(.small)
                }
            }
        }
        .confirmationDialog("Remove “\(installation.displayName)” from AKit?", isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let harness = model.customHarnesses.first(where: { $0.harnessID == installation.id }) {
                    do {
                        try model.removeCustomHarness(harness)
                    } catch {
                        removeError = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("Only its description in ~/.akit/harnesses.json is removed. The harness and its files stay untouched.")
        }
        .alert("Couldn't remove", isPresented: Binding(get: { removeError != nil }, set: { if !$0 { removeError = nil } })) {
            Button("OK") {}
        } message: {
            Text(removeError ?? "")
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }
}

private struct LocationRow: View {
    let location: ConfigLocation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: location.exists ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(location.exists ? .green : .secondary)
                .help(location.exists ? "Exists" : "Not created yet")
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(location.title)
                Text(location.url.tildePath)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let dest = location.symlinkDestination {
                    Label("symlink to \(dest.tildePath)", systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(location.exists ? Color.secondary : Color.red)
                }
                if let note = location.note {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
            }

            Spacer()

            if ExternalEditor.appURL != nil {
                Button {
                    ExternalEditor.open(location.url)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .disabled(!location.exists)
                .help("Open in \(ExternalEditor.name)")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([location.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .disabled(!location.exists)
            .help("Show in Finder")
        }
        .opacity(location.exists ? 1 : 0.6)
    }
}
