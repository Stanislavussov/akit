import AKitLab
import AKitReview
import AppKit
import SwiftUI

/// A run's Overview (R45–R47): what happens, the modules that change and why, where the why
/// comes from, and the flow. In the run's summary language; Translate shows it in another one.
/// Never posted.
struct ReviewOverviewSection<Translate: View>: View {
    let overview: ReviewOverview
    let translator: Translator
    /// The run's Translate menu and its note: one menu for the whole run.
    @ViewBuilder let translate: () -> Translate
    /// Snapshots: `--tab requests` and `--tab map` fold it, to show the tab.
    @State private var expanded = !["requests", "map"].contains(DebugSnapshot.options?.tab)

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                points
                if !overview.modules.isEmpty { modules }
                sources
                if !overview.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(overview.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
                flow
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text("Overview").font(.headline)
                Text(overview.language.name).font(.callout).foregroundStyle(.secondary)
                    .help("The summary language of this run (Summary language in New Review…). It stays in AKit; GitLab gets the posting language.")
                Spacer()
                translate()
            }
        }
    }

    private var points: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(overview.points.enumerated()), id: \.offset) { index, point in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(translator.text(ReviewWorkflow.Run.TranslationKey.overviewPoint(index), point))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var modules: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Module")
                Text("Files")
                Text("Why it changes")
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Divider()
            ForEach(Array(overview.modules.enumerated()), id: \.offset) { index, module in
                GridRow {
                    Text(module.name).font(.callout.monospaced()).textSelection(.enabled)
                    ModuleFilesButton(files: module.files)
                    Text(module.why.isEmpty ? "—" : translator.text(ReviewWorkflow.Run.TranslationKey.overviewModule(index), module.why))
                        .font(.callout)
                        .foregroundStyle(module.why.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridColumnAlignment(.leading)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private var sources: some View {
        HStack(spacing: 6) {
            Text("Why from:").font(.caption).foregroundStyle(.secondary)
            if overview.whySources.isEmpty {
                Text("not said").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(overview.whySources, id: \.self) { source in
                Text(title(source))
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.secondary.opacity(0.12), in: Capsule())
                    .help(help(source))
            }
        }
    }

    @ViewBuilder private var flow: some View {
        if let flow = overview.flow {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Flow").font(.subheadline.weight(.medium))
                    Text(overview.flowKind == .sequenceDiagram ? "sequence diagram" : "flowchart").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Mermaid", systemImage: "doc.on.doc") { copy(flow) }
                        .controlSize(.small)
                        .help("Copy the diagram's Mermaid source, to paste into a merge request, a wiki or mermaid.live")
                }
                MermaidView(source: flow)
                Text("Changed parts are marked; the other repositories that use the change are a group of their own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if let original = overview.flowOriginal {
            DisclosureGroup("Flow left out (the source)") {
                HStack(alignment: .top) {
                    Text(original).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy Mermaid", systemImage: "doc.on.doc") { copy(original) }.controlSize(.small)
                }
            }
            .font(.callout)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func title(_ source: ReviewOverview.WhySource) -> String {
        switch source {
        case .workItem: "work item"
        case .description: "description"
        case .notes: "your notes"
        case .none: "nothing said"
        }
    }

    private func help(_ source: ReviewOverview.WhySource) -> String {
        switch source {
        case .workItem: "The work item and its parents up to the epic, with their comments (Azure DevOps through MCP)"
        case .description: "The merge request's description"
        case .notes: "Context for this review, from New Review…"
        case .none: "Nothing says why: the reasons are the model's reading of the code"
        }
    }
}

/// A module's files: the count, and the list in a popover.
private struct ModuleFilesButton: View {
    let files: [String]
    @State private var shown = false

    var body: some View {
        Button("\(files.count) file\(files.count == 1 ? "" : "s")") { shown = true }
            .buttonStyle(.link)
            .font(.callout)
            .popover(isPresented: $shown) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(files, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                }
                .padding(10)
            }
    }
}
