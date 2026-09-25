import SwiftUI

/// Sidebar sections. New sections (Agents, Settings…) arrive in later steps.
enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case overview
    case skills
    case skillsSh
    case sessions
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .skills: "Skills"
        case .skillsSh: "skills.sh"
        case .sessions: "Sessions"
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .skills: "book.closed"
        case .skillsSh: "sparkle.magnifyingglass"
        case .sessions: "bubble.left.and.bubble.right"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(SelfRebuild.self) private var rebuild
    @State private var selection: SidebarSection? = DebugSnapshot.options?.section ?? .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .badge(section == .skills ? model.skills.count : 0)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
            .safeAreaInset(edge: .bottom) { BuildBadge(info: .current) }
        } detail: {
            switch selection ?? .overview {
            case .overview: OverviewView()
            case .skills: SkillsView()
            case .skillsSh: SkillsShView()
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
