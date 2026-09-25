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

    /// Adds or replaces (same id) a custom harness. The file is re-read right before
    /// saving, so hand edits made meanwhile are kept, and a broken file is never overwritten.
    func saveCustomHarness(_ harness: CustomHarness) throws {
        try updateCustomHarnesses { list in
            var list = list
            if let index = list.firstIndex(where: { $0.id == harness.id }) {
                list[index] = harness
            } else {
                list.append(harness)
            }
            return list
        }
    }

    func removeCustomHarness(_ harness: CustomHarness) throws {
        try updateCustomHarnesses { $0.filter { $0.id != harness.id } }
    }

    private func updateCustomHarnesses(_ change: ([CustomHarness]) throws -> [CustomHarness]) throws {
        do {
            customHarnesses = try CustomHarnessStore.update(in: .current, change)
            customHarnessError = nil
        } catch {
            throw NSError(domain: "AKit", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "~/.akit/harnesses.json was not changed: \(error.localizedDescription)"])
        }
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
        let (found, skills) = await Task.detached {
            let found = HarnessCatalog.detectAll(in: env, adapters: adapters)
            let projects = ProjectFinder.projects(inRoots: roots)
            return (found, SkillScanner.scan(installations: found, extraProjects: projects, adapters: adapters, in: env))
        }.value
        installations = found
        self.skills = skills
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
