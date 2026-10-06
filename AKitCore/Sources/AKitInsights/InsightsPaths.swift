import AKitFoundation
import Foundation

/// Where session insights live on this Mac. Nothing here is ever part of the brain.
public struct InsightsPaths {
    let home: URL

    init(home: URL) { self.home = home }
    public init(env: HarnessEnvironment) { home = env.homeDirectory }

    var folder: URL { home.appending(path: ".akit/index", directoryHint: .isDirectory) }
    public var database: URL { folder.appending(path: "index.sqlite") }
    /// Daily files hooks append to.
    public var spool: URL { folder.appending(path: "spool", directoryHint: .isDirectory) }
    /// Held by an importer while it runs; hooks never touch it.
    public var lock: URL { folder.appending(path: "import.lock") }
    var log: URL { folder.appending(path: "import.log") }
    /// Settings, e.g. `{"keepManualCallExamples": true}`.
    public var settings: URL { home.appending(path: ".akit/insights.json") }

    /// The settings file's top-level object; empty when it is missing or isn't a JSON object.
    func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settings),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// Changes keys of the settings file, keeping the others; creates it when missing. A file
    /// that isn't a JSON object is left alone (thrown), never overwritten.
    func updateSettings(_ change: (inout [String: Any]) -> Void) throws {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: settings) {
            guard let read = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: settings.path])
            }
            object = read
        }
        change(&object)
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: settings, options: .atomic)
    }
}
