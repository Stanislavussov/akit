import AKitFoundation
import AKitModel
import Foundation

/// The instruction files (AGENTS.md, CLAUDE.md) the harnesses really loaded, read from their
/// recorded sessions: Claude Code's `instructions` attachment and the `project_context` section
/// of Pi's system message. It shows where a harness takes its global file on this Mac, even when
/// AKit looks in another place (a PI_CODING_AGENT_DIR the app doesn't see). Read-only.
public enum InstructionSightings {
    public enum Level: String, Codable, Sendable, Hashable {
        /// The harness's own global file (Claude's ~/.claude/CLAUDE.md, Pi's agent folder).
        case global
        /// A file in the session's folder or a folder above it.
        case project
    }

    /// One file, as the sessions loaded it.
    public struct Sighting: Sendable, Identifiable {
        public let path: String
        public let level: Level
        public let harnesses: [HarnessID]
        /// Session folders that loaded it and how many sessions there did, the busiest first.
        public let projects: [(path: String, sessions: Int)]
        public let sessions: Int
        public let lastSeen: Date
        /// The file is still there.
        public let exists: Bool
        public var id: String { "\(level.rawValue):\(path)" }
    }

    public struct Report: Sendable {
        public let days: Int
        /// Sessions read per harness, and how many of them recorded their instruction files.
        public let read: [HarnessID: Int]
        public let recorded: [HarnessID: Int]
        public let sightings: [Sighting]

        public var global: [Sighting] { sightings.filter { $0.level == .global } }
        /// Project files grouped by session folder, with the sessions there, the busiest folder first.
        public var byProject: [(project: String, files: [(file: Sighting, sessions: Int)])] {
            var groups: [String: [(file: Sighting, sessions: Int)]] = [:]
            for sighting in sightings where sighting.level == .project {
                for project in sighting.projects { groups[project.path, default: []].append((sighting, project.sessions)) }
            }
            return groups.map { (project: $0.key, files: $0.value.sorted { $0.sessions > $1.sessions }) }
                .sorted { ($0.files.map(\.sessions).max() ?? 0, $1.project) > ($1.files.map(\.sessions).max() ?? 0, $0.project) }
        }
    }

    /// The files loaded by the sessions changed in the last `days` days. Sessions in a folder
    /// that is gone (Lab's temporary runs) are left out.
    public static func scan(_ sessions: [SessionSummary], days: Int, now: Date = .now) -> Report {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        struct Tally { var level: Level; var harnesses: [HarnessID] = []; var projects: [String: Int] = [:]; var sessions = 0; var last = Date.distantPast }
        var tallies: [String: Tally] = [:], order: [String] = []
        var read: [HarnessID: Int] = [:], recorded: [HarnessID: Int] = [:]
        for session in sessions where session.modified >= since && SessionOverview.isAvailable(for: session.harness)
            && session.project.map({ FileWalk.isDirectory($0) }) ?? true {
            read[session.harness, default: 0] += 1
            guard let files = loaded(in: session) else { continue }
            recorded[session.harness, default: 0] += 1
            let project = session.project.map { $0.standardizedFileURL.path }
            for file in files {
                let key = "\(file.level.rawValue):\(file.path)"
                if tallies[key] == nil { tallies[key] = Tally(level: file.level); order.append(key) }
                if !tallies[key]!.harnesses.contains(session.harness) { tallies[key]!.harnesses.append(session.harness) }
                if let project { tallies[key]!.projects[project, default: 0] += 1 }
                tallies[key]!.sessions += 1
                tallies[key]!.last = max(tallies[key]!.last, session.modified)
            }
        }
        let sightings = order.map { key -> Sighting in
            let tally = tallies[key]!, path = String(key.drop { $0 != ":" }.dropFirst())
            return Sighting(path: path, level: tally.level, harnesses: tally.harnesses,
                            projects: tally.projects.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ($0.key, $0.value) },
                            sessions: tally.sessions, lastSeen: tally.last, exists: FileManager.default.fileExists(atPath: path))
        }
        .sorted { ($0.sessions, $1.path) > ($1.sessions, $0.path) }
        return Report(days: days, read: read, recorded: recorded, sightings: sightings)
    }

    /// The instruction files one session recorded; nil when it recorded none (older versions).
    static func loaded(in session: SessionSummary) -> [(path: String, level: Level)]? {
        switch session.harness {
        case .claudeCode: claudeFiles(in: session.file)
        case .pi: piFiles(in: session.file, cwd: session.project)
        default: nil
        }
    }

    /// Claude Code: the first `instructions` attachment of the main conversation. `User` and
    /// `Managed` files are global; `Project` and `Local` ones belong to the folder. Auto memory
    /// (`AutoMem`, MEMORY.md) isn't an instruction file AKit manages: left out.
    static func claudeFiles(in file: URL) -> [(path: String, level: Level)]? {
        var found: [(path: String, level: Level)]?
        JSONLines.scanHead(of: file) { entry in
            guard entry["type"] as? String == "attachment", !ClaudeLogFormat.isSidechain(entry),
                  let attachment = entry["attachment"] as? JSONLines.Object, attachment["type"] as? String == "instructions" else { return false }
            found = (attachment["files"] as? [JSONLines.Object] ?? []).compactMap { file in
                guard let path = file["path"] as? String else { return nil }
                let kind = (file["type"] as? String ?? "").lowercased()
                guard !kind.hasSuffix("mem") else { return nil }
                return (path, kind == "user" || kind == "managed" ? .global : .project)
            }
            return true
        }
        return found
    }

    /// Pi 1.0 and newer: the paths in the system message's `project_context`. Pi reads one file
    /// per folder from the session's folder up, and the global one from its agent folder: a file
    /// in no folder above the session's is the global one.
    static func piFiles(in file: URL, cwd: URL?) -> [(path: String, level: Level)]? {
        var found: [(path: String, level: Level)]?
        JSONLines.scanHead(of: file) { entry in
            guard entry["type"] as? String == "message", let message = entry["message"] as? JSONLines.Object,
                  message["role"] as? String == "system", let sections = message["sections"] as? JSONLines.Object else { return false }
            let context = sections["project_context"] as? String ?? ""
            found = paths(inPiContext: context).map { path in (path, isAbove(path, cwd: cwd) ? .project : .global) }
            return true
        }
        return found
    }

    static func paths(inPiContext text: String) -> [String] {
        text.matches(of: /<project_instructions path="([^"]*)">/).map { String($0.1) }
    }

    /// The file's folder is `cwd` or a folder above it.
    static func isAbove(_ path: String, cwd: URL?) -> Bool {
        guard let cwd else { return false }
        let folder = URL(filePath: path).deletingLastPathComponent().standardizedFileURL.path
        let here = cwd.standardizedFileURL.path
        return here == folder || here.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}
