import AKitErrorAnalysis
import SwiftUI

/// Sidebar groups, by the question their screens answer. The screens guide has one section
/// per group and per screen (`docs/guides/screens.ru.md`), ordered from simple to complex:
/// On This Mac, Activity, Setup, Improve.
enum SidebarGroup: String, CaseIterable, Identifiable {
    case installed
    case setup
    case activity
    case improve
    case work
    var id: Self { self }

    var title: String {
        switch self {
        case .installed: "On This Mac"
        case .setup: "Setup"
        case .activity: "Activity"
        case .improve: "Improve"
        case .work: "Work"
        }
    }

    var summary: String {
        switch self {
        case .installed: "What the agents have on this Mac right now: harnesses, skills, MCP servers"
        case .setup: "What the agents should have: your brain of skills and layers, rendered into projects"
        case .activity: "How the agents worked: their saved sessions, tokens and cost"
        case .improve: "What the setup costs unused, why sessions went wrong and whether a fix helped"
        case .work: "Agents that help with your daily work: review of merge requests, a knowledge base of your services and flows"
        }
    }

    var sections: [SidebarSection] {
        switch self {
        case .installed: [.overview, .skills, .skillsSh, .mcp, .instructions]
        case .setup: [.brain]
        case .activity: [.sessions, .usage]
        case .improve: [.insights, .lab, .analysis]
        case .work: [.review, .knowledge]
        }
    }
}

/// Sidebar sections. Their order on screen comes from `SidebarGroup`.
enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case overview
    case skills
    case skillsSh
    case mcp
    case instructions
    case sessions
    case usage
    case insights
    case lab
    case analysis
    case brain
    case review
    case knowledge
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .skills: "Skills"
        case .skillsSh: "skills.sh"
        case .mcp: "MCP Servers"
        case .instructions: "Instructions"
        case .sessions: "Sessions"
        case .usage: "Usage"
        case .insights: "Insights"
        case .lab: "Lab"
        case .analysis: "Error Analysis"
        case .brain: "Brain"
        case .review: "Review"
        case .knowledge: "Knowledge"
        }
    }

    /// The sidebar tooltip: what the screen is for and where it leads.
    var summary: String {
        switch self {
        case .overview: "Installed harnesses, their versions and config folders"
        case .skills: "Every skill the agents see now, by where it lives. Brain skills are edited in Brain"
        case .skillsSh: "Find a public skill on skills.sh and install it into a folder; Import Skills… in Brain adds it to your library"
        case .mcp: "MCP servers per harness and project; edited in the harness configs, secrets in the Keychain"
        case .instructions: "The AGENTS.md and CLAUDE.md files each harness loads for a session in a project, in order, with their size"
        case .sessions: "Saved conversations, newest first; open one for its tokens and Analysis. Review in Terminal… starts a Lab run"
        case .usage: "Tokens and cost per day, summed from the same session files"
        case .insights: "What the skill list costs in every request and which skills the model never calls; Apply… makes one manual in its layer"
        case .lab: "The queue of runs that start an agent or a model: reviews, replays, analysis batches, control cells; Sends logs what went out"
        case .analysis: "Recurring failure modes across many sessions, their frequencies, and whether a fix helped; its batches run in Lab"
        case .brain: "Your git repo of skills and layers; Set Up Project… renders them into a project"
        case .review: "AI review of GitLab merge requests: Pi proposes comments, you approve each, AKit adds them as your drafts"
        case .knowledge: "Notes about your services, flows and teams by space, in a local git repo that agents read; edits are committed by AKit"
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .skills: "book.closed"
        case .skillsSh: "sparkle.magnifyingglass"
        case .mcp: "server.rack"
        case .instructions: "doc.text"
        case .sessions: "bubble.left.and.bubble.right"
        case .usage: "chart.bar.xaxis"
        case .insights: "lightbulb"
        case .lab: "flask"
        case .analysis: "stethoscope"
        case .brain: "brain"
        case .review: "checklist"
        case .knowledge: "books.vertical"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(SelfRebuild.self) private var rebuild
    @Environment(AppUpdate.self) private var update
    @Environment(GuideNavigator.self) private var guides
    @Environment(AskAKitModel.self) private var ask
    @Environment(\.openWindow) private var openWindow
    /// Error Analysis state lives as long as the window: the last pool judge run and rebuild
    /// stay when you leave the section, until AKit quits. Lab sheets read it too.
    @State private var analysis = AnalysisModel()
    /// Review state lives as long as the window: a review keeps running when you leave the section.
    @State private var review = ReviewModel()
    /// Knowledge state lives as long as the window: open note tabs and the commit queue's timer.
    @State private var knowledge = KnowledgeModel()

    var body: some View {
        @Bindable var model = model
        @Bindable var ask = ask
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
                                    AskAKitMenuItem(title: "The \(section.title) screen (sidebar item)",
                                                    facts: ["Sidebar group: \(group.title)", "Tooltip: \(section.summary)",
                                                            badge(for: section) > 0 ? "Number next to it: \(badge(for: section))" : ""],
                                                    screen: section)
                                }
                                .tag(section)
                        }
                    } header: {
                        Text(group.title).help(group.summary)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
            .safeAreaInset(edge: .bottom) {
                if DebugSnapshot.options?.demo != true {
                    VStack(spacing: 0) {
                        UpdateButton()
                        BuildBadge(info: .current)
                    }
                }
            }
        } detail: {
            switch model.section ?? .overview {
            case .overview: OverviewView()
            case .skills: SkillsView()
            case .skillsSh: SkillsShView()
            case .mcp: MCPView()
            case .instructions: InstructionsView()
            case .sessions: SessionsView()
            case .usage: UsageView()
            case .insights: InsightsView()
            case .lab: LabView()
            case .analysis: ErrorAnalysisView()
            case .brain: BrainView()
            case .review: ReviewView()
            case .knowledge: KnowledgeView()
            }
        }
        .environment(review)
        .environment(knowledge)
        // Ask AKit: a chat beside every screen (Help → Ask AKit, ⌥⌘/).
        .inspector(isPresented: $ask.isOpen) {
            AskAKitPanel()
                .inspectorColumnWidth(min: 300, ideal: 380, max: 600)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Ask AKit", systemImage: "questionmark.bubble") { ask.toggle() }
                    .help("Ask what something on this screen means or how to use it (⌥⌘/)")
            }
        }
        .onChange(of: model.section ?? .overview, initial: true) { _, section in ask.section = section }
        // Mode names and definitions, and the ids made from them or from prompts, come from
        // sessions: never sent as screen data.
        .onAppear {
            ask.sessionTexts = { [analysis] in
                analysis.data.modes.flatMap { [$0.name, $0.definition] }
                    + analysis.data.controlTasks.filter { if case .commit = $0.source { false } else { true } }.flatMap { [$0.title, $0.prompt] }
            }
        }
        .environment(analysis)
        // Skill switch changes (Skills, Insights): one sheet for the whole window.
        .skillSwitchSheet(model)
        .skillInvocationSheet(model)
        // MCP switch changes (MCP Servers, Insights).
        .mcpSwitchSheet(model)
        // A newer AKit in the source folder: the Update button above the build badge.
        .task { if DebugSnapshot.options == nil { await update.watch() } else { await update.check() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await update.checkSoon() }
        }
        // Lab runs start and end outside AKit: keep the badge and the queue current.
        .task { if DebugSnapshot.options == nil { await model.watchLab() } else { await model.reloadLab() } }
        .overlay(alignment: .bottom) {
            if rebuild.state == .building {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(rebuild.target == .install ? "Updating AKit… It restarts when the new version is installed."
                                                    : "Rebuilding AKit… It restarts when the build is done.")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
            } else if let notice = model.diagnosticsNotice {
                Label(notice, systemImage: "stethoscope")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
            }
        }
        .alert(rebuild.target == .install ? "Couldn't update AKit" : "Couldn't rebuild AKit", isPresented: Binding(get: { rebuildError != nil },
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
