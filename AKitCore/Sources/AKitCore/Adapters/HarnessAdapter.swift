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

    /// Saved conversations (any order). Empty if the harness keeps none or AKit can't read them.
    func sessions(in env: HarnessEnvironment) -> [SessionSummary]

    /// Messages of one saved session from `sessions(in:)`.
    func transcript(of session: SessionSummary) throws -> SessionTranscript

    /// The system prompt the harness saved inside this session, if it saves one.
    func recordedPrompt(in session: SessionSummary) throws -> PromptSnapshot?

    /// How AKit can show this harness's system prompt.
    var systemPromptAccess: SystemPromptAccess { get }

    /// Starts the harness in `project` to read the system prompt it would send now.
    /// Must not contact the model or save a session.
    func capturePrompt(in project: URL, env: HarnessEnvironment) async throws -> PromptSnapshot?

    /// Folder new skills are installed into. nil = this harness can't take skills there.
    func skillInstallRoot(for scope: InstallScope, in env: HarnessEnvironment) -> URL?
}

extension HarnessAdapter {
    public func knownProjects(in env: HarnessEnvironment) -> [URL] { [] }
    public func skillRoots(in env: HarnessEnvironment, projects: [URL]) -> [SkillRoot] { [] }
    public func sessions(in env: HarnessEnvironment) -> [SessionSummary] { [] }
    public func transcript(of session: SessionSummary) throws -> SessionTranscript { SessionTranscript() }
    public func recordedPrompt(in session: SessionSummary) throws -> PromptSnapshot? { nil }
    public var systemPromptAccess: SystemPromptAccess { .unavailable }
    public func capturePrompt(in project: URL, env: HarnessEnvironment) async throws -> PromptSnapshot? { nil }

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

public enum SystemPromptAccess: Sendable {
    case unavailable
    /// Saved inside session files: `recordedPrompt(in:)`.
    case recorded
    /// Asked from the harness on demand: `capturePrompt(in:env:)`.
    case captured
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
