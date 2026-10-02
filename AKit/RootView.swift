import SwiftUI

/// Sidebar groups, by the question their screens answer. The screens guide follows the
/// same order (`docs/guides/screens.ru.md`, one section per group and per screen).
enum SidebarGroup: String, CaseIterable, Identifiable {
    case installed
    case setup
    case activity
    case improve
    var id: Self { self }

    var title: String {
        switch self {
        case .installed: "On This Mac"
        case .setup: "Setup"
        case .activity: "Activity"
        case .improve: "Improve"
        }
    }

    var summary: String {
        switch self {
        case .installed: "What the agents have on this Mac right now: harnesses, skills, MCP servers"
        case .setup: "What the agents should have: your brain of skills and layers, rendered into projects"
        case .activity: "How the agents worked: their saved sessions, tokens and cost"
        case .improve: "Why sessions went wrong and whether a fix helped"
        }
    }

    var sections: [SidebarSection] {
        switch self {
        case .installed: [.overview, .skills, .skillsSh, .mcp]
        case .setup: [.brain]
        case .activity: [.sessions, .usage]
        case .improve: [.lab, .analysis]
        }
    }
}

/// Sidebar sections. Their order on screen comes from `SidebarGroup`.
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

    /// The sidebar tooltip: what the screen is for and where it leads.
    var summary: String {
        switch self {
        case .overview: "Installed harnesses, their versions and config folders"
        case .skills: "Every skill the agents see now, by where it lives. Brain skills are edited in Brain"
        case .skillsSh: "Find a public skill on skills.sh and install it into a folder; Import Skills… in Brain adds it to your library"
        case .mcp: "MCP servers per harness and project; edited in the harness configs, secrets in the Keychain"
        case .sessions: "Saved conversations, newest first; open one for its tokens and Analysis. Review in Terminal… starts a Lab run"
        case .usage: "Tokens and cost per day, summed from the same session files"
        case .lab: "The queue of runs that start an agent or a model: reviews, replays, analysis batches, control cells; Sends logs what went out"
        case .analysis: "Recurring failure modes across many sessions, their frequencies, and whether a fix helped; its batches run in Lab"
        case .brain: "Your git repo of skills and layers; Set Up Project… renders them into a project"
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
    @Environment(GuideNavigator.self) private var guides
    @Environment(\.openWindow) private var openWindow
    /// Error Analysis state lives as long as the window: the last pool judge run and rebuild
    /// stay when you leave the section, until AKit quits. Lab sheets read it too.
    @State private var analysis = AnalysisModel()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.section) {
                ForEach(SidebarGroup.allCases) { group in
                    Section {
                        ForEach(group.sections) { section in
                            Label(section.title, systemImage: section.icon)
                                .badge(badge(for: section))
                                .help(section.summary)
                                .contextMenu {
                                    Button("What Is \(section.title) For?", systemImage: "book") {
                                        showGuide(section.rawValue)
                                    }
                                }
                                .tag(section)
                        }
                    } header: {
                        Text(group.title).help(group.summary)
                    }
                }
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

    private func showGuide(_ section: String) {
        guides.show(.screens, section: section)
        openWindow(id: GuideView.windowID)
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
