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
        /// Real paths of the global files AKit looks at (the Instructions screen's global files).
        public let known: Set<String>
        /// What doesn't match, one line each.
        public let notes: [String]

        public func isKnown(_ sighting: InstructionSightings.Sighting) -> Bool {
            known.contains(InstructionEdit.realPath(URL(filePath: sighting.path)))
        }
    }

    /// The sessions of the last `days` days against the global files AKit finds.
    public static func sightings(days: Int = 30, env: HarnessEnvironment) -> Sightings {
        let installations = HarnessCatalog.detectAll(in: env).filter { SessionOverview.isAvailable(for: $0.id) }
        let report = InstructionSightings.scan(SessionScanner.scan(installations: installations, in: env), days: days)
        var known = Set<String>()
        for harness in InstructionMove.installed(env) {
            for entry in InstructionScanner.view(harness: harness, project: nil, env: env).loaded where entry.level == .global {
                known.insert(InstructionEdit.realPath(entry.file))
            }
        }
        return Sightings(report: report, known: known, notes: notes(report, known: known, installed: installations.map(\.id), env: env))
    }

    static func notes(_ report: InstructionSightings.Report, known: Set<String>, installed: [HarnessID], env: HarnessEnvironment) -> [String] {
        var notes: [String] = []
        for harness in installed {
            let read = report.read[harness] ?? 0, recorded = report.recorded[harness] ?? 0
            if read == 0 {
                notes.append("AKit found no \(harness.displayName) sessions of the last \(report.days) days in \(FileWalk.tilde(sessionsFolder(harness, env: env), home: env.homeDirectory)).")
            } else if recorded == 0 {
                notes.append("None of \(read) \(harness.displayName) sessions recorded its instruction files (older \(harness.displayName) versions don't).")
            }
        }
        for sighting in report.global where sighting.exists && !known.contains(InstructionEdit.realPath(URL(filePath: sighting.path))) {
            let path = FileWalk.tilde(URL(filePath: sighting.path), home: env.homeDirectory)
            for harness in sighting.harnesses {
                let folder = FileWalk.tilde(HarnessCatalog.configRoot(of: harness, in: env) ?? env.homeDirectory, home: env.homeDirectory)
                let variable = harness == .pi ? "PI_CODING_AGENT_DIR" : "CLAUDE_CONFIG_DIR"
                notes.append("\(harness.displayName) loaded \(path) as its global file, but AKit looks in \(folder). \(variable) is probably set in your shell and AKit doesn't see it.")
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
