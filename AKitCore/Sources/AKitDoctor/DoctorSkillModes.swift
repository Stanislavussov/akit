import AKitBrain
import AKitFoundation
import AKitSkills
import Foundation

extension Doctor {
    /// The Skill modes lines (skill-modes.md, "Doctor"): the modes file (one that doesn't parse
    /// is a problem, skipped entries are notes), the Pi extension that applies it (missing or
    /// outdated is a problem once there are entries), a Pi older than the one the end-to-end test
    /// ran on, and entries for names no skill in their project has (for projects found on this Mac).
    /// `piVersion`: `pi --version`'s text, nil without Pi.
    static func skillModeLines(piFound: Bool, piVersion: String?, projects: [URL], projectsRoot: URL, env: HarnessEnvironment,
                               tilde: (URL) -> String) -> [String] {
        let home = env.homeDirectory
        let file = SkillModes.file(home: home)
        let reading = SkillModes.read(file, home: home)
        var lines: [String] = []
        if !reading.exists {
            lines.append("  no skill modes set (\(tilde(file)); akit skills mode)")
        } else if !reading.usable {
            lines += reading.problems.map { "! \($0.message)" }
        } else {
            let count = reading.projects.count
            lines.append("  \(tilde(file)): \(count) project\(count == 1 ? "" : "s") with skill modes")
            lines += reading.problems.map { "  note: \($0.message)" }
        }
        guard piFound else {
            if !reading.projects.isEmpty { lines.append("  no Pi: skill modes apply in Pi only") }
            return lines
        }
        let state = SkillModesExtension(env: env).status()
        let used = !reading.projects.isEmpty
        switch state.state {
        case .current: lines.append("  Pi extension: \(tilde(URL(filePath: state.path))), current")
        case .missing:
            lines.append(used ? "! the Pi extension that applies skill modes is missing: akit skills extension install"
                         : "  Pi extension: not installed (akit skills extension install, once a mode is set)")
        case .outdated:
            lines.append("! the Pi extension that applies skill modes is older than this AKit: akit skills extension install")
        case .foreign:
            lines.append("! \(tilde(URL(filePath: state.path))) is not AKit's file; skill modes may not apply. Move it away, then akit skills extension install")
        }
        if let version = piVersion.flatMap(Self.versionNumber),
           version.compare(SkillModesExtension.minPi, options: .numeric) == .orderedAscending {
            lines.append("! skill modes may not apply in Pi \(version) (checked on \(SkillModesExtension.minPi)); update Pi.")
        }
        // Entries naming no skill in their project: only projects with entries that are on this Mac.
        guard used else { return lines }
        var folders: [String: URL] = [:]
        for folder in projects {
            guard let id = ProjectRecords.projectID(ofFolder: folder, projectsRoot: projectsRoot.path), reading.projects[id] != nil,
                  folders[id] == nil else { continue }
            folders[id] = GitCheckout.containing(folder).map(\.folder) ?? folder
        }
        for (id, folder) in folders.sorted(by: { $0.key < $1.key }) {
            let skills = SkillModes.piSkills(in: folder, env: env)
            let resolution = SkillModes.resolve(file: reading, skills: skills, projectID: id, userFolders: SkillModes.piUserFolders(in: env))
            let known = Set(skills.map(\.name)).union(resolution.renames.keys)
            let missing = reading.entries(for: id).keys.filter { !known.contains($0) }.sorted()
            if !missing.isEmpty {
                lines.append("  note: \(id): no skill named \(missing.joined(separator: ", ")) in \(tilde(folder)) (akit skills mode NAME --reset there takes an entry out)")
            }
        }
        return lines
    }

    /// `1.5.2` from `pi --version`'s text (`1.5.2`, `pi 1.5.2`, `v1.5.2`).
    static func versionNumber(_ text: String) -> String? {
        text.firstMatch(of: /\d+(\.\d+)+/).map { String($0.output.0) }
    }
}
