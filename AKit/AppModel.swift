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
        let adapters = HarnessCatalog.allAdapters(custom: customHarnesses)
        guard let adapter = adapters.first(where: { $0.id == session.harness }) else { return SessionTranscript() }
        return try await Task.detached { try adapter.transcript(of: session) }.value
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
