import Foundation

/// Where session insights live on this Mac. Nothing here is ever part of the brain.
struct InsightsPaths {
    let home: URL

    init(home: URL) { self.home = home }
    init(env: HarnessEnvironment) { home = env.homeDirectory }

    var folder: URL { home.appending(path: ".akit/index", directoryHint: .isDirectory) }
    var database: URL { folder.appending(path: "index.sqlite") }
    /// Daily files hooks append to (step 2).
    var spool: URL { folder.appending(path: "spool", directoryHint: .isDirectory) }
    /// Held by an importer while it runs; hooks never touch it.
    var lock: URL { folder.appending(path: "import.lock") }
    var log: URL { folder.appending(path: "import.log") }
    /// Settings, e.g. `{"keepManualCallExamples": true}`.
    var settings: URL { home.appending(path: ".akit/insights.json") }
}
