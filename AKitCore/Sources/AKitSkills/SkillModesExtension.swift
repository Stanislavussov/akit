import AKitFoundation
import AKitHarnesses
import AKitModel
import Foundation

/// `akit skills extension install|status|uninstall`: Pi's `akit-skill-modes.ts` extension
/// (skill-modes.md, "Pi: the extension"), installed like the capture extension: an AKit marker
/// line, a preview first, a backup of a file AKit didn't write, a replacement only of AKit's own
/// file, and the Trash on uninstall. The text is `Resources/akit-skill-modes.ts`, copied into the
/// code by tools/gen-skill-modes-extension.sh (a test keeps the two equal).
public struct SkillModesExtension: Sendable {
    /// The marker in the file's first line: AKit wrote it and may replace or remove it.
    public static let marker = "akit-skill-modes: written by AKit"
    /// The Pi `make test-skill-modes-pi` passed on (the SDK with pi-ai's faux model); Doctor warns below it.
    public static let minPi = "1.5.2"
    public static var text: String { SkillModesExtensionSource.akit_skill_modes_ts }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public enum State: String, Codable, Sendable {
        /// No file; `current`: this AKit's text; `outdated`: AKit's, an older text; `foreign`: not AKit's.
        case missing, current, outdated, foreign
    }

    public struct Status: Codable, Sendable {
        public let path: String
        public let state: State
        /// Pi is on this Mac (its config folder, or `pi` on the PATH).
        public let piFound: Bool
        public var minPi = SkillModesExtension.minPi
    }

    public struct Plan: Sendable {
        public let file: URL
        /// The text written; nil for no write.
        public let text: String?
        /// What is there now.
        public let old: String?
        /// The file isn't AKit's: copied into ~/.akit/backups first.
        public let backup: Bool
        /// Moved to the Trash (uninstall).
        public let trash: Bool
        public let notes: [String]
        public var isEmpty: Bool { text == nil && !trash }

        /// Every write (with its diff) and note, one per line.
        public func text(home: URL) -> String {
            let shown = FileWalk.tilde(file, home: home)
            var lines: [String] = []
            if let text {
                if backup { lines.append("BACK UP \(shown) (not written by AKit) into ~/.akit/backups") }
                lines.append("\(old == nil ? "NEW" : "CHANGED") \(shown)")
                if let old { lines += TextDiff.unified(TextDiff.lines(from: old, to: text)) }
            }
            if trash { lines.append("TRASH \(shown)") }
            lines += notes.map { "note: \($0)" }
            if isEmpty, notes.isEmpty { lines.append("Nothing to do.") }
            return lines.joined(separator: "\n")
        }
    }

    let env: HarnessEnvironment

    public init(env: HarnessEnvironment) { self.env = env }

    var piRoot: URL { HarnessCatalog.configRoot(of: .pi, in: env) ?? env.piAgentDirectory }
    public var file: URL { piRoot.appending(path: "extensions/akit-skill-modes.ts") }

    public var piFound: Bool { FileManager.default.fileExists(atPath: piRoot.path) || env.findExecutable("pi") != nil }

    public func status() -> Status {
        let old = try? String(contentsOf: file, encoding: .utf8)
        let state: State = switch old {
        case nil: .missing
        case Self.text?: .current
        case let text? where text.contains(Self.marker): .outdated
        default: .foreign
        }
        return Status(path: file.path, state: state, piFound: piFound)
    }

    /// Writes the extension, or nothing when it is current. Refused without Pi.
    public func installPlan() throws(Failure) -> Plan {
        guard piFound else {
            throw Failure(message: "Pi was not found (\(FileWalk.tilde(piRoot, home: env.homeDirectory)), or pi on the PATH); no extension written.")
        }
        let old = try? String(contentsOf: file, encoding: .utf8)
        guard old != Self.text else { return Plan(file: file, text: nil, old: old, backup: false, trash: false, notes: ["The skill modes extension is current."]) }
        return Plan(file: file, text: Self.text, old: old, backup: old.map { !$0.contains(Self.marker) } ?? false, trash: false,
                    notes: old == nil ? ["Pi loads it at its next start (or /reload)."] : [])
    }

    /// Moves AKit's file to the Trash; leaves one AKit didn't write. The modes file stays.
    public func uninstallPlan() -> Plan {
        guard let old = try? String(contentsOf: file, encoding: .utf8) else {
            return Plan(file: file, text: nil, old: nil, backup: false, trash: false, notes: ["The skill modes extension is not installed."])
        }
        guard old.contains(Self.marker) else {
            return Plan(file: file, text: nil, old: old, backup: false, trash: false,
                        notes: ["\(FileWalk.tilde(file, home: env.homeDirectory)) was not written by AKit; left alone."])
        }
        return Plan(file: file, text: nil, old: old, backup: false, trash: true,
                    notes: ["\(FileWalk.tilde(SkillModes.file(home: env.homeDirectory), home: env.homeDirectory)) stays; nothing applies it without the extension."])
    }

    /// Carries out a plan: a backup of a file AKit didn't write, then the write; or the Trash.
    /// Refused when the file changed since the plan. Returns the backup folder, if one was made.
    @discardableResult
    public func execute(_ plan: Plan, trash: (URL) throws -> URL? = Trash.move) throws(Failure) -> URL? {
        let fm = FileManager.default
        let now = try? String(contentsOf: plan.file, encoding: .utf8)
        guard now == plan.old else {
            throw Failure(message: "\(FileWalk.tilde(plan.file, home: env.homeDirectory)) changed since the preview. Run it again.")
        }
        do {
            if plan.trash {
                _ = try trash(plan.file)
                return nil
            }
            guard let text = plan.text else { return nil }
            var backup: URL?
            if plan.backup {
                backup = try Backup.newFolder(home: env.homeDirectory)
                _ = try Backup.copy(plan.file, into: backup!, home: env.homeDirectory)
            }
            let folder = plan.file.deletingLastPathComponent()
            if !fm.fileExists(atPath: folder.path) {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try Data(text.utf8).write(to: plan.file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plan.file.path)
            return backup
        } catch {
            throw Failure(message: "Stopped: \(error.localizedDescription)")
        }
    }
}
