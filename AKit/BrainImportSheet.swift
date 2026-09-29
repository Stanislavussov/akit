import AKitBrain
import AKitFoundation
import SwiftUI

/// Preview and run an import of skills into a brain layer: all global skills into core by
/// default, or one skill (from the Skills screen) into the layer you pick.
struct BrainImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Skills folder to import from; nil = `~/.agents/skills`.
    var source: URL?
    /// Only these are ticked at first; nil = everything that can be imported.
    var preselect: [String]?
    @State var layer = "core"
    @State var mode = LayerSkill.Mode.manual
    @State private var plan: BrainImport.Plan?
    @State private var chosen: Set<String> = []
    @State private var isApplying = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Skills into the Brain").font(.title2.bold())
            Text("Copies skills from \((plan?.source ?? source)?.tildePath ?? "~/.agents/skills") into the brain's skills/ and lists them in the \(layer) layer as \(mode.rawValue). The originals stay where they are, so your harnesses keep seeing them.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Picker("Layer", selection: $layer) {
                    ForEach(model.brain?.layers.map(\.name) ?? [layer], id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                .help("The layer that lists the imported skills; core goes into the home folder")
                Picker("Mode", selection: $mode) {
                    Text("manual").tag(LayerSkill.Mode.manual)
                    Text("auto").tag(LayerSkill.Mode.auto)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("manual: runs only on an explicit /name. auto: in the agent's context.")
                Spacer()
            }
            .disabled(isApplying)
            if let plan {
                candidates(plan)
                layerDiff(plan)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isApplying ? "Importing…" : "Import \(chosen.count) Skill\(chosen.count == 1 ? "" : "s")", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || isApplying || layerAfter.failure != nil)
            }
        }
        .padding(16)
        .frame(width: 640, height: 620)
        .task(id: "\(layer)|\(mode.rawValue)") { await reload() }
    }

    private func reload() async {
        let loaded = await model.brainImportPlan(from: source, layer: layer, mode: mode)
        let isFirstLoad = plan == nil
        plan = loaded
        // First time everything that can be imported (or the preselected ones); after that keep the user's picks.
        let selectable = Set(loaded?.candidates.filter(Self.selectable).map(\.name) ?? [])
        chosen = isFirstLoad ? selectable.intersection(preselect ?? Array(selectable)) : chosen.intersection(selectable)
    }

    private static func selectable(_ candidate: BrainImport.Candidate) -> Bool {
        candidate.state != .different && !candidate.isDone
    }

    private func candidates(_ plan: BrainImport.Plan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(plan.candidates.count) skills found").font(.headline)
                Spacer()
                let selectable = plan.candidates.filter(Self.selectable).map(\.name)
                Button(chosen.count == selectable.count ? "Select None" : "Select All") {
                    chosen = chosen.count == selectable.count ? [] : Set(selectable)
                }
                .buttonStyle(.link)
                .disabled(selectable.isEmpty)
            }
            List(plan.candidates) { candidate in
                Toggle(isOn: Binding(get: { chosen.contains(candidate.name) },
                                     set: { if $0 { chosen.insert(candidate.name) } else { chosen.remove(candidate.name) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(candidate.name).fontWeight(.medium)
                            Text(status(candidate)).font(.caption).foregroundStyle(candidate.state == .different ? .orange : .secondary)
                            Spacer()
                            if let source = candidate.source {
                                Text(source).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .help("Installed from \(source); after the import the brain copy is yours")
                            }
                        }
                        if !candidate.skipped.isEmpty {
                            Text("Not copied: \(candidate.skipped.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .disabled(!Self.selectable(candidate))
            }
            .listStyle(.bordered)
            .overlay {
                if plan.candidates.isEmpty {
                    ContentUnavailableView("No skills to import", systemImage: "tray")
                }
            }
        }
    }

    private func status(_ candidate: BrainImport.Candidate) -> String {
        switch candidate.state {
        case .new: candidate.inLayer ? "copy (already in \(layer))" : "copy"
        case .same: candidate.inLayer ? "already imported" : "same copy in the brain; add to \(layer)"
        case .different: "a different copy is in the brain; skipped"
        }
    }

    private var layerAfter: (text: String?, failure: String?) {
        guard let plan else { return (nil, nil) }
        do {
            return (try BrainImport.layerAfter(plan, importing: Array(chosen)), nil)
        } catch {
            return (nil, error.message)
        }
    }

    private func layerDiff(_ plan: BrainImport.Plan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("layers/\(plan.layer)/layer.yaml").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let failure = layerAfter.failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if let after = layerAfter.text, after != plan.layerBefore {
                        DiffPreview(diff: TextDiff.lines(from: plan.layerBefore, to: after))
                    } else {
                        Text("No change").foregroundStyle(.secondary)
                    }
                }
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .frame(height: 150)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func apply() {
        guard let plan else { return }
        isApplying = true
        error = nil
        Task {
            defer { isApplying = false }
            do {
                // Keep the plan's order so the layer lists skills alphabetically.
                try await model.importIntoBrain(plan, names: plan.candidates.map(\.name).filter(chosen.contains))
                dismiss()
            } catch {
                self.error = error.localizedDescription
                // The brain may have changed (part of the import done): preview it again.
                await reload()
            }
        }
    }
}
