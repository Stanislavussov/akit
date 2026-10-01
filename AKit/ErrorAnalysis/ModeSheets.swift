import AKitErrorAnalysis
import AKitFoundation
import SwiftUI

/// A change to one mode that needs a form: shown as a sheet from the mode page and the
/// review queue alike.
enum ModeAction: Identifiable {
    case rename(Mode), edit(Mode), scope(Mode), merge(Mode), split(Mode), reject(Mode), history

    var id: String {
        switch self {
        case .rename(let mode): "rename|\(mode.id)"
        case .edit(let mode): "edit|\(mode.id)"
        case .scope(let mode): "scope|\(mode.id)"
        case .merge(let mode): "merge|\(mode.id)"
        case .split(let mode): "split|\(mode.id)"
        case .reject(let mode): "reject|\(mode.id)"
        case .history: "history"
        }
    }
}

struct ModeActionSheet: View {
    let action: ModeAction

    var body: some View {
        switch action {
        case .rename(let mode): RenameModeSheet(mode: mode)
        case .edit(let mode): EditModeSheet(mode: mode)
        case .scope(let mode): ScopeModeSheet(mode: mode)
        case .merge(let mode): MergeModeSheet(mode: mode)
        case .split(let mode): SplitModeSheet(mode: mode)
        case .reject(let mode): RejectModeSheet(mode: mode)
        case .history: ModeHistorySheet()
        }
    }
}

/// Title, explanation, the form, an error line and Cancel / the action button.
private struct ModeForm<Content: View>: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(\.dismiss) private var dismiss
    let title: String
    var detail: String?
    let button: String
    var role: ButtonRole?
    let enabled: Bool
    let work: @Sendable (HarnessEnvironment) async throws -> String?
    @ViewBuilder let content: Content
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            content
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(button, role: role, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!enabled || busy)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func save() {
        busy = true
        error = nil
        Task {
            do {
                try await analysis.run(work)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

private struct RenameModeSheet: View {
    let mode: Mode
    @State private var name: String

    init(mode: Mode) {
        self.mode = mode
        _name = State(initialValue: mode.name)
    }

    var body: some View {
        let id = mode.id, name = name
        ModeForm(title: "Rename Mode", detail: "The id \(mode.id) stays, so results and exemplars keep pointing at it.", button: "Rename",
                 enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty && name != mode.name) { env in
            "Renamed to \(try await ModeStore(env: env).rename(id, to: name).name)."
        } content: {
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
        }
    }
}

private struct EditModeSheet: View {
    let mode: Mode
    @State private var definition: String
    @State private var include: String
    @State private var exclude: String
    @State private var kind: Mode.Kind

    init(mode: Mode) {
        self.mode = mode
        _definition = State(initialValue: mode.definition)
        _include = State(initialValue: mode.include.joined(separator: "\n"))
        _exclude = State(initialValue: mode.exclude.joined(separator: "\n"))
        _kind = State(initialValue: mode.kind)
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        let id = mode.id, definition = definition, include = Self.lines(include), exclude = Self.lines(exclude), kind = kind
        ModeForm(title: "Edit \(mode.name)",
                 detail: "A changed definition, criteria or kind makes this v\(mode.version + 1) and invalidates the mode's test metrics: its check has to be validated again.",
                 button: "Save", enabled: !definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { env in
            let change = try await ModeStore(env: env).edit(id, definition: definition, include: include, exclude: exclude, kind: kind)
            return change.invalidations.isEmpty ? "Nothing changed."
                : change.invalidations.map { "\($0.modeID) is now v\($0.version): \($0.reason)." }.joined(separator: " ")
        } content: {
            Form {
                Picker("Kind", selection: $kind) {
                    ForEach(Mode.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                LabeledContent("Definition") { TextEditor(text: $definition).frame(height: 60) }
                LabeledContent("Include") { TextEditor(text: $include).frame(height: 70) }
                LabeledContent("Exclude") { TextEditor(text: $exclude).frame(height: 70) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: 330)
            Text("One criterion per line.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ScopeModeSheet: View {
    @Environment(AppModel.self) private var model
    let mode: Mode
    @State private var general: Bool
    @State private var project: String

    init(mode: Mode) {
        self.mode = mode
        if case .project(let id) = mode.scope {
            _general = State(initialValue: false)
            _project = State(initialValue: id)
        } else {
            _general = State(initialValue: true)
            _project = State(initialValue: "")
        }
    }

    var body: some View {
        let id = mode.id, scope: Mode.Scope = general ? .general : .project(project.trimmingCharacters(in: .whitespaces))
        ModeForm(title: "Scope of \(mode.name)", detail: "Scope only filters reports; matching sees every mode.", button: "Save",
                 enabled: general || !project.trimmingCharacters(in: .whitespaces).isEmpty) { env in
            "Scope: \(try await ModeStore(env: env).setScope(id, scope).scope)."
        } content: {
            Picker("Scope", selection: $general) {
                Text("General").tag(true)
                Text("One project").tag(false)
            }
            .pickerStyle(.radioGroup)
            HStack {
                TextField("Project id", text: $project, prompt: Text("github.com/acme/app"))
                    .textFieldStyle(.roundedBorder)
                Menu("Projects") {
                    ForEach(model.brainProjectFolders.keys.sorted(), id: \.self) { id in Button(id) { project = id } }
                }
                .fixedSize()
                .disabled(model.brainProjectFolders.isEmpty)
            }
            .disabled(general)
        }
    }
}

private struct MergeModeSheet: View {
    @Environment(AnalysisModel.self) private var analysis
    let mode: Mode
    @State private var target = ""

    var body: some View {
        let id = mode.id, target = target
        ModeForm(title: "Merge \(mode.name) into…",
                 detail: "The mode leaves the current list and its notes count for the other one, whose version goes up. Past results are recounted through the merge.",
                 button: "Merge", enabled: !target.isEmpty) { env in
            try await ModeStore(env: env).merge([id], into: target)
            return "Merged \(id) into \(target)."
        } content: {
            Picker("Into", selection: $target) {
                Text("Choose a mode").tag("")
                ForEach(analysis.data.current.filter { $0.id != mode.id }) { Text($0.name).tag($0.id) }
            }
        }
    }
}

private struct SplitModeSheet: View {
    struct Part: Identifiable {
        let id = UUID()
        var name = ""
        var definition = ""
    }

    let mode: Mode
    @State private var parts = [Part(), Part()]

    var body: some View {
        let id = mode.id, kind = mode.kind
        let filled = parts.map { ($0.name.trimmingCharacters(in: .whitespaces), $0.definition.trimmingCharacters(in: .whitespacesAndNewlines)) }
        ModeForm(title: "Split \(mode.name)",
                 detail: "Narrower modes replace it. They start at v1 as candidates; this one is kept, rejected as \"split into …\".",
                 button: "Split", enabled: filled.count >= 2 && filled.allSatisfy { !$0.0.isEmpty && !$0.1.isEmpty }) { env in
            let store = ModeStore(env: env)
            var taken = Set(try await store.list().map(\.id))
            let modes = filled.map { name, definition in
                let slug = Clustering.slug(name, taken: taken)
                taken.insert(slug)
                return Mode(id: slug, name: name, kind: kind, definition: definition)
            }
            let change = try await store.split(id, into: modes)
            return "Split \(id) into \(change.modes.filter { $0.id != id }.map(\.name).joined(separator: ", "))."
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($parts) { $part in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                TextField("Name", text: $part.name).textFieldStyle(.roundedBorder)
                                if parts.count > 2 {
                                    Button("Remove", systemImage: "minus.circle") { parts.removeAll { $0.id == part.id } }
                                        .labelStyle(.iconOnly)
                                        .buttonStyle(.borderless)
                                }
                            }
                            TextField("Definition: one or two sentences", text: $part.definition, axis: .vertical)
                                .lineLimit(2...4)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
            Button("Add Part", systemImage: "plus") { parts.append(Part()) }
        }
    }
}

private struct RejectModeSheet: View {
    let mode: Mode
    @State private var reason = ""

    var body: some View {
        let id = mode.id, reason = reason
        ModeForm(title: "Reject \(mode.name)", detail: "The mode is kept with the reason, so the model doesn't propose it again.",
                 button: "Reject", role: .destructive, enabled: !reason.trimmingCharacters(in: .whitespaces).isEmpty) { env in
            try await ModeStore(env: env).reject(id, reason: reason)
            return "Rejected \(id)."
        } content: {
            TextField("Rejected because…", text: $reason, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// The commits of the modes repository: every change to the list.
private struct ModeHistorySheet: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(\.dismiss) private var dismiss
    struct Entry: Identifiable {
        let id: Int
        let date: Date
        let message: String
    }

    @State private var entries: [Entry]?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("History of the Modes").font(.title2.bold())
            Text("~/.akit/lab/analysis is a local git repository: every change to the list is a commit.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(entries ?? []) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 150, alignment: .leading)
                    Text(entry.message).textSelection(.enabled)
                }
            }
            .overlay {
                if entries == nil, error == nil { ProgressView() }
            }
            .frame(height: 340)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .task {
            let env = analysis.env
            do {
                let history = try await Task.detached { try await ModeStore(env: env).history(limit: 200) }.value
                entries = history.enumerated().map { Entry(id: $0.offset, date: $0.element.date, message: $0.element.message) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
