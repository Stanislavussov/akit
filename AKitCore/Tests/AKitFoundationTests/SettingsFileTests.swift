import Foundation
import Testing
@testable import AKitFoundation

/// The checked write in a temporary fake home: the harness's lock, backups and their pruning.
struct SettingsFileTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-settings-file-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var file: URL { home.appending(path: ".claude.json") }
    var lock: URL { home.appending(path: ".claude.json.lock") }

    func change(_ value: String) throws -> SettingsFile.Change {
        try SettingsFile.change(file, edits: [.set(["a"], .string(value))], home: home, lock: lock)
    }

    @Test func aStaleLockIsTakenOverAndTheLockIsGoneAfterwards() throws {
        try Data("{\"a\": \"x\"}\n".utf8).write(to: file)
        try fm.createDirectory(at: lock, withIntermediateDirectories: false)
        try fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-60)], ofItemAtPath: lock.path)
        try SettingsFile.apply(try change("y"), home: home)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\"a\": \"y\"}\n")
        #expect(!fm.fileExists(atPath: lock.path))
    }

    @Test(.timeLimit(.minutes(1))) func aHeldLockMakesAKitWaitThenGiveUp() throws {
        try fm.createDirectory(at: lock, withIntermediateDirectories: false)
        let start = Date.now
        #expect(throws: SettingsFile.Failure.self) { try SettingsFile.Lock.acquire(lock, file: file, home: home, wait: 0.3) }
        #expect(Date.now.timeIntervalSince(start) < 5)
        // Someone else's lock stays.
        #expect(fm.fileExists(atPath: lock.path))
    }

    @Test func backupsArePrivateAndPruned() throws {
        try Data("{\"a\": \"0\"}\n".utf8).write(to: file)
        for index in 1...(SettingsFile.keptBackups + 3) {
            try SettingsFile.apply(try change("\(index)"), home: home)
        }
        let root = home.appending(path: ".akit/backups")
        let backups = try fm.contentsOfDirectory(atPath: root.path).filter { fm.fileExists(atPath: root.appending(path: "\($0)/.claude.json").path) }
        #expect(backups.count == SettingsFile.keptBackups)
        let newest = try #require(backups.sorted().last)
        let mode = try fm.attributesOfItem(atPath: root.appending(path: "\(newest)/.claude.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try String(contentsOf: root.appending(path: "\(newest)/.claude.json"), encoding: .utf8) == "{\"a\": \"\(SettingsFile.keptBackups + 2)\"}\n")
    }

    @Test func aChangedTouchedValueIsRefused() throws {
        try Data("{\"a\": \"x\", \"b\": 1}\n".utf8).write(to: file)
        let planned = try change("y")
        // Another key changed: still applies on the fresh text.
        try Data("{\"a\": \"x\", \"b\": 2}\n".utf8).write(to: file)
        try SettingsFile.apply(planned, home: home)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\"a\": \"y\", \"b\": 2}\n")
        // The touched value changed: refused.
        let again = try change("z")
        try Data("{\"a\": \"w\", \"b\": 2}\n".utf8).write(to: file)
        #expect(throws: SettingsFile.Failure.self) { try SettingsFile.apply(again, home: home) }
    }

    @Test func checkComparesKeysByScalars() throws {
        // The same tree to Swift, two different files to a harness.
        #expect(throws: SettingsFile.Failure.self) {
            try SettingsFile.checked("{\"cafe\u{301}\": 1}", expected: .object(["caf\u{e9}": .number("1")]), file: file, home: home)
        }
    }
}
