import AKitBrain
import AKitFoundation
import AKitKnowledge
import SwiftUI

/// Knowledge → Pi Template… (K16): the core layer's short section about the base for Pi only
/// (`akit kb pi-template`). Its own preview, since the Edit Layer sheet shows only the section
/// that goes to every target: the template text and the diff of layer.yaml and the template.
/// After the write, Update Home Folder… puts it into Pi's AGENTS.md (`akit apply --home`).
struct PiTemplateSheet: View {
    @Environment(KnowledgeModel.self) private var model
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// Opens Update Home Folder… in place of this sheet.
    let onUpdateHome: () -> Void

    @State private var edit: LayerEditor.FileEdit?
    @State private var problem: String?
    @State private var written = false
    @State private var isWriting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pi Template").font(.title3.bold())
            Text("A short section in the core layer that tells Pi about this base: read the card at the start of a task about other systems, then search. Only Pi gets it (when: target == pi), in the AGENTS.md it reads in ~/.pi/agent; ~/.claude/CLAUDE.md doesn't. Change the words later in the brain: layers/core/templates/\(KnowledgePiTemplate.template).")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
            if let edit {
                Text(state(edit)).fontWeight(.medium)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Template").font(.caption.bold()).foregroundStyle(.secondary)
                        Text(KnowledgePiTemplate.text.trimmingCharacters(in: .whitespacesAndNewlines))
                            .textSelection(.enabled).padding(.bottom, 8)
                        if !edit.isEmpty, !written {
                            if edit.changesLayer {
                                Text("layers/\(edit.layer)/layer.yaml").font(.caption.bold()).foregroundStyle(.secondary)
                                DiffPreview(diff: TextDiff.lines(from: edit.layerBefore, to: edit.layerAfter))
                            }
                            if edit.changesTemplate {
                                Text("layers/\(edit.layer)/templates/\(edit.template)" + (edit.templateBefore == nil ? " (new)" : ""))
                                    .font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 6)
                                DiffPreview(diff: TextDiff.lines(from: edit.templateBefore ?? "", to: edit.templateAfter))
                            }
                        }
                    }
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220)
            } else if problem == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 220)
            }
            HStack {
                Spacer()
                if written || edit?.isEmpty == true {
                    Button("Done") { dismiss() }
                    Button("Update Home Folder…", action: onUpdateHome)
                        .keyboardShortcut(.defaultAction)
                        .help("Put the core layer into this Mac's home folder, so Pi's AGENTS.md gets the section (akit apply --home)")
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button(edit?.changesLayer == false ? "Update Template" : "Add to Core Layer") { write() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(edit == nil || isWriting)
                        .help("Commit the pending edits of the base, then write and commit these files in the brain (akit kb pi-template --yes)")
                }
            }
        }
        .padding(20)
        .frame(width: 640)
        // The brain may still be scanned when the sheet opens (a snapshot, a fresh launch).
        .task(id: app.brain?.root) { load() }
    }

    private func state(_ edit: LayerEditor.FileEdit) -> String {
        if written { return "Written to the core layer and committed in the brain. Now Update Home Folder… puts it into Pi's AGENTS.md." }
        if edit.isEmpty { return "Already set in the core layer. If Pi's AGENTS.md doesn't have it yet, Update Home Folder…." }
        return edit.changesLayer ? "The core layer gets this section for Pi:" : "The template's text differs from AKit's; it is written back:"
    }

    private func load() {
        guard !written else { return }
        guard let brain = app.brain else {
            if !app.isScanning { problem = "No brain on this Mac. Create one in Brain first." }
            return
        }
        problem = nil
        do { edit = try KnowledgePiTemplate.plan(brain: brain) } catch { problem = error.message }
        if DebugSnapshot.options != nil {
            print("pi template: " + (problem ?? edit.map { $0.isEmpty ? "already set" : "would write\n" + $0.diff } ?? "-"))
        }
    }

    private func write() {
        guard let edit else { return }
        isWriting = true
        Task {
            defer { isWriting = false }
            await model.flush(model.base)
            do {
                try await app.setKnowledgePiTemplate(edit, base: model.base)
                written = true
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
