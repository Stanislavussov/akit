import AKitFoundation
import AKitLab
import Foundation

/// Where error analysis keeps its files on this Mac (`docs/design/error-analysis.md`,
/// "Storage"). Local only: nothing here is ever part of the brain.
public struct AnalysisPaths: Sendable {
    /// `~/.akit/lab/analysis`: a local git repository (no remote) that tracks `modes/` only.
    public let folder: URL

    public init(env: HarnessEnvironment) {
        folder = LabPaths(env: env).folder.appending(path: "analysis", directoryHint: .isDirectory)
    }

    public var modes: URL { folder.appending(path: "modes", directoryHint: .isDirectory) }
    public var modesFile: URL { modes.appending(path: "modes.json") }
    /// Quotes from scrubbed transcripts, kept apart from the definitions.
    public var exemplars: URL { modes.appending(path: "exemplars", directoryHint: .isDirectory) }
    public var notes: URL { folder.appending(path: "notes", directoryHint: .isDirectory) }
    public var checks: URL { folder.appending(path: "checks", directoryHint: .isDirectory) }
    public var labels: URL { folder.appending(path: "labels", directoryHint: .isDirectory) }
    public var batches: URL { folder.appending(path: "batches", directoryHint: .isDirectory) }
    public var fixes: URL { folder.appending(path: "fixes", directoryHint: .isDirectory) }

    /// `notes/<session-key>.json`; the key is made safe for a file name.
    public func notes(of sessionKey: String) -> URL {
        notes.appending(path: Self.fileName(sessionKey) + ".json")
    }

    public func check(of modeID: String) -> URL {
        checks.appending(path: Self.fileName(modeID) + ".json")
    }

    public func batch(_ runID: String) -> URL {
        batches.appending(path: Self.fileName(runID) + ".json")
    }

    /// Letters, digits, `-`, `_` and `.` stay; everything else (the `:` of a session key, `/`)
    /// becomes `_`, so a key can never name a path outside its folder.
    public static func fileName(_ key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let safe = String(key.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "_" })
        return safe.hasPrefix(".") ? "_" + safe.dropFirst() : safe
    }
}
