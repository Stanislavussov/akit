import AKitCore
import AppKit
import SwiftUI

/// Skills screen: every skill the installed harnesses can see, grouped by where it lives.
/// Read-only for now; editing arrives with safe writes (step 3).
struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Skill.ID?
    @State private var query = ""
    @State private var pendingDelete: Skill?
    @State private var deleteError: String?

    var body: some View {
        @Bindable var model = model
        HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
            Group {
                if let skill = model.skills.first(where: { $0.id == selection }) {
                    SkillDetailView(skill: skill, onDelete: { pendingDelete = skill })
                } else {
                    ContentUnavailableView("Select a skill", systemImage: "book.closed")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Skills")
        .navigationSubtitle(subtitle)
        .searchable(text: $query, placement: .toolbar, prompt: "Name or description")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Picker("Show", selection: $model.skillsFilter) {
                        Text("All Skills").tag(SkillsFilter.all)
                        Text("Global Only").tag(SkillsFilter.global)
                    }
                    .pickerStyle(.inline)
                    if !projects.isEmpty {
                        Picker("Project", selection: $model.skillsFilter) {
                            ForEach(projects, id: \.url) { project in
                                Text("\(project.url.lastPathComponent)  (\(project.count))").tag(SkillsFilter.project(project.url))
                            }
                        }
                        .pickerStyle(.inline)
                    }
                } label: {
                    Label(filterTitle, systemImage: filterIcon)
                        .labelStyle(.titleAndIcon)
                }
                .fixedSize()
                .help(filterHelp)
            }
            ToolbarItem(placement: .navigation) {
                Menu {
                    Picker("Harness", selection: $model.skillsHarness) {
                        Text("All Harnesses").tag(String?.none)
                        Divider()
                        ForEach(model.installations) { harness in
                            Text(harness.displayName).tag(Optional(harness.id.rawValue))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(harnessTitle, systemImage: "cpu")
                        .labelStyle(.titleAndIcon)
                }
                .fixedSize()
                .help(model.skillsHarness == nil ? "Showing skills of every harness" : "Showing only skills \(harnessTitle) sees")
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.isScanning)
                    .help("Rescan skills (⌘R)")
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { skill in
            Button("Move to Trash", role: .destructive) { delete(skill) }
            Button("Cancel", role: .cancel) {}
        } message: { skill in
            Text(deleteMessage(for: skill))
        }
        .alert("Couldn't delete the skill", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK") {}
        } message: {
            Text(deleteError ?? "")
        }
        .onAppear {
            // Use the menu's own URL for the chosen project, so the picker shows it as selected.
            if case .project(let chosen) = model.skillsFilter,
               let match = projects.first(where: { $0.url.standardizedFileURL.path == chosen.standardizedFileURL.path }) {
                model.skillsFilter = .project(match.url)
            }
            if !reveal() { selection = selection ?? filtered.first?.id }
        }
        .onChange(of: model.revealSkill) { reveal() }
        .onChange(of: model.skillsHarness) {
            if selection.flatMap({ id in filtered.first { $0.id == id } }) == nil { selection = filtered.first?.id }
        }
        .onChange(of: model.skillsFilter) {
            if selection.flatMap({ id in filtered.first { $0.id == id } }) == nil { selection = filtered.first?.id }
        }
        .onChange(of: model.skills) { if selection.flatMap({ id in model.skills.first { $0.id == id } }) == nil { selection = filtered.first?.id } }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.scope) { group in
                Section {
                    ForEach(group.skills) { skill in
                        SkillRow(skill: skill)
                            .tag(skill.id)
                            .contextMenu {
                                if ExternalEditor.appURL != nil {
                                    Button("Open in \(ExternalEditor.name)") { ExternalEditor.open(skill.folder) }
                                }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([skill.file]) }
                                Divider()
                                Button("Move to Trash…", role: .destructive) { pendingDelete = skill }
                                    .disabled(skill.isReadOnly)
                            }
                    }
                } header: {
                    Text(group.scope.title)
                        .help(projectPath(group.scope) ?? "")
                }
            }
        }
        .overlay {
            if !query.isEmpty && filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if model.skills.isEmpty && !model.isScanning {
                ContentUnavailableView("No skills found", systemImage: "book.closed")
            }
        }
    }

    /// Selects the skill another screen asked to show. Returns whether there was one.
    @discardableResult
    private func reveal() -> Bool {
        guard let id = model.revealSkill else { return false }
        model.revealSkill = nil
        query = ""
        selection = id
        return true
    }

    private func deleteMessage(for skill: Skill) -> String {
        var lines: [String]
        if SkillRemover.removesOnlyLink(skill) {
            let link = (skill.isSingleFile ? skill.file : skill.folder).tildePath
            lines = ["\(link) is a link. Only the link is moved to the Trash; the skill itself stays in \(skill.realFolder.tildePath)."]
        } else {
            let place = (skill.isSingleFile ? skill.realFile : skill.realFolder).tildePath
            lines = ["\(place) will be moved to the Trash. You can put it back from there."]
        }
        if skill.visibleTo.count > 1 {
            lines.append("It is shared: \(skill.visibleTo.map(\.displayName).joined(separator: " and ")) will all stop seeing it.")
        } else if let harness = skill.visibleTo.first {
            lines.append("\(harness.displayName) will stop seeing it.")
        }
        if let origin = skill.origin {
            lines.append("It was installed from \(origin); installing it again brings it back.")
        }
        return lines.joined(separator: "\n\n")
    }

    private func delete(_ skill: Skill) {
        Task {
            do {
                try await model.delete(skill)
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private var subtitle: String {
        let shown = scoped.count
        let base = shown == model.skills.count ? "\(shown) skills" : "\(shown) of \(model.skills.count) skills"
        return filtered.count == shown ? base : "\(filtered.count) found · " + base
    }

    /// Skills for the chosen project filter, before the search text.
    private var scoped: [Skill] {
        model.skills.filter { skill in
            model.skillsFilter.includes(skill.scope)
                && (model.skillsHarness.map { id in skill.visibleTo.contains { $0.rawValue == id } } ?? true)
        }
    }

    private var harnessTitle: String {
        guard let id = model.skillsHarness else { return "All Harnesses" }
        return model.installations.first { $0.id.rawValue == id }?.displayName ?? id
    }

    private var filtered: [Skill] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return scoped }
        return scoped.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.description.localizedCaseInsensitiveContains(q)
        }
    }

    /// Projects for the filter menu: the known ones plus any that have skills, with their own skill count.
    private var projects: [(url: URL, count: Int)] {
        var urls: [String: URL] = [:]
        var counts: [String: Int] = [:]
        for url in model.projects {
            urls[url.standardizedFileURL.path] = url
            counts[url.standardizedFileURL.path, default: 0] += 0
        }
        for skill in model.skills {
            guard case .project(let url) = skill.scope else { continue }
            let key = url.standardizedFileURL.path
            urls[key] = urls[key] ?? url
            counts[key, default: 0] += 1
        }
        return counts.compactMap { key, count in urls[key].map { (url: $0, count: count) } }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    private var filterTitle: String {
        switch model.skillsFilter {
        case .all: "All Skills"
        case .global: "Global Only"
        case .project(let url): "Project · \(url.lastPathComponent)"
        }
    }

    private var filterIcon: String {
        switch model.skillsFilter {
        case .all: "square.stack.3d.up"
        case .global: "globe"
        case .project: "folder"
        }
    }

    private var filterHelp: String {
        switch model.skillsFilter {
        case .all: "Showing every skill, from all projects"
        case .global: "Showing only skills that every project sees"
        case .project(let url): "Showing what a session in \(url.tildePath) sees: its own skills plus global ones"
        }
    }

    private var groups: [(scope: SkillScope, skills: [Skill])] {
        Dictionary(grouping: filtered, by: \.scope)
            .map { (scope: $0.key, skills: $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { (rank($0.scope), $0.scope.title) < (rank($1.scope), $1.scope.title) }
    }

    /// Group order; with a project chosen, its own skills come first.
    private func rank(_ scope: SkillScope) -> Int {
        if case .project = model.skillsFilter, case .project = scope { return -1 }
        return scope.sortRank
    }

    private func projectPath(_ scope: SkillScope) -> String? {
        if case .project(let url) = scope { return url.tildePath }
        return nil
    }
}

private struct SkillRow: View {
    let skill: Skill

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(skill.name).fontWeight(.medium)
                if !skill.warnings.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Spacer()
                ForEach(skill.visibleTo, id: \.self) { HarnessBadge(harness: $0) }
            }
            if !skill.description.isEmpty {
                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SkillDetailView: View {
    @Environment(AppModel.self) private var model
    let skill: Skill
    let onDelete: () -> Void
    @State private var files: [String] = []
    @State private var text: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                info
                if !skill.warnings.isEmpty { warnings }
                if files.count > 1 { fileList }
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Reload on selection change and after every rescan (⌘R).
        .task(id: "\(skill.id)|\(model.lastScan?.timeIntervalSince1970 ?? 0)") {
            let skill = skill
            let loaded = await Task.detached { (SkillFiles.list(skill), SkillFiles.text(of: skill)) }.value
            // The detached load is not cancelled with the view task: drop results for an old selection.
            guard !Task.isCancelled else { return }
            files = loaded.0
            text = loaded.1
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(skill.name).font(.title2.bold()).textSelection(.enabled)
                if skill.isReadOnly {
                    Label("Read-only", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if ExternalEditor.appURL != nil {
                    Button("Open in \(ExternalEditor.name)", systemImage: "square.and.pencil") {
                        ExternalEditor.open(skill.folder)
                    }
                }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([skill.file])
                }
                .labelStyle(.iconOnly)
                .help("Show in Finder")
                if !skill.isReadOnly {
                    Button("Move to Trash…", systemImage: "trash", role: .destructive, action: onDelete)
                        .labelStyle(.iconOnly)
                        .help("Move this skill to the Trash")
                }
            }
            if !skill.description.isEmpty {
                Text(skill.description).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private var info: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                label("Location")
                Text(skill.file.tildePath).monospaced()
            }
            if skill.realFile.path != skill.file.path {
                GridRow {
                    label("Real path")
                    Text(skill.realFile.tildePath).monospaced()
                }
            }
            GridRow {
                label("Visible to")
                HStack(spacing: 4) {
                    if skill.visibleTo.isEmpty {
                        Text("No harness").foregroundStyle(.secondary)
                    }
                    ForEach(skill.visibleTo, id: \.self) { HarnessBadge(harness: $0) }
                }
            }
            if let origin = skill.origin {
                GridRow {
                    label("Source")
                    Text(origin)
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(skill.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
    }

    private var fileList: some View {
        GroupBox("Files (\(files.count))") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(files, id: \.self) { file in
                    Text(file).font(.system(.callout, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .textSelection(.enabled)
        }
    }

    private var content: some View {
        GroupBox(skill.file.lastPathComponent) {
            Text(text ?? "")
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
                .textSelection(.enabled)
        }
    }
}

/// Which skills the Skills screen lists.
enum SkillsFilter: Hashable {
    case all
    /// Skills every project sees (global, claude.ai, plugins, built-in).
    case global
    /// What a session in this project sees: its own skills plus the global ones.
    case project(URL)

    /// `--project <folder name>` in snapshot mode picks that project.
    static var initial: SkillsFilter {
        guard let name = DebugSnapshot.options?.project else { return .all }
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Projects/\(name)")
        return .project(root)
    }

    func includes(_ scope: SkillScope) -> Bool {
        switch (self, scope) {
        case (.all, _): true
        case (_, .project(let url)):
            if case .project(let chosen) = self { url.standardizedFileURL.path == chosen.standardizedFileURL.path } else { false }
        default: true
        }
    }
}
