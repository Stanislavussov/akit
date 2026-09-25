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

    /// Folder new skills are installed into. nil = this harness can't take skills there.
    func skillInstallRoot(for scope: InstallScope, in env: HarnessEnvironment) -> URL?
}

extension HarnessAdapter {
    public func knownProjects(in env: HarnessEnvironment) -> [URL] { [] }
    public func skillRoots(in env: HarnessEnvironment, projects: [URL]) -> [SkillRoot] { [] }

    /// The first writable skill root of that scope.
    public func skillInstallRoot(for scope: InstallScope, in env: HarnessEnvironment) -> URL? {
        switch scope {
        case .global:
            return skillRoots(in: env, projects: []).first { $0.scope == .global && !$0.isReadOnly }?.url
        case .project(let project):
            return skillRoots(in: env, projects: [project]).first { $0.scope == .project(project) && !$0.isReadOnly }?.url
        }
    }
}

/// All known adapters.
public enum HarnessCatalog {
    public static let adapters: [any HarnessAdapter] = [
        ClaudeCodeAdapter(),
        PiAdapter(),
        OpenCodeAdapter(),
        CodexAdapter(),
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
