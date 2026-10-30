import AKitFoundation
import AKitHarnesses
import AKitInstructions
import AKitModel
import AKitSessions
import Foundation

/// Global Instructions → Loaded in Sessions: the instruction files the recorded sessions really
/// loaded, next to the files AKit looks at. A global file the sessions loaded but AKit doesn't
/// know means the harness reads another folder than AKit (often a PI_CODING_AGENT_DIR or
/// CLAUDE_CONFIG_DIR that only the shell sets). Read-only.
extension GlobalInstructions {
    public struct Sightings: Sendable {
        public let report: InstructionSightings.Report
        /// Ids of the global files AKit doesn't look at (not among the Instructions screen's global files).
        public let unknown: Set<String>
        /// What doesn't match, one line each.
        public let notes: [String]

        public func isKnown(_ sighting: InstructionSightings.Sighting) -> Bool {
            !unknown.contains(sighting.id)
        }
    }

    /// The variables that move a harness's folders. Set only in the shell, AKit.app doesn't see them.
    static let folderVariables = ["PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR", "CLAUDE_CONFIG_DIR"]

    /// The sessions of the last `days` days against the global files AKit finds. `shell`: the
    /// login shell's variables (the app reads them): a folder variable only the shell sets moves
    /// where the sessions are read from, and gets a note. `sessions`: the app's list, used when
    /// the shell moves nothing (no second scan).
    public static func sightings(days: Int = 30, env: HarnessEnvironment, shell: [String: String]? = nil,
                                 sessions given: [SessionSummary]? = nil) -> Sightings {
        var scanEnv = env, moved: [String] = []
        for name in folderVariables {
            if let value = shell?[name], !value.isEmpty, value != env.variables[name] {
                scanEnv.variables[name] = value
                moved.append(name)
            }
        }
        let installations = HarnessCatalog.detectAll(in: scanEnv).filter { SessionOverview.isAvailable(for: $0.id) }
        let sessions = moved.isEmpty ? given ?? SessionScanner.scan(installations: installations, in: env)
            : SessionScanner.scan(installations: installations, in: scanEnv)
        let report = InstructionSightings.scan(sessions, days: days)
        var known = Set<String>()
        for harness in InstructionMove.installed(env) {
            for entry in InstructionScanner.view(harness: harness, project: nil, env: env).loaded where entry.level == .global {
                known.insert(InstructionEdit.realPath(entry.file))
            }
        }
        let unknown = Set(report.global.filter { !known.contains(InstructionEdit.realPath(URL(filePath: $0.path))) }.map(\.id))
        var notes = moved.map { name in
            "Your shell sets \(name)=\(scanEnv.variables[name] ?? ""), but AKit.app doesn't see it, so AKit's other screens use the default folder. The sessions below are read from the shell's folder."
        }
        notes += self.notes(report, unknown: unknown, installed: installations.map(\.id), env: scanEnv, home: env.homeDirectory)
        return Sightings(report: report, unknown: unknown, notes: notes)
    }

    static func notes(_ report: InstructionSightings.Report, unknown: Set<String>, installed: [HarnessID], env: HarnessEnvironment, home: URL) -> [String] {
        var notes: [String] = []
        for harness in installed {
            let read = report.read[harness] ?? 0, recorded = report.recorded[harness] ?? 0
            if read == 0 {
                var note = "AKit found no \(harness.displayName) sessions of the last \(report.days) days in \(FileWalk.tilde(sessionsFolder(harness, env: env), home: home))."
                if harness == .pi { note += " If Pi keeps them elsewhere, PI_CODING_AGENT_DIR or PI_CODING_AGENT_SESSION_DIR is set where AKit can't see it." }
                notes.append(note)
            } else if recorded == 0 {
                notes.append("None of \(read) \(harness.displayName) sessions recorded its instruction files (older \(harness.displayName) versions don't).")
            }
        }
        for sighting in report.global where sighting.exists && unknown.contains(sighting.id) {
            let path = FileWalk.tilde(URL(filePath: sighting.path), home: home)
            for harness in sighting.harnesses {
                let root = HarnessCatalog.configRoot(of: harness, in: env) ?? home
                let folder = FileWalk.tilde(root, home: home)
                if InstructionEdit.realPath(URL(filePath: sighting.path)).hasPrefix(InstructionEdit.realPath(root) + "/") {
                    notes.append("\(harness.displayName) loaded \(path) as a global file; AKit's Global Files don't list it (an import AKit doesn't follow).")
                } else {
                    let variable = harness == .pi ? "PI_CODING_AGENT_DIR" : "CLAUDE_CONFIG_DIR"
                    notes.append("\(harness.displayName) loaded \(path) as its global file, but AKit looks in \(folder). \(variable) is probably set where AKit can't see it.")
                }
            }
        }
        return notes
    }

    static func sessionsFolder(_ harness: HarnessID, env: HarnessEnvironment) -> URL {
        let root = HarnessCatalog.configRoot(of: harness, in: env) ?? env.homeDirectory
        return harness == .pi ? PiLogFormat.folder(configRoot: root, in: env) : root.appending(path: "projects")
    }

    /// The user's own text of an instruction file, without AKit's block and other tools' blocks:
    /// what Use as Core Text… puts into Edit…. nil when the file can't be read.
    public static func ownText(of file: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: file.path), let text = String(data: data, encoding: .utf8) else { return nil }
        return ownSections(of: text, managed: managedBlocks(in: text)).map { $0.text.trimmingCharacters(in: .newlines) }
            .joined(separator: "\n\n")
    }
}
