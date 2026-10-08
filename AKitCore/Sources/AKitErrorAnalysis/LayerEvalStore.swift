import AKitFoundation
import AKitLab
import Foundation

/// One layer eval as it was queued: the exact setups (so Continue reuses them and comparison
/// rows don't split), the tasks, and what was blocked or noted.
/// `~/.akit/lab/evals/layer-evals/<id>/manifest.json`.
public struct LayerEvalManifest: Codable, Sendable, Hashable, Identifiable {
    public static let schemaVersion = 1

    public var schema = LayerEvalManifest.schemaVersion
    public var id: String
    public var layer: String
    public var createdAt: Date
    public var brainCommit: String
    /// `[requiredOnly, layer]`, verbatim.
    public var setups: [ControlSetup]
    public var sanity: ControlSetup?
    public var tasks: [String]
    public var sanityTasks: [String]
    public var repeats: Int
    public var blocked: [String: String]
    public var notes: [String: [String]]
    public var overlap: [String]

    /// The agent of the eval's setups.
    public var agent: LabAgent? { setups.first?.agent }
}

/// The eval folders: `layer-evals/<id>/manifest.json` and `overlays/<hash>/`. Nothing of an
/// eval goes into the brain.
public enum LayerEvalStore {
    /// Writes the eval's folder under a temporary name, then moves it into place, so a reader
    /// never sees half an eval. A continued eval already has its folder.
    @discardableResult
    public static func create(_ prepared: LayerSetups.Prepared, repeats: Int, now: Date = .now,
                              env: HarnessEnvironment) throws -> LayerEvalManifest {
        let paths = EvalPaths(env: env)
        let folder = paths.layerEval(prepared.evalID)
        let manifest = LayerEvalManifest(id: prepared.evalID, layer: prepared.layer, createdAt: now, brainCommit: prepared.brainCommit,
                                         setups: prepared.setups, sanity: prepared.sanitySetup, tasks: prepared.runnable.map(\.id),
                                         sanityTasks: prepared.sanityTasks.map(\.id), repeats: repeats, blocked: prepared.blocked,
                                         notes: prepared.notes, overlap: prepared.overlap)
        if prepared.continuing, let existing = self.manifest(prepared.evalID, env: env) { return existing }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else {
            throw LayerSetups.Failure(message: "The eval \(prepared.evalID) already exists.")
        }
        let temporary = paths.layerEvals.appending(path: ".\(AnalysisPaths.fileName(prepared.evalID))-\(UUID().uuidString.prefix(8))",
                                                   directoryHint: .isDirectory)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        do {
            for (hash, overlay) in prepared.overlays {
                try overlay.save(to: temporary.appending(path: "overlays").appending(path: hash, directoryHint: .isDirectory))
            }
            try AnalysisJSON.encoder.encode(manifest).write(to: temporary.appending(path: "manifest.json"), options: .atomic)
            try fm.moveItem(at: temporary, to: folder)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
        return manifest
    }

    /// The eval's manifest; nil when it is missing or was written by a newer AKit.
    public static func manifest(_ id: String, env: HarnessEnvironment) -> LayerEvalManifest? {
        read(EvalPaths(env: env).layerEval(id).appending(path: "manifest.json"))
    }

    /// Why an eval can't be read, for a message: missing, or written by a newer AKit.
    public static func problem(_ id: String, env: HarnessEnvironment) -> String? {
        let url = EvalPaths(env: env).layerEval(id).appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: url) else { return "No eval \(id)." }
        struct Header: Decodable { let schema: Int? }
        if let header = try? JSONDecoder().decode(Header.self, from: data), (header.schema ?? 1) > LayerEvalManifest.schemaVersion {
            return "The eval \(id) was written by a newer AKit; install the app and akit together."
        }
        return read(url) == nil ? "The eval \(id) can't be read." : nil
    }

    /// The evals of a layer, newest first.
    public static func evals(of layer: String, env: HarnessEnvironment) -> [LayerEvalManifest] {
        FileWalk.children(of: EvalPaths(env: env).layerEvals)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { read($0.appending(path: "manifest.json")) }
            .filter { $0.layer == layer }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The newest eval of a layer with this agent.
    public static func latest(of layer: String, agent: LabAgent, env: HarnessEnvironment) -> LayerEvalManifest? {
        evals(of: layer, env: env).first { $0.agent == agent }
    }

    /// The stored overlay of an eval, its bytes checked against their hashes and the overlay
    /// against its own hash.
    public static func overlay(hash: String, eval: String, env: HarnessEnvironment) throws -> ControlOverlay {
        let folder = EvalPaths(env: env).layerEval(eval).appending(path: "overlays").appending(path: AnalysisPaths.fileName(hash))
        let overlay = try ControlOverlay.load(from: folder)
        guard overlay.hash == hash else {
            throw LayerSetups.Failure(message: "The overlay \(hash.prefix(12)) of the eval \(eval) changed on disk; start a new eval.")
        }
        return overlay
    }

    private static func read(_ url: URL) -> LayerEvalManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        struct Header: Decodable { let schema: Int? }
        // A newer AKit's eval is skipped rather than misread.
        if let header = try? JSONDecoder().decode(Header.self, from: data), (header.schema ?? 1) > LayerEvalManifest.schemaVersion { return nil }
        return try? AnalysisJSON.decoder.decode(LayerEvalManifest.self, from: data)
    }
}
