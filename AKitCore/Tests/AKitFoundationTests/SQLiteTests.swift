import Foundation
import Testing
@testable import AKitFoundation

struct SQLiteTests {
    private func temp() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "akit-sqlite-\(UUID().uuidString)/db.sqlite")
    }

    @Test func fullTextSearchRanksWithBM25() throws {
        let db = try SQLiteDatabase(url: temp(), privateFolder: false)
        try db.execute("CREATE VIRTUAL TABLE notes USING fts5(title, body)")
        try db.run("INSERT INTO notes(title, body) VALUES(?, ?)", "Orders", "the orders api creates orders")
        try db.run("INSERT INTO notes(title, body) VALUES(?, ?)", "Billing", "invoices and payments")
        let rows = try db.rows("SELECT title, bm25(notes) FROM notes WHERE notes MATCH ? ORDER BY bm25(notes)", "orders")
        #expect(rows.count == 1)
        #expect(rows[0][0].text == "Orders")
        #expect(rows[0][1].double != nil)
    }

    @Test func blobRoundTrip() throws {
        let db = try SQLiteDatabase(url: temp())
        try db.execute("CREATE TABLE v(id INTEGER PRIMARY KEY, data BLOB)")
        let bytes = Data([0, 1, 2, 255, 0, 7])
        try db.run("INSERT INTO v(data) VALUES(?)", bytes)
        try db.run("INSERT INTO v(data) VALUES(?)", Data())
        #expect(try db.value("SELECT data FROM v WHERE id = 1")?.blob == bytes)
        #expect(try db.value("SELECT data FROM v WHERE id = 2")?.blob == Data())
    }

    @Test func walModeIsOn() throws {
        let db = try SQLiteDatabase(url: temp())
        #expect(try db.value("PRAGMA journal_mode")?.text == "wal")
    }

    @Test func twoConnectionsRunSideBySide() throws {
        let url = temp()
        let first = try SQLiteDatabase(url: url)
        let second = try SQLiteDatabase(url: url)
        try first.execute("CREATE TABLE t(n INTEGER)")
        try first.transaction { try first.run("INSERT INTO t(n) VALUES(?)", 1) }
        #expect(try second.value("SELECT count(*) FROM t")?.int == 1)
        try second.run("INSERT INTO t(n) VALUES(?)", 2)
        #expect(try first.value("SELECT count(*) FROM t")?.int == 2)
    }

    @Test func folderIsPrivateOnlyWhenAsked() throws {
        let privateURL = temp()
        _ = try SQLiteDatabase(url: privateURL)
        let mode = try FileManager.default.attributesOfItem(atPath: privateURL.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }
}
