import AKitCore
import AppKit
import SwiftUI

/// skills.sh screen: search the public skills directory and install a skill
/// into one skills folder you choose (global or in a project), as is or as your own copy.
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
    /// The one skills folder to install into (`InstallTarget.id`).
    @State private var folderID: String?
    /// Last chosen kind of folder, e.g. `.claude/skills`, reused as the default.
    @AppStorage("skillsShFolderKind") private var folderKind = ".claude/skills"
    @State private var scope: InstallScope = .global
    /// Folders picked with "Choose Folder…" that AKit didn't find on its own.
    @State private var chosenProjects: [URL] = []
    @State private var name = ""
    @State private var mode: InstallRequest.Mode = DebugSnapshot.options?.ownCopy == true ? .ownCopy : .published
    /// Your version of SKILL.md for "My own copy".
    @State private var editedText = ""

    // Planned install, recomputed only when the options change (it reads harness files).
    /// Every skills folder at the chosen place; the user picks one.
    @State private var options: [InstallTarget] = []
    /// The chosen folder (one element) — the skill is copied only there.
    @State private var targets: [InstallTarget] = []
    @State private var conflicts: [URL] = []
    @State private var blockedConflicts: [URL] = []
    /// Conflicts that are this very skill, installed earlier from the same source.
    @State private var installedHere: [URL] = []

    @State private var isInstalling = false
    @State private var confirmReplace = false
    @State private var installError: String?

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
        .confirmationDialog(otherConflicts.isEmpty ? "Install it again?" : "Replace the existing skill?",
                            isPresented: $confirmReplace, titleVisibility: .visible) {
            Button(otherConflicts.isEmpty ? "Move Current Copy to Trash and Reinstall" : "Move Old to Trash and Install",
                   role: .destructive) { install(replace: true) }
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
                if let repo = sourceURL {
                    Button("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") {
                        NSWorkspace.shared.open(repo)
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
                    label("Where")
                    HStack(spacing: 8) {
                        Picker("Install to", selection: $scope) {
                            Text("Global — every project").tag(InstallScope.global)
                            if !sortedProjects.isEmpty {
                                Divider()
                                ForEach(sortedProjects, id: \.self) { project in
                                    Text("Project · \(project.lastPathComponent)").tag(InstallScope.project(project))
                                }
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help(scopeHelp)
                        Button("Choose Folder…") { chooseProject() }
                            .help("Install into any repository or folder")
                    }
                }
                GridRow {
                    label("Name")
                    TextField("Skill name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
                GridRow {
                    label("Folder")
                    if options.isEmpty {
                        Text("No harness reads skills here").foregroundStyle(.secondary)
                    } else {
                        Picker("Folder", selection: Binding(get: { targets.first?.id }, set: { chooseFolder($0) })) {
                            ForEach(options) { option in
                                HStack(spacing: 6) {
                                    Text(option.folder(for: name.isEmpty ? "…" : name).tildePath).monospaced()
                                    Text("seen by").foregroundStyle(.secondary)
                                    ForEach(option.seenBy, id: \.self) { HarnessBadge(harness: $0) }
                                }
                                .tag(Optional(option.id))
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)

            if !installedHere.isEmpty { installedBlock }

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
                Spacer()
                if isInstalling { ProgressView().controlSize(.small) }
                Button(installButtonTitle) {
                    if conflicts.isEmpty { install(replace: false) } else { confirmReplace = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!problems.isEmpty || targets.isEmpty || isInstalling)
                .help(targets.first.map { "Installs one copy into \($0.folder(for: name).tildePath)" } ?? "")
            }
            .padding(6)
        } label: {
            Label("Install", systemImage: "square.and.arrow.down")
        }
    }

    private var installButtonTitle: String {
        if !otherConflicts.isEmpty { return "Replace…" }
        if !conflicts.isEmpty { return "Reinstall…" }
        return mode == .ownCopy ? "Save as My Skill" : "Install"
    }

    /// Where this skill already is, with ways to open it.
    private var installedBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Installed here", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fontWeight(.medium)
                Spacer()
                if let repo = sourceURL {
                    Button("Open Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") {
                        NSWorkspace.shared.open(repo)
                    }
                    .buttonStyle(.link)
                }
            }
            ForEach(installedHere, id: \.self) { folder in
                HStack(spacing: 10) {
                    Text(folder.tildePath).monospaced().lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Skills") { model.showSkill(inFolder: folder) }
                        .help("Open this skill in AKit's Skills screen")
                    if ExternalEditor.appURL != nil {
                        Button("Open in \(ExternalEditor.name)") { ExternalEditor.open(folder) }
                    }
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    .labelStyle(.iconOnly)
                    .help("Show in Finder")
                }
                .controlSize(.small)
            }
        }
        .font(.callout)
        .padding(8)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
    }

    /// The skill's folder in its GitHub repository.
    private var sourceURL: URL? {
        remote.repoURL.map { repo in fetched.map { repo.appending(path: "tree/HEAD/\($0.pathInRepo)") } ?? repo }
    }

    /// Existing folders under this name that are something else.
    private var otherConflicts: [URL] { conflicts.filter { !installedHere.contains($0) } }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Install Here"
        panel.message = "Choose the repository or folder to install the skill into."
        panel.directoryURL = model.projectRoots.first.map { HarnessEnvironment.current.expand($0) }
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
        if !sortedProjects.contains(where: { $0.standardizedFileURL.path == url.path }) { chosenProjects.append(url) }
        scope = .project(sortedProjects.first { $0.standardizedFileURL.path == url.path } ?? url)
    }

    private var sortedProjects: [URL] {
        (model.projects + chosenProjects).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private var scopeHelp: String {
        if case .project(let url) = scope { return url.tildePath }
        return "Your global skill folders"
    }

    /// Changes whenever the planned install could change, including after a rescan.
    private var planKey: String {
        let scopeKey = if case .project(let url) = scope { url.path } else { "global" }
        return [folderID ?? "", scopeKey, name, "\(model.installations.count)",
                "\(model.lastScan?.timeIntervalSince1970 ?? 0)"].joined(separator: "|")
    }

    private func plan() {
        options = model.installTargets(for: model.installations.map(\.id), scope: scope)
        let chosen = options.first { $0.id == folderID }
            ?? options.first { $0.root.path.hasSuffix("/" + folderKind) }
            ?? options.first { $0.harnesses.contains(.claudeCode) }
            ?? options.first
        targets = chosen.map { [$0] } ?? []
        conflicts = SkillInstaller.conflicts(name: name, targets: targets)
        blockedConflicts = SkillInstaller.blockedConflicts(name: name, targets: targets)
        let lock = (try? InstalledSkillLock.load(in: .current)) ?? InstalledSkillLock()
        // Where this skill already is at this place, in any of its folders.
        installedHere = SkillInstaller.conflicts(name: name, targets: options).filter { folder in
            guard let entry = lock.entry(forSkillFolder: folder) else { return false }
            return entry.source == remote.source && entry.skillId == remote.skillId
        }
    }

    private func chooseFolder(_ id: String?) {
        folderID = id
        if let root = options.first(where: { $0.id == id })?.root {
            folderKind = root.pathComponents.suffix(2).joined(separator: "/")
        }
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
        let others = otherConflicts.filter { !blockedConflicts.contains($0) }
        if !others.isEmpty {
            result.append("A different skill named “\(name)” already exists at \(others.map(\.tildePath).joined(separator: ", ")); "
                          + "installing replaces it (the old one goes to the Trash).")
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
            if let name = DebugSnapshot.options?.project,
               let project = model.projects.first(where: { $0.lastPathComponent == name }) {
                scope = .project(project)
            }
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
                _ = try await model.install(request, into: targets, replace: replace)
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
