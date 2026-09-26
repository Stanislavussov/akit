import AKitCore
import SwiftUI

/// Preview and run an import of global skills into the brain's core layer.
struct BrainImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var plan: BrainImport.Plan?
    @State private var chosen: Set<String> = []
    @State private var isApplying = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Skills into the Brain").font(.title2.bold())
            Text("Copies skills from \(plan?.source.tildePath ?? "~/.agents/skills") into the brain's skills/ and lists them in the core layer as manual. The originals stay where they are, so your harnesses keep seeing them.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let plan {
                candidates(plan)
                coreDiff(plan)
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
                    .disabled(chosen.isEmpty || isApplying || coreAfter.failure != nil)
            }
        }
        .padding(16)
        .frame(width: 640, height: 620)
        .task { await reload() }
    }

    private func reload() async {
        let loaded = await model.brainImportPlan()
        let isFirstLoad = plan == nil
        plan = loaded
        // First time everything that can be imported; after a failure, keep the user's picks.
        let selectable = Set(loaded?.candidates.filter(Self.selectable).map(\.name) ?? [])
        chosen = isFirstLoad ? selectable : chosen.intersection(selectable)
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
        case .new: candidate.inCore ? "copy (already in core)" : "copy"
        case .same: candidate.inCore ? "already imported" : "same copy in the brain; add to core"
        case .different: "a different copy is in the brain; skipped"
        }
    }

    private var coreAfter: (text: String?, failure: String?) {
        guard let plan else { return (nil, nil) }
        do {
            return (try BrainImport.coreAfter(plan, importing: Array(chosen)), nil)
        } catch {
            return (nil, error.message)
        }
    }

    private func coreDiff(_ plan: BrainImport.Plan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("layers/core/layer.yaml").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let failure = coreAfter.failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if let after = coreAfter.text, after != plan.coreBefore {
                        DiffPreview(diff: TextDiff.lines(from: plan.coreBefore, to: after))
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
                // Keep the plan's order so the core layer lists skills alphabetically.
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
