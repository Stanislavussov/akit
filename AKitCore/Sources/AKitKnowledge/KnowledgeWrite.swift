import AKitFoundation
import Foundation

/// Checked writes of files the app edits (a map's `.excalidraw`, step 2.2b): the bytes come from
/// the editor as they are (AKit never builds them), and a file that changed on disk since AKit
/// read it or last wrote it is never overwritten without the user's choice.
public enum KnowledgeWrite {
    public enum Outcome: Sendable, Equatable {
        /// Written; the hash is the new expected hash for the next save.
        case saved(hash: String)
        /// The file on disk is not the one AKit expected: nothing was written. `diskHash` is nil
        /// when the file is gone.
        case conflict(diskHash: String?)
    }

    /// Lowercase hex SHA-256 of the bytes.
    public static func hash(_ data: Data) -> String { Checksum.sha256(data) }

    /// The hash of a file's bytes now; nil when it can't be read.
    public static func hash(of file: URL) -> String? { (try? Data(contentsOf: file)).map(hash) }

    /// Writes `bytes` to `file` atomically, but only when the file's bytes on disk still hash to
    /// `expectedHash`; otherwise `.conflict` and nothing is written.
    public static func saveChecked(_ bytes: Data, to file: URL, expectedHash: String) throws -> Outcome {
        let disk = hash(of: file)
        guard disk == expectedHash else { return .conflict(diskHash: disk) }
        try bytes.write(to: file, options: .atomic)
        return .saved(hash: hash(bytes))
    }
}

extension KnowledgeBase {
    /// A map's file (`payments/maps/overview` → `areas/payments/maps/overview.excalidraw`).
    public func mapFile(_ id: String) -> URL { root.appending(path: mapPath(id)) }

    /// The base-relative path of a map id.
    public func mapPath(_ id: String) -> String { "areas/\(id).excalidraw" }

    /// Saves a map's bytes as the editor serialized them (`KnowledgeWrite.saveChecked`) and returns
    /// its base-relative path for the commit queue (U2) with the outcome. Only an existing map
    /// under `areas/` is written.
    public func saveMap(_ id: String, bytes: Data, expectedHash: String) throws(Failure) -> (path: String, outcome: KnowledgeWrite.Outcome) {
        let path = mapPath(id)
        guard KnowledgeGit.isInside(path), FileWalk.isRegularFile(mapFile(id)) else {
            throw Failure(message: "No map \(id) in \(root.path).")
        }
        do { return (path, try KnowledgeWrite.saveChecked(bytes, to: mapFile(id), expectedHash: expectedHash)) } catch {
            throw Failure(message: "Couldn't save \(path): \(error.localizedDescription)")
        }
    }
}
