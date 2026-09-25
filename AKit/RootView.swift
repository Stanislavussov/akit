import SwiftUI

/// Sidebar sections. New sections (Agents, Settings…) arrive in later steps.
enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case overview
    case skills
    case sessions
    case systemPrompt
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .skills: "Skills"
        case .sessions: "Sessions"
        case .systemPrompt: "System Prompt"
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .skills: "book.closed"
        case .sessions: "bubble.left.and.bubble.right"
        case .systemPrompt: "doc.plaintext"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarSection? = DebugSnapshot.options?.section ?? .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .badge(section == .skills ? model.skills.count : 0)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            switch selection ?? .overview {
            case .overview: OverviewView()
            case .skills: SkillsView()
            case .sessions: SessionsView()
            case .systemPrompt: SystemPromptView()
            }
        }
    }
}
