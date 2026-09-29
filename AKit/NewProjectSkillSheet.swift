import AKitCore
import SwiftUI

/// Create a skill that belongs to one project: `.agents/skills/<name>/SKILL.md` in the
/// project, committed with it. AKit never overwrites it.
struct NewProjectSkillSheet: View {
    @Environment(\.dismiss) private var dismiss

    let project: URL
    /// Called with the new SKILL.md.
    let onCreated: (URL) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Skill in \(project.lastPathComponent)").font(.title2.bold())
            Form {
                TextField("Name", text: $name, prompt: Text("deploy"))
                if let problem = ProjectSkills.nameProblem(name, in: project), !name.isEmpty {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                TextField("Description", text: $description, prompt: Text("When the agent should use it"))
            }
            .formStyle(.grouped)
            .frame(height: 150)
            VStack(alignment: .leading, spacing: 4) {
                Text("Instructions").font(.headline)
                Text("What the agent does when it uses the skill. You can edit SKILL.md later.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $instructions)
                    .font(.callout.monospaced())
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }
            Text("Saved to \(ProjectBundle.skillsFolder)/\(name.isEmpty ? "<name>" : name) in the project. Commit it with the project. Pi, Codex and OpenCode see it right away; Claude Code once the project has the .claude/skills link (Layers & Skills… → Apply adds it).")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Skill", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ProjectSkills.nameProblem(name, in: project) != nil || description.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560, height: 520)
    }

    private func create() {
        do {
            let file = try ProjectSkills.create(name, description: description, instructions: instructions, in: project)
            onCreated(file)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
