import AKitCore
import Foundation
import Observation

/// App state. Screens only read it and call its methods.
@MainActor
@Observable
final class AppModel {
    private(set) var installations: [HarnessInstallation] = []
    private(set) var versions: [HarnessID: String] = [:]
    private(set) var skills: [Skill] = []
    /// Saved conversations of all installed harnesses, newest first.
    private(set) var sessions: [SessionSummary] = []
    private(set) var isScanning = false
    private(set) var lastScan: Date?

    /// Folders searched for projects (`~/Projects` by default). Stored per machine,
    /// so work and home can differ.
    var projectRoots: [String] {
        didSet { UserDefaults.standard.set(projectRoots, forKey: Self.projectRootsKey) }
    }

    /// Harnesses described by the user in `~/.akit/harnesses.json`.
    private(set) var customHarnesses: [CustomHarness] = []
    /// Set when `~/.akit/harnesses.json` can't be read; AKit then refuses to overwrite it.
    private(set) var customHarnessError: String?

    var checkedAdapters: [String] { HarnessCatalog.adapters.map(\.displayName) + customHarnesses.map(\.name) }
    var builtInNames: [String] { HarnessCatalog.adapters.map(\.displayName) }

    private static let projectRootsKey = "projectRoots"
    /// A refresh was requested while a scan was running: scan once more when it ends.
    private var rescanRequested = false

    init() {
        projectRoots = UserDefaults.standard.stringArray(forKey: Self.projectRootsKey) ?? ProjectFinder.defaultRoots
    }

    /// Re-detect harnesses, their versions and skills. Files are only read.
    func refresh() async {
        guard !isScanning else {
            rescanRequested = true
            return
        }
        isScanning = true
        repeat {
            rescanRequested = false
            await scan()
        } while rescanRequested
        isScanning = false
    }

    /// Moves a skill to the Trash, then rescans.
    func delete(_ skill: Skill) async throws {
        _ = try await Task.detached { try SkillRemover.moveToTrash(skill) }.value
        await refresh()
    }

    /// Messages of one session, read in the background.
    func transcript(of session: SessionSummary) async throws -> SessionTranscript {
        guard let adapter = adapter(for: session.harness) else { return SessionTranscript() }
        return try await Task.detached { try adapter.transcript(of: session) }.value
    }

    // MARK: System prompt

    /// Prompts caught from harnesses in this run of AKit, by harness and project.
    private(set) var capturedPrompts: [String: PromptSnapshot] = [:]

    func promptAccess(_ harness: HarnessID) -> SystemPromptAccess {
        adapter(for: harness)?.systemPromptAccess ?? .unavailable
    }

    /// The system prompt saved in this session, if the harness saves it.
    func recordedPrompt(in session: SessionSummary) async throws -> PromptSnapshot? {
        guard let adapter = adapter(for: session.harness) else { return nil }
        return try await Task.detached { try adapter.recordedPrompt(in: session) }.value
    }

    /// The newest saved system prompt among this harness's sessions in `project`.
    func latestRecordedPrompt(harness: HarnessID, project: URL) async throws -> (PromptSnapshot, SessionSummary)? {
        guard let adapter = adapter(for: harness) else { return nil }
        let candidates = sessions.filter { $0.harness == harness && $0.project?.standardizedFileURL == project.standardizedFileURL }
        return try await Task.detached {
            for session in candidates {
                if let prompt = try adapter.recordedPrompt(in: session) { return (prompt, session) }
            }
            return nil
        }.value
    }

    func capturedPrompt(harness: HarnessID, project: URL) -> PromptSnapshot? {
        capturedPrompts[Self.promptKey(harness, project)]
    }

    /// Asks the harness for its current system prompt in `project` (see PiPromptProbe).
    func capturePrompt(harness: HarnessID, project: URL) async throws {
        guard let adapter = adapter(for: harness) else { return }
        guard let prompt = try await adapter.capturePrompt(in: project, env: .current) else {
            throw NSError(domain: "AKit", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "\(adapter.displayName) couldn't be started: its command was not found."])
        }
        capturedPrompts[Self.promptKey(harness, project)] = prompt
    }

    private static func promptKey(_ harness: HarnessID, _ project: URL) -> String {
        "\(harness.rawValue)|\(project.standardizedFileURL.path)"
    }

    private func adapter(for harness: HarnessID) -> (any HarnessAdapter)? {
        HarnessCatalog.allAdapters(custom: customHarnesses).first { $0.id == harness }
    }

    /// Adds or replaces (same id) a custom harness and saves the file.
    func saveCustomHarness(_ harness: CustomHarness) throws {
        var list = customHarnesses
        if let index = list.firstIndex(where: { $0.id == harness.id }) {
            list[index] = harness
        } else {
            list.append(harness)
        }
        try writeCustomHarnesses(list)
    }

    func removeCustomHarness(_ harness: CustomHarness) throws {
        try writeCustomHarnesses(customHarnesses.filter { $0.id != harness.id })
    }

    private func writeCustomHarnesses(_ list: [CustomHarness]) throws {
        if let customHarnessError {
            throw NSError(domain: "AKit", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "~/.akit/harnesses.json could not be read (\(customHarnessError)). Fix or remove it first; AKit won't overwrite it."])
        }
        try CustomHarnessStore.save(list, in: .current)
        customHarnesses = list
        Task { await refresh() }
    }

    private func scan() async {
        let env = HarnessEnvironment.current
        let roots = projectRoots.map(env.expand)
        do {
            customHarnesses = try CustomHarnessStore.load(in: env)
            customHarnessError = nil
        } catch {
            customHarnessError = error.localizedDescription
        }
        let adapters = HarnessCatalog.allAdapters(custom: customHarnesses)
        let (found, skills, sessions) = await Task.detached {
            let found = HarnessCatalog.detectAll(in: env, adapters: adapters)
            let projects = ProjectFinder.projects(inRoots: roots)
            async let skills = SkillScanner.scan(installations: found, extraProjects: projects, adapters: adapters, in: env)
            async let sessions = SessionScanner.scan(installations: found, adapters: adapters, in: env)
            return (found, await skills, await sessions)
        }.value
        installations = found
        self.skills = skills
        self.sessions = sessions
        lastScan = .now

        var newVersions: [HarnessID: String] = [:]
        await withTaskGroup(of: (HarnessID, String?).self) { group in
            for item in found {
                guard let exe = item.executableURL else { continue }
                group.addTask { (item.id, await VersionProbe.version(of: exe, in: env)) }
            }
            for await (id, version) in group {
                if let version { newVersions[id] = version }
            }
        }
        versions = newVersions
    }
}
