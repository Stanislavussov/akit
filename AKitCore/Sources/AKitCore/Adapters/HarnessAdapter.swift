import Foundation

/// An adapter is the "translator" for one harness.
/// It knows where the harness keeps its files and in which format.
/// The UI only talks to this protocol, so a new harness is added
/// with a new adapter, without touching the screens.
///
/// The protocol grows with the MVP steps: skills → writing → agents/MCP.
public protocol HarnessAdapter: Sendable {
    var id: HarnessID { get }
    var displayName: String { get }

    /// Whether the harness is installed here and where its configs are. nil = not found.
    func detect(in env: HarnessEnvironment) -> HarnessInstallation?

    /// Project folders this harness already knows about (e.g. from its history).
    func knownProjects(in env: HarnessEnvironment) -> [URL]

    /// Folders the harness reads skills from, global and for the given projects.
    func skillRoots(in env: HarnessEnvironment, projects: [URL]) -> [SkillRoot]
}

extension HarnessAdapter {
    public func knownProjects(in env: HarnessEnvironment) -> [URL] { [] }
    public func skillRoots(in env: HarnessEnvironment, projects: [URL]) -> [SkillRoot] { [] }
}

/// All known adapters.
public enum HarnessCatalog {
    public static let adapters: [any HarnessAdapter] = [
        ClaudeCodeAdapter(),
        PiAdapter(),
    ]

    /// Built-in adapters plus the user's own from `~/.akit/harnesses.json`.
    public static func allAdapters(custom: [CustomHarness]) -> [any HarnessAdapter] {
        adapters + custom.map(CustomHarnessAdapter.init)
    }

    /// Detect all installed harnesses.
    public static func detectAll(in env: HarnessEnvironment = .current,
                                 adapters: [any HarnessAdapter] = HarnessCatalog.adapters) -> [HarnessInstallation] {
        adapters.compactMap { $0.detect(in: env) }
    }
}
