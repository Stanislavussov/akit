import AKitAttention
import AKitFoundation
import Foundation

/// The Attention screen's data (docs/design/attention.md): what every other screen has that
/// needs the person, and where it lives.
extension AppModel {
    /// Items not dismissed, as listed and counted by the sidebar badge.
    var attentionShown: [AttentionItem] { attention.filter { !attentionDismissals.hides($0) } }

    /// Reads every source again, off the main thread: flow runs of many projects take a moment.
    func reloadAttention() async {
        let env = HarnessEnvironment.current
        let brain = brain
        let projects = projects
        let items = await Task.detached { Attention.collect(env: env, brain: brain, projects: projects) }.value
        if items != attention { attention = items }
        let dismissals = AttentionDismissals.load(home: env.homeDirectory)
        if dismissals != attentionDismissals { attentionDismissals = dismissals }
    }

    /// Runs, reviews and checks end outside AKit: read again every 30 seconds while the window lives.
    func watchAttention() async {
        while !Task.isCancelled {
            await reloadAttention()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    /// Hides the items until they change (a new status, another check).
    func dismissAttention(_ items: [AttentionItem]) {
        let home = HarnessEnvironment.current.homeDirectory
        try? AttentionDismissals.dismiss(items, current: attention, home: home)
        attentionDismissals = AttentionDismissals.load(home: home)
    }

    func restoreAttention(_ items: [AttentionItem]) {
        let home = HarnessEnvironment.current.homeDirectory
        try? AttentionDismissals.restore(items.map(\.id), home: home)
        attentionDismissals = AttentionDismissals.load(home: home)
    }

    /// Shows the place an item lives: its screen, tab and the run, batch, layer or server in it.
    /// Also what an `akit://<screen>?item=…` link from `akit attention` opens.
    func open(_ link: AttentionLink, review: ReviewModel, knowledge: KnowledgeModel) {
        switch link.screen {
        case "lab":
            revealLabRun = link.item
            section = .lab
        case "review":
            if let id = link.item { review.open(id) }
            section = .review
        case "analysis":
            switch link.tab {
            case "reports" where link.item != nil: revealBatch = link.item
            case "evals" where link.item != nil: showLayerSet(link.item!)
            default: revealAnalysisTab = link.tab
            }
            section = .analysis
        case "runs":
            revealFlowRun = link.item
            section = .runs
        case "mcp":
            revealMCPCheck = link.item
            section = .mcp
        case "knowledge":
            section = .knowledge
            Task {
                if knowledge.bases.isEmpty { await knowledge.load() }
                if let folder = link.folder, let base = knowledge.bases.first(where: { $0.root.path == folder }) {
                    knowledge.choose(base: base)
                }
                if link.tab == "inbox" { knowledge.screenTab = .inbox }
            }
        case "brain":
            revealBrainLayer = link.item
            section = .brain
        default:
            if let screen = SidebarSection.allCases.first(where: { $0.rawValue.lowercased() == link.screen }) { section = screen }
        }
    }
}
