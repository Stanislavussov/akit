import SwiftUI

/// Sidebar sections. New sections (Agents, Settings…) arrive in later steps.
enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case overview
    case skills
    case skillsSh
    case mcp
    case sessions
    case usage
    case lab
    case analysis
    case brain
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .skills: "Skills"
        case .skillsSh: "skills.sh"
        case .mcp: "MCP Servers"
        case .sessions: "Sessions"
        case .usage: "Usage"
        case .lab: "Lab"
        case .analysis: "Error Analysis"
        case .brain: "Brain"
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .skills: "book.closed"
        case .skillsSh: "sparkle.magnifyingglass"
        case .mcp: "server.rack"
        case .sessions: "bubble.left.and.bubble.right"
        case .usage: "chart.bar.xaxis"
        case .lab: "flask"
        case .analysis: "stethoscope"
        case .brain: "brain"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(SelfRebuild.self) private var rebuild
    /// Error Analysis state lives as long as the window: the last pool judge run and rebuild
    /// stay when you leave the section, until AKit quits. Lab sheets read it too.
    @State private var analysis = AnalysisModel()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $model.section) { section in
                Label(section.title, systemImage: section.icon)
                    .badge(badge(for: section))
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                if DebugSnapshot.options?.demo != true { BuildBadge(info: .current) }
            }
        } detail: {
            switch model.section ?? .overview {
            case .overview: OverviewView()
            case .skills: SkillsView()
            case .skillsSh: SkillsShView()
            case .mcp: MCPView()
            case .sessions: SessionsView()
            case .usage: UsageView()
            case .lab: LabView()
            case .analysis: ErrorAnalysisView()
            case .brain: BrainView()
            }
        }
        .environment(analysis)
        // Lab runs start and end outside AKit: keep the badge and the queue current.
        .task { if DebugSnapshot.options == nil { await model.watchLab() } else { await model.reloadLab() } }
        .overlay(alignment: .bottom) {
            if rebuild.state == .building {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Rebuilding AKit… It restarts when the build is done.")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
            }
        }
        .alert("Couldn't rebuild AKit", isPresented: Binding(get: { rebuildError != nil },
                                                             set: { if !$0 { rebuild.dismissError() } })) {
            Button("OK") { rebuild.dismissError() }
        } message: {
            Text(rebuildError ?? "")
        }
    }

    private func badge(for section: SidebarSection) -> Int {
        switch section {
        case .skills: model.skills.count
        case .mcp: model.mcpServers.count
        case .lab: model.labRuns.filter { $0.status == .running || $0.status == .queued }.count
        default: 0
        }
    }

    private var rebuildError: String? {
        if case .failed(let message) = rebuild.state { return message }
        return nil
    }
}
