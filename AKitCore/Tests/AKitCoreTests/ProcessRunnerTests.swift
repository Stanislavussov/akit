import Foundation
import Testing
@testable import AKitCore

/// ProcessRunner with small shell scripts in a temporary folder.
struct ProcessRunnerTests {
    let folder: URL
    let fm = FileManager.default

    init() throws {
        folder = fm.temporaryDirectory.appending(path: "akit-process-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func script(_ body: String) throws -> URL {
        let url = folder.appending(path: "run.sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func run(_ body: String, timeout: TimeInterval = 5) async throws -> (ProcessRunner.Result, TimeInterval) {
        let start = Date()
        let result = try #require(await ProcessRunner.run(try script(body), arguments: ["a b"], directory: folder,
                                                          environment: ["GREETING": "hi", "PATH": "/usr/bin:/bin"],
                                                          timeout: timeout, killGrace: 0.5))
        return (result, Date().timeIntervalSince(start))
    }

    @Test func collectsOutputArgumentsEnvironmentAndFolder() async throws {
        let (result, _) = try await run("echo \"$GREETING $1\"; pwd -P; echo oops >&2; exit 3")
        #expect(result.exitedNormally)
        #expect(result.status == 3)
        #expect(!result.succeeded)
        let lines = result.output.split(separator: "\n").map(String.init)
        #expect(lines.first == "hi a b")
        #expect(lines.contains { $0.hasSuffix("/" + folder.lastPathComponent) })
        #expect(lines.contains("oops"))
    }

    @Test func childLeftBehindDoesNotBlock() async throws {
        let (result, elapsed) = try await run("(sleep 30) &\necho started")
        #expect(result.succeeded)
        #expect(result.output.contains("started"))
        #expect(elapsed < 5)
    }

    @Test func ignoredTerminationIsKilledAfterTimeout() async throws {
        let (result, elapsed) = try await run("trap '' TERM\nwhile true; do sleep 0.1; done", timeout: 0.5)
        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(elapsed < 4)
    }

    @Test func missingProgramIsNil() async {
        let result = await ProcessRunner.run(folder.appending(path: "nope"), arguments: [], environment: [:], timeout: 1)
        #expect(result == nil)
    }
}
