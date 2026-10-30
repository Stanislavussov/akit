import AKitBrain
import AKitFoundation
import Foundation

/// Delete… on Review → Roles and Scenarios (`akit review role|scenario delete`): the item goes to
/// the Trash with what is bound to it. At the brain level that is every project's own copy, the
/// profiles' `default_scenario` that names it, and for a scenario the roles no other scenario or
/// profile uses; the id goes to `removed:` of the brain's review.yaml, so a built-in one stays
/// hidden and what still names it skips it. At a project level only the project's own items go.
extension ReviewConfigEditor {
    /// A file whose text changes with the delete.
    public struct Edit: Sendable {
        public var file: URL
        public var old: String?
        public var new: String
        public var diff: [String]
    }

    public struct Removal: Sendable {
        public var kind: Kind
        public var id: String
        public var level: Level
        /// Files and folders that go to the Trash.
        public var trash: [URL]
        /// review.yaml (`removed:`) and the profiles (`default_scenario`).
        public var edits: [Edit]
        /// Roles deleted with a scenario: no other scenario or profile uses them.
        public var roles: [String]
        /// Roles of the scenario that stay: something else uses them.
        public var kept: [String]
        /// Whether the roles only the scenario uses were asked to go too.
        public var withRoles: Bool
        /// Why AKit kept roles it would otherwise delete.
        public var notes: [String] = []
    }

    /// What a delete would do. Nothing is changed.
    public static func planDelete(_ kind: Kind, id: String, level: Level, withRoles: Bool = true, catalog: ReviewCatalog,
                                  home: URL, brain: URL) throws -> Removal {
        guard kind == .role || kind == .scenario else { throw Failure(message: "Only a role or a scenario can be deleted here.") }
        guard ReviewYAML.isID(id) else { throw Failure(message: "\(id): use a-z, 0-9 and -.") }
        let name = kind.rawValue
        var removal = Removal(kind: kind, id: id, level: level, trash: [], edits: [], roles: [], kept: [], withRoles: withRoles)
        // A file AKit couldn't read may name a role: then no role goes with a scenario.
        let rolesSafe = catalog.problems.isEmpty
        if kind == .scenario, withRoles, !rolesSafe {
            removal.notes.append("No role goes with it: AKit couldn't read some review files, and they may use its roles ("
                                 + catalog.problems.prefix(2).joined(separator: " ") + ").")
        }
        let fileManager = FileManager.default
        /// The file or folder of an item at a level, when it exists.
        func own(_ kind: Kind, _ id: String, _ level: Level) -> URL? {
            let url = file(kind, id: id, level: level, home: home, brain: brain)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return kind == .role ? url.deletingLastPathComponent() : url
        }
        func profileEdit(_ profile: ReviewProfile) throws {
            guard profile.defaultScenario == id, kind == .scenario, let url = profile.file,
                  let old = try? String(contentsOf: url, encoding: .utf8) else { return }
            let new = settingTopLevel("default_scenario", nil, in: old)
            guard (try? ReviewProfile.parse(new, slug: profile.slug))?.defaultScenario == nil else {
                throw Failure(message: "AKit couldn't take default_scenario: \(id) out of \(url.lastPathComponent): edit the profile first.")
            }
            removal.edits.append(Edit(file: url, old: old, new: new, diff: TextDiff.unified(TextDiff.lines(from: old, to: new))))
        }

        switch level {
        case .brain:
            let inBrain = kind == .role ? catalog.roles.contains { $0.id == id } : catalog.scenarios.contains { $0.id == id }
            let copies = catalog.profiles.map(\.slug).filter { slug in
                kind == .role ? (catalog.projectRoles[slug] ?? []).contains { $0.id == id } : (catalog.projectScenarios[slug] ?? []).contains { $0.id == id }
            }
            guard inBrain else {
                guard copies.isEmpty else {
                    throw Failure(message: "\(name.capitalized) \(id) is only a project's own (\(copies.joined(separator: ", "))): delete it at that project's level (--project P).")
                }
                throw Failure(message: "There is no \(name) \(id).")
            }
            var deleteRoles: [String] = kind == .role ? [id] : []
            if kind == .scenario {
                removal.trash += [own(.scenario, id, .brain)].compactMap { $0 } + copies.compactMap { own(.scenario, id, .project($0)) }
                for profile in catalog.profiles { try profileEdit(profile) }
                // Its roles: in the brain's scenario and in the projects' copies.
                var candidates: [String] = []
                for scenario in catalog.scenarios.filter({ $0.id == id }) + catalog.projectScenarios.values.flatMap({ $0.filter { $0.id == id } }) {
                    for role in scenario.roleIDs where !candidates.contains(role) { candidates.append(role) }
                }
                let others = catalog.scenarios.filter { $0.id != id } + catalog.projectScenarios.values.flatMap { $0.filter { $0.id != id } }
                let used = Set(others.flatMap(\.roleIDs) + catalog.profiles.flatMap(\.rolesAdd))
                let known = Set(catalog.roles.map(\.id) + catalog.projectRoles.values.flatMap { $0.map(\.id) })
                let existing = candidates.filter(known.contains)
                removal.kept = existing.filter(used.contains)
                if withRoles, rolesSafe { deleteRoles = existing.filter { !used.contains($0) } }
                removal.roles = deleteRoles
            }
            for role in deleteRoles {
                removal.trash += [own(.role, role, .brain)].compactMap { $0 }
                for slug in catalog.profiles.map(\.slug) {
                    // A role deleted with a scenario: only in the projects whose copy of it named the role.
                    if kind == .scenario, role != id,
                       !(catalog.projectScenarios[slug] ?? []).contains(where: { $0.id == id && $0.roleIDs.contains(role) }) { continue }
                    removal.trash += [own(.role, role, .project(slug))].compactMap { $0 }
                }
            }
            // The ids go to removed: so built-in ones stay hidden.
            let url = file(.defaults, id: "", level: .brain, home: home, brain: brain)
            let old = try? String(contentsOf: url, encoding: .utf8)
            var new = old ?? ""
            let roles = (catalog.removedRoles.union(deleteRoles)).sorted()
            let scenarios = (kind == .scenario ? catalog.removedScenarios.union([id]) : catalog.removedScenarios).sorted()
            if roles != catalog.removedRoles.sorted() { new = settingKey("roles", "[" + roles.joined(separator: ", ") + "]", block: "removed", in: new) }
            if scenarios != catalog.removedScenarios.sorted() {
                new = settingKey("scenarios", "[" + scenarios.joined(separator: ", ") + "]", block: "removed", in: new)
            }
            if new != (old ?? "") {
                let block = (try? ReviewYAML.map(new))?["removed"] as? [String: Any] ?? [:]
                guard ReviewYAML.strings(block["roles"]).sorted() == roles, ReviewYAML.strings(block["scenarios"]).sorted() == scenarios,
                      (try? ReviewSettingsPatch.parse(ReviewYAML.map(new), where: "review.yaml")) == (try? ReviewSettingsPatch.parse(ReviewYAML.map(old ?? ""), where: "review.yaml")) else {
                    throw Failure(message: "AKit couldn't add \(id) to removed: in review.yaml by itself: edit review.yaml first.")
                }
                removal.edits.append(Edit(file: url, old: old, new: new, diff: TextDiff.unified(TextDiff.lines(from: old ?? "", to: new))))
            }
        case .project(let slug):
            guard let profile = catalog.profiles.first(where: { $0.slug == slug }) else { throw Failure(message: "There is no project profile \(slug).") }
            guard let target = own(kind, id, level) else { throw Failure(message: "\(slug) has no own \(name) \(id).") }
            let inBrain = kind == .role ? catalog.roles.contains { $0.id == id } : catalog.scenarios.contains { $0.id == id }
            if inBrain {
                throw Failure(message: "\(slug)'s \(name) \(id) is its copy of the brain's: Reset to Brain moves the copy to the Trash. "
                              + "To delete \(id) everywhere, delete it at the Brain level.")
            }
            if kind == .role {
                // A project's own role its scenarios or profile still name would stop their runs.
                let users = catalog.scenarios(for: profile).filter { $0.roleIDs.contains(id) }.map(\.id)
                    + (profile.rolesAdd.contains(id) ? ["the profile's roles: add"] : [])
                guard users.isEmpty else {
                    throw Failure(message: "\(slug)'s role \(id) is still used by \(users.joined(separator: ", ")): take it out there first.")
                }
            }
            removal.trash.append(target)
            if kind == .scenario {
                try profileEdit(profile)
                let scenario = (catalog.projectScenarios[slug] ?? []).first { $0.id == id }
                let others = catalog.scenarios(for: profile).filter { $0.id != id }
                let used = Set(others.flatMap(\.roleIDs) + profile.rolesAdd)
                // Only the project's own roles: the brain's belong to every project.
                let ownRoles = Set((catalog.projectRoles[slug] ?? []).map(\.id)).subtracting(catalog.roles.map(\.id))
                let candidates = (scenario?.roleIDs ?? []).filter(ownRoles.contains)
                removal.kept = candidates.filter(used.contains)
                if withRoles, rolesSafe {
                    removal.roles = candidates.filter { !used.contains($0) }
                    removal.trash += removal.roles.compactMap { own(.role, $0, level) }
                }
            }
        }
        return removal
    }

    /// Does it: the edits are written, the files go to the Trash, and what is in the brain is
    /// committed there in one commit.
    public static func applyDelete(_ removal: Removal, brain: URL, env: HarnessEnvironment,
                                   trash: (URL) throws -> URL? = Trash.move) async throws {
        let root = brain.resolvingSymlinksInPath().path
        func inBrain(_ url: URL) -> String? {
            let path = url.resolvingSymlinksInPath().path
            return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
        }
        // The files may have changed since the user saw the list: plan again and compare.
        let home = env.homeDirectory
        let fresh = try planDelete(removal.kind, id: removal.id, level: removal.level, withRoles: removal.withRoles,
                                   catalog: ReviewCatalog.load(home: home, brain: brain), home: home, brain: brain)
        guard fresh.trash.map(\.path).sorted() == removal.trash.map(\.path).sorted(),
              fresh.edits.map({ $0.file.path + "\n" + $0.new }).sorted() == removal.edits.map({ $0.file.path + "\n" + $0.new }).sorted() else {
            throw Failure(message: "The review files changed since this list was made. Nothing was deleted; open Delete… again.")
        }
        let brainPaths = (removal.edits.map(\.file) + removal.trash).compactMap(inBrain)
        if !brainPaths.isEmpty, let problem = await BrainGit.commitProblem(brain: brain, env: env) { throw Failure(message: problem) }
        // Only what git knows can be committed as deleted.
        var tracked = Set<String>()
        if let git = env.findExecutable("git"), !brainPaths.isEmpty,
           let listed = await ProcessRunner.run(git, arguments: ["ls-files", "--"] + brainPaths, directory: brain, environment: env.gitVariables, timeout: 30) {
            let files = listed.output.split(separator: "\n").map(String.init)
            tracked = Set(brainPaths.filter { path in files.contains { $0 == path || $0.hasPrefix(path + "/") } })
        }
        // The Trash first: a move that fails leaves the files as they were.
        for url in removal.trash { _ = try trash(url) }
        for edit in removal.edits {
            try FileManager.default.createDirectory(at: edit.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(edit.new.utf8).write(to: edit.file, options: .atomic)
        }
        let commitPaths = brainPaths.filter { path in tracked.contains(path) || removal.edits.contains { inBrain($0.file) == path } }
        guard !commitPaths.isEmpty else { return }
        let with = removal.roles.filter { $0 != removal.id }
        let message = "Review: delete \(removal.kind.rawValue) \(removal.id)" + (with.isEmpty ? "" : " and roles " + with.joined(separator: ", "))
        do {
            try await BrainRemove.commit(commitPaths, message, in: brain, env: env)
        } catch {
            throw Failure(message: error.message)
        }
    }

    /// The delete in lines a person reads: what goes to the Trash, what changes, what stays.
    public static func describe(_ removal: Removal) -> [String] {
        var lines = removal.notes
        if removal.kind == .scenario, !removal.roles.isEmpty {
            lines.append("Roles only this scenario uses, deleted too: " + removal.roles.joined(separator: ", ") + ".")
        }
        if !removal.kept.isEmpty {
            lines.append("Roles that stay (other scenarios or profiles use them): " + removal.kept.joined(separator: ", ") + ".")
        }
        lines += removal.trash.map { "To the Trash: \($0.path)" }
        for edit in removal.edits { lines.append("Changes: \(edit.file.path)") }
        if removal.level == .brain {
            lines.append("Built-in items with these ids stay hidden (removed: in review.yaml); scenarios and profiles that still name them skip them.")
        }
        return lines
    }
}
