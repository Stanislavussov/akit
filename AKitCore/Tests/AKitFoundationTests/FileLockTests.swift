import Foundation
import Testing
@testable import AKitFoundation

struct FileLockTests {
    private func lockFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "akit-lock-\(UUID().uuidString)/x.lock")
    }

    @Test func secondAcquireReturnsNilWhileHeld() throws {
        let url = lockFile()
        var first = try FileLock.acquire(url)
        #expect(first != nil)
        #expect(try FileLock.acquire(url) == nil)
        first = nil
        #expect(try FileLock.acquire(url) != nil)
    }

    @Test func timeoutReturnsNilAfterAbout200Milliseconds() throws {
        let url = lockFile()
        let held = try #require(try FileLock.acquire(url))
        let started = Date.now
        #expect(try FileLock.acquire(url, timeout: 0.2) == nil)
        let waited = Date.now.timeIntervalSince(started)
        #expect(waited >= 0.2 && waited < 1.5)
        held.release()
        #expect(try FileLock.acquire(url, timeout: 0.2) != nil)
    }
}
