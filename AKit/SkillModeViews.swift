import AKitBrain
import AKitFoundation
import AKitModel
import AKitSkills
import SwiftUI

/// Skill detail: **Mode Here**, the skill's mode in Pi for the project chosen at the top of the
/// Skills screen (skill-modes.md): Auto, Manual or Off, from the project's entry in
/// `~/.akit/local/skill-modes.json` or the skill's own SKILL.md, with Reset. Writes at once
/// (backup first) and shows a refusal inline. The global level is Model invocation below it.
struct SkillModeHereControl: View {
    @Environment(AppModel.self) private var model
    let skill: Skill
    @State private var reading = SkillModes.Reading()
    @State private var problem: String?
    @State private var working = false
    @State private var installing: SkillModesExtension.Plan?
    @State private var extensionState: SkillModesExtension.State = .current

    private var env: HarnessEnvironment { .current }

    /// The project folder chosen at the top of the screen; nil for All Skills / Global Only.
    private var folder: URL? {
        if case .project(let url) = model.skillsFilter { url } else { nil }
    }

    private var projectID: String? { folder.flatMap { ProjectRecords.projectID(ofFolder: $0, projectsRoot: model.projectsRoot.path) } }

    /// The skill as Pi's extension reports it to `akit skills resolve`.
    private var loaded: SkillModes.LoadedSkill {
        let scope = skill.places[.pi]?.scope ?? skill.scope
        return switch scope {
        case .project: .init(name: skill.name, scope: "project", origin: "top-level", path: skill.file.path)
        case .package(_, let project): .init(name: skill.name, scope: project == nil ? "user" : "project", origin: "package", path: skill.file.path)
        default: .init(name: skill.name, scope: "user", origin: "top-level", path: skill.file.path)
        }
    }

    var body: some View {
        if skill.visibleTo.contains(.pi) {
            GridRow {
                Text("Mode Here").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 4) { content }
            }
            .task(id: "\(skill.id)|\(projectID ?? "")") { reload() }
            .sheet(item: $installing) { plan in
                SkillModesInstallSheet(plan: plan) { reload() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if folder == nil {
            Text("Pick a project at the top (Project) to set its mode there.").foregroundStyle(.secondary)
        } else if let projectID {
            let entries = reading.usable ? reading.entries(for: projectID) : [:]
            let key = SkillModes.entryName(for: loaded, in: entries)
            let own: SkillMode = skill.disablesModelInvocation ? .manual : .auto
            let mode = key.flatMap { entries[$0] } ?? own
            HStack(spacing: 8) {
                Picker("Mode Here", selection: Binding(get: { mode }, set: { set($0, key: key ?? skill.name) })) {
                    ForEach(SkillMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(working || !reading.usable)
                .help(SkillModeText.help)
                Text(fromText(key: key)).foregroundStyle(.secondary)
                if let key {
                    Button("Reset") { reset(key) }
                        .disabled(working)
                        .help("Take the project's entry \(key) out; the skill's SKILL.md decides again (\(own.title)).")
                }
            }
            if !reading.usable, let message = reading.problems.first?.message {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if extensionState != .current {
                HStack(spacing: 8) {
                    Text(extensionState == .missing ? "Pi applies modes through AKit's extension, which is not installed."
                         : extensionState == .outdated ? "AKit's Pi extension for skill modes is outdated."
                         : "Another file is where AKit's Pi extension for skill modes goes; modes may not apply.")
                        .foregroundStyle(.secondary)
                    if extensionState != .foreign {
                        Button(extensionState == .missing ? "Install…" : "Update…") { install() }
                    }
                }
            }
        } else {
            Text("\(folder?.lastPathComponent ?? "This folder") is not in a git repository; only the skill's SKILL.md applies.")
                .foregroundStyle(.secondary)
        }
    }

    private func fromText(key: String?) -> String {
        guard let key else { return "from Skill" }
        return key == skill.name ? "from Project" : "from Project (\(key): always your own \(skill.name))"
    }

    private func reload() {
        reading = SkillModes.read(SkillModes.file(home: env.homeDirectory), home: env.homeDirectory)
        extensionState = SkillModesExtension(env: env).status().state
    }

    private func set(_ mode: SkillMode, key: String) {
        guard let projectID else { return }
        write { home in try SkillModes.plan(set: mode, name: key, project: projectID, home: home) }
    }

    private func reset(_ key: String) {
        guard let projectID else { return }
        write { home in try SkillModes.plan(reset: key, project: projectID, home: home) }
    }

    private func write(_ make: @escaping @Sendable (URL) throws -> SkillModes.Plan) {
        let home = env.homeDirectory
        working = true
        problem = nil
        Task {
            let failure: String? = await Task.detached {
                do {
                    try SkillModes.apply(try make(home), home: home)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            problem = failure
            working = false
            reload()
        }
    }

    private func install() {
        do {
            installing = try SkillModesExtension(env: env).installPlan()
        } catch {
            problem = error.localizedDescription
        }
    }
}

enum SkillModeText {
    static let help = "Auto: listed to Pi's model in this project. Manual: only /skill:NAME runs it. Off: left out, and /skill:NAME is refused. Kept in ~/.akit/local/skill-modes.json for the project (every checkout and worktree of it), never in the repository; Reset lets the skill's SKILL.md decide again."
}

extension SkillModesExtension.Plan: @retroactive Identifiable {
    public var id: String { file.path + (text?.count.description ?? "") }
}

/// The extension's install: the file it writes (or replaces, after a backup), then Install.
struct SkillModesInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    let plan: SkillModesExtension.Plan
    let done: () -> Void
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install the Pi Extension for Skill Modes").font(.headline)
            Text("Pi loads it at its next start (or /reload). Before each run it asks AKit for the project's modes; it never changes skill files.")
                .foregroundStyle(.secondary)
            ScrollView {
                Text(plan.text(home: HarnessEnvironment.current.homeDirectory))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 160, maxHeight: 320)
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install") {
                    do {
                        try SkillModesExtension(env: .current).execute(plan)
                        done()
                        dismiss()
                    } catch {
                        problem = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
