import AKitCore
import AppKit
import SwiftUI

/// skills.sh screen: search the public skills directory and install a skill
/// into the chosen harnesses, globally or into one project, as is or as your own copy.
struct SkillsShView: View {
    @Environment(AppModel.self) private var model
    @State private var query = DebugSnapshot.options?.query ?? ""
    @State private var results: [RemoteSkill] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var selection: RemoteSkill.ID?

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
            Group {
                if let remote = results.first(where: { $0.id == selection }) {
                    RemoteSkillDetailView(remote: remote)
                        .id(remote.id)
                } else {
                    ContentUnavailableView("Select a skill", systemImage: "sparkle.magnifyingglass",
                                           description: Text("Pick a search result to preview and install it."))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("skills.sh")
        .navigationSubtitle(results.isEmpty ? "" : "\(results.count) results")
        .searchable(text: $query, placement: .toolbar, prompt: "Search skills.sh")
        .toolbar {
            ToolbarItem {
                Link(destination: SkillsShClient.base) {
                    Label("Open skills.sh", systemImage: "safari")
                }
                .help("Open skills.sh in the browser")
            }
        }
        .task(id: query) { await search() }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(results) { remote in
                RemoteSkillRow(remote: remote, installed: isInstalled(remote))
                    .tag(remote.id)
                    .contextMenu {
                        Button("Open on skills.sh") { NSWorkspace.shared.open(remote.pageURL) }
                        if let repo = remote.repoURL {
                            Button("Open on GitHub") { NSWorkspace.shared.open(repo) }
                        }
                    }
            }
        }
        .overlay {
            if let searchError {
                ContentUnavailableView("Search failed", systemImage: "wifi.exclamationmark", description: Text(searchError))
            } else if trimmedQuery.count < SkillsShClient.minimumQueryLength {
                ContentUnavailableView("Search skills.sh", systemImage: "magnifyingglass",
                                       description: Text("Type what the skill should help with, e.g. “tdd” or “react”."))
            } else if isSearching && results.isEmpty {
                ProgressView()
            } else if results.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Debounced: runs 350 ms after typing stops; a newer query cancels this one.
    private func search() async {
        let q = trimmedQuery
        guard q.count >= SkillsShClient.minimumQueryLength else {
            results = []
            searchError = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await SkillsShClient.search(q)
            guard !Task.isCancelled else { return }
            results = found
            searchError = nil
            if selection.flatMap({ id in found.first { $0.id == id } }) == nil {
                // Snapshots show the first result; normally nothing is downloaded until you pick one.
                selection = DebugSnapshot.options != nil ? found.first?.id : nil
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            results = []
            searchError = error.localizedDescription
        }
    }

    private func isInstalled(_ remote: RemoteSkill) -> Bool {
        let published = InstalledSkillLock.publishedOrigin(remote.source)
        let origins: Set<String> = [remote.source, published, published + " (renamed)"]
        return model.skills.contains { $0.name == remote.name && $0.origin.map(origins.contains) == true }
    }
}

private struct RemoteSkillRow: View {
    let remote: RemoteSkill
    let installed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(remote.name).fontWeight(.medium).lineLimit(1)
                if installed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                        .help("Already installed")
                }
                Spacer()
                Label(remote.installs.compactCount, systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("\(remote.installs) installs")
            }
            Text(remote.source)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

/// Preview of one skill and the install form.
private struct RemoteSkillDetailView: View {
    @Environment(AppModel.self) private var model
    let remote: RemoteSkill

    @State private var fetched: FetchedSkill?
    @State private var fetchError: String?

    // Install options.
    @State private var harnesses: Set<HarnessID> = []
    @State private var scope: InstallScope = .global
    @State private var name = ""
    @State private var mode: InstallRequest.Mode = DebugSnapshot.options?.ownCopy == true ? .ownCopy : .published
    /// Your version of SKILL.md for "My own copy".
    @State private var editedText = ""

    // Planned install, recomputed only when the options change (it reads harness files).
    @State private var targets: [InstallTarget] = []
    @State private var conflicts: [URL] = []
    @State private var blockedConflicts: [URL] = []

    @State private var isInstalling = false
    @State private var confirmReplace = false
    @State private var installError: String?
    @State private var installed: [URL] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let fetched {
                    installForm(fetched)
                    preview(fetched)
                } else if let fetchError {
                    Label(fetchError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Downloading \(remote.source)…").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
        .task(id: planKey) { plan() }
        .confirmationDialog("Replace the existing skill?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Move Old to Trash and Install", role: .destructive) { install(replace: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(conflicts.map(\.tildePath).joined(separator: "\n")
                 + "\n\nThe existing folder goes to the Trash; you can put it back from there.")
        }
        .alert("Couldn't install the skill", isPresented: Binding(get: { installError != nil }, set: { if !$0 { installError = nil } })) {
            Button("OK") {}
        } message: {
            Text(installError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(fetched?.name ?? remote.name).font(.title2.bold()).textSelection(.enabled)
                Spacer()
                Button("skills.sh", systemImage: "safari") { NSWorkspace.shared.open(remote.pageURL) }
                    .help("Open this skill on skills.sh")
                if let repo = remote.repoURL {
                    Button("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") {
                        NSWorkspace.shared.open(repo.appending(path: fetched.map { "tree/HEAD/\($0.pathInRepo)" } ?? ""))
                    }
                    .help("Open the source on GitHub")
                }
            }
            HStack(spacing: 12) {
                Label(remote.source, systemImage: "shippingbox")
                Label("\(remote.installs.formatted()) installs", systemImage: "arrow.down.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let description = fetched?.description, !description.isEmpty {
                Text(description).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    // MARK: - Install form

    private func installForm(_ fetched: FetchedSkill) -> some View {
        GroupBox {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label("Install as")
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Install as", selection: $mode) {
                            Text("Author's version").tag(InstallRequest.Mode.published)
                            Text("My own copy").tag(InstallRequest.Mode.ownCopy)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Text(mode == .published
                             ? "Installed exactly as published, linked to \(remote.source)."
                             : "Change SKILL.md below and save it as your skill. AKit remembers it was based on \(remote.source), but it is yours.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    label("For")
                    HStack(spacing: 14) {
                        ForEach(model.installations) { harness in
                            Toggle(harness.displayName, isOn: Binding(
                                get: { harnesses.contains(harness.id) },
                                set: { on in if on { harnesses.insert(harness.id) } else { harnesses.remove(harness.id) } }))
                        }
                        if model.installations.isEmpty {
                            Text("No harness installed").foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    label("Install to")
                    Picker("Install to", selection: $scope) {
                        Text("Global — every project").tag(InstallScope.global)
                        if !model.projects.isEmpty {
                            Divider()
                            ForEach(sortedProjects, id: \.self) { project in
                                Text("Project · \(project.lastPathComponent)").tag(InstallScope.project(project))
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help(scopeHelp)
                }
                GridRow {
                    label("Name")
                    TextField("Skill name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
                GridRow {
                    label("Copies to")
                    VStack(alignment: .leading, spacing: 4) {
                        if targets.isEmpty {
                            Text("Choose a harness").foregroundStyle(.secondary)
                        }
                        ForEach(targets) { target in
                            HStack(spacing: 6) {
                                Text(target.folder(for: name.isEmpty ? "…" : name).tildePath).monospaced()
                                ForEach(target.seenBy, id: \.self) { HarnessBadge(harness: $0) }
                            }
                        }
                    }
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)

            if !problems.isEmpty || !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                    ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
            }

            HStack {
                if !installed.isEmpty {
                    Label(mode == .ownCopy ? "Saved" : "Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(installed) }
                        .buttonStyle(.link)
                    if ExternalEditor.appURL != nil, let first = installed.first {
                        Button("Open in \(ExternalEditor.name)") { ExternalEditor.open(first) }
                            .buttonStyle(.link)
                            .help("Keep changing your copy, including its other files")
                    }
                }
                Spacer()
                if isInstalling { ProgressView().controlSize(.small) }
                Button(conflicts.isEmpty ? (mode == .ownCopy ? "Save as My Skill" : "Install") : "Replace…") {
                    if conflicts.isEmpty { install(replace: false) } else { confirmReplace = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!problems.isEmpty || targets.isEmpty || isInstalling)
            }
            .padding(6)
        } label: {
            Label("Install", systemImage: "square.and.arrow.down")
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private var sortedProjects: [URL] {
        model.projects.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private var scopeHelp: String {
        if case .project(let url) = scope { return url.tildePath }
        return "Your global skill folders"
    }

    /// Changes whenever the planned install could change, including after a rescan.
    private var planKey: String {
        let scopeKey = if case .project(let url) = scope { url.path } else { "global" }
        return [harnesses.map(\.rawValue).sorted().joined(separator: ","), scopeKey, name,
                "\(model.lastScan?.timeIntervalSince1970 ?? 0)"].joined(separator: "|")
    }

    private func plan() {
        targets = model.installTargets(for: model.installations.map(\.id).filter(harnesses.contains), scope: scope)
        conflicts = SkillInstaller.conflicts(name: name, targets: targets)
        blockedConflicts = SkillInstaller.blockedConflicts(name: name, targets: targets)
    }

    private var problems: [String] {
        SkillInstaller.nameProblems(name).map { $0.prefix(1).uppercased() + $0.dropFirst() }
            + blockedConflicts.map { "\($0.tildePath) exists and is not a single skill; choose another name" }
    }

    private var warnings: [String] {
        var result: [String] = []
        if targets.contains(where: { $0.seenBy.contains(.pi) }) {
            result += PiNameRule.problems(name).map { "Pi: \($0)" }
        }
        let missing = harnesses.filter { id in !targets.contains { $0.harnesses.contains(id) } }
        result += missing.sorted().map { "\($0.displayName) has no skills folder for this choice" }
        if !conflicts.isEmpty, blockedConflicts.isEmpty {
            result.append("A skill named “\(name)” already exists there; installing replaces it (the old one goes to the Trash).")
        }
        return result
    }

    // MARK: - Preview

    private func preview(_ fetched: FetchedSkill) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if fetched.files.count > 1 {
                GroupBox("Files (\(fetched.files.count))") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(fetched.files.prefix(200), id: \.self) { file in
                            Text(file).font(.system(.callout, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                    .textSelection(.enabled)
                }
            }
            if mode == .ownCopy {
                GroupBox {
                    TextEditor(text: $editedText)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 360)
                        .scrollContentBackground(.hidden)
                } label: {
                    HStack {
                        Text("SKILL.md — your version")
                        if editedText != fetched.skillText {
                            Text("changed").font(.caption).foregroundStyle(.orange)
                            Button("Reset to Original") { editedText = fetched.skillText }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
            } else {
                GroupBox("SKILL.md") {
                    Text(fetched.skillText)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        do {
            let skill = try await RemoteSkillFetcher.fetch(remote)
            fetched = skill
            editedText = skill.skillText
            name = Self.defaultName(for: skill)
            harnesses = Set(model.installations.map(\.id).filter { [.claudeCode, .pi].contains($0) })
            if harnesses.isEmpty, let first = model.installations.first { harnesses = [first.id] }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            fetchError = error.localizedDescription
        }
    }

    /// The skill's own name when every harness accepts it, otherwise its skills.sh id.
    static func defaultName(for skill: FetchedSkill) -> String {
        let own = skill.name
        if SkillInstaller.nameProblems(own).isEmpty, PiNameRule.problems(own).isEmpty { return own }
        return skill.remote.skillId
    }

    private func install(replace: Bool) {
        guard let fetched else { return }
        let request = InstallRequest(skill: fetched, name: name, mode: mode, editedText: editedText)
        let targets = targets
        isInstalling = true
        Task {
            defer { isInstalling = false }
            do {
                installed = try await model.install(request, into: targets, replace: replace)
            } catch {
                installError = error.localizedDescription
            }
        }
    }
}

extension Int {
    /// 964882 → "965K", 1200000 → "1.2M".
    var compactCount: String { formatted(.number.notation(.compactName).precision(.significantDigits(1...3))) }
}
