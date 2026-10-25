import Foundation
import Testing
import AKitFoundation

/// A temporary fake home for one test; git in it reads no config of the real user.
enum FakeHome {
    /// A new, empty folder `<prefix>-<UUID>` in the temporary folder, by its real path.
    static func make(_ prefix: String) throws -> URL {
        let fm = FileManager.default
        let home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "\(prefix)-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// `HOME` is `home`; the global git config is /dev/null, the system one is off.
    static func env(_ home: URL, _ extra: [String: String] = [:]) -> HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home,
                           variables: ["HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"].merging(extra) { $1 },
                           executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    /// Runs git in `folder`, expects it to succeed and returns its trimmed output.
    static func git(_ args: [String], in folder: URL, env: HarnessEnvironment) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: folder,
                                                           environment: env.variables, timeout: 20))
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
