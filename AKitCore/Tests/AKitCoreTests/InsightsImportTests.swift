import Foundation
import Testing
@testable import AKitCore

/// The session index: schema, import rules, facts. Temporary fake home and index; never
/// reads the real ~/.claude or ~/.pi.
struct InsightsImportTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-insights-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }
    var paths: InsightsPaths { InsightsPaths(home: home) }

    // MARK: Schema

    @Test func migrationsAreOrderedAndIdempotent() throws {
        let database = try IndexSchema.open(paths.database)
        #expect(try database.userVersion == IndexSchema.migrations.count)
        #expect(try database.value("SELECT value FROM meta WHERE key = 'keyVersion'")?.text == "\(IndexSchema.keyVersion)")

        // Opening again runs nothing twice (a second run of v1 would fail on CREATE TABLE).
        try database.run("INSERT INTO sources(path, generation, harness, kind, parser_version, state) VALUES('x', 1, 'claude', 'session', 1, 'active')")
        let again = try IndexSchema.open(paths.database)
        #expect(try again.userVersion == IndexSchema.migrations.count)
        #expect(try again.value("SELECT COUNT(*) FROM sources")?.int == 1)
        #expect(try again.value("SELECT COUNT(*) FROM meta")?.int == 1)

        // No fact table can cascade from sources, and each has its source index.
        for table in IndexSchema.factTables {
            #expect(try again.rows("SELECT * FROM pragma_foreign_key_list('\(table)')").isEmpty, "\(table)")
            #expect(try again.value("SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?", "\(table)_source")?.text
                    == "\(table)_source")
        }

        // An index from a newer akit is refused, not downgraded.
        try again.execute("PRAGMA user_version = \(IndexSchema.migrations.count + 1)")
        #expect(throws: IndexDatabase.Failure.self) { _ = try IndexSchema.open(paths.database) }
    }
}
