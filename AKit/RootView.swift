import SwiftUI

/// Sidebar sections. New sections (Agents, Settings…) arrive in later steps.
enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case overview
    case skills
    case skillsSh
    case mcp
    case sessions
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .skills: "Skills"
        case .skillsSh: "skills.sh"
        case .mcp: "MCP Servers"
        case .sessions: "Sessions"
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .skills: "book.closed"
        case .skillsSh: "sparkle.magnifyingglass"
        case .mcp: "server.rack"
        case .sessions: "bubble.left.and.bubble.right"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(SelfRebuild.self) private var rebuild

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $model.section) { section in
                Label(section.title, systemImage: section.icon)
                    .badge(section == .skills ? model.skills.count : section == .mcp ? model.mcpServers.count : 0)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
            .safeAreaInset(edge: .bottom) { BuildBadge(info: .current) }
        } detail: {
            switch model.section ?? .overview {
            case .overview: OverviewView()
            case .skills: SkillsView()
            case .skillsSh: SkillsShView()
            case .mcp: MCPView()
            case .sessions: SessionsView()
            }
        }
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

    private var rebuildError: String? {
        if case .failed(let message) = rebuild.state { return message }
        return nil
    }
}
