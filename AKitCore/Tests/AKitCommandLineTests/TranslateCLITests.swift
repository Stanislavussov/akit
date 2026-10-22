import Foundation
import Testing
import AKitFoundation
import AKitLab
@testable import AKitCommandLine

/// `akit translate` with a fake `claude` in a temporary home.
@Suite(.serialized)
struct TranslateCLITests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-translate-cli-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
        let claude = home.appending(path: "bin/claude")
        try Data("""
            #!/bin/sh
            if [ "$1 $2" = "auth status" ]; then
              echo '{"loggedIn":true,"apiProvider":"firstParty","email":"me@example.com","orgName":"Me"}'; exit 0
            fi
            cat > "$HOME/stdin.txt"
            echo "$@" > "$HOME/args.txt"
            echo '{"type":"result","is_error":false,"result":"","structured_output":{"parts":["Привет, `run()`"]},"usage":{"input_tokens":3,"output_tokens":2},"total_cost_usd":0.001}'

            """.utf8).write(to: claude)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func akit(_ arguments: String..., stdin: String = "") async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: home, out: { out.append($0) }, err: { err.append($0) },
                                     input: { Data(stdin.utf8) })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    @Test func translatesStdinWithTheTranslationModel() async throws {
        let result = await akit("translate", "--to", "ru", "-", stdin: "Hello, `run()`")
        #expect(result.code == 0, "\(result.err)")
        #expect(result.out == "Привет, `run()`")
        #expect(try String(contentsOf: home.appending(path: "stdin.txt"), encoding: .utf8).contains("Hello, `run()`"))
        #expect(try String(contentsOf: home.appending(path: "args.txt"), encoding: .utf8).contains("--model haiku"))
        #expect(SendLog.records(env: env).map(\.purpose) == ["translate"])
    }

    @Test func refusesWhatThePolicyRefuses() async {
        // A merge request goes to Pi, or to an allowed Claude Code account: none is on the list.
        let result = await akit("translate", "--to", "de", "-", "--origin", "merge-request", stdin: "Text")
        #expect(result.code != 0)
        #expect(result.err.contains("Not sent"))
        #expect(!fm.fileExists(atPath: home.appending(path: "stdin.txt").path))
    }

    @Test func checksItsArguments() async {
        #expect(await akit("translate", "-").err.contains("--to LANG"))
        #expect(await akit("translate", "--to", "xx", "-").err.contains("en, ru, cs"))
        #expect(await akit("translate", "--to", "ru").err.contains("Translate one thing"))
        #expect(await akit("translate", "--to", "ru", "--lab-run", "nope").err.contains("no Lab run"))
        #expect(await akit("translate", "--help").out.contains("akit translate model"))
    }

    @Test func setsAndShowsTheTranslationModel() async throws {
        #expect(await akit("translate", "model").out == "Claude Code · haiku · low")
        let set = await akit("translate", "model", "pi", "zai/glm-5-air", "minimal")
        #expect(set.code == 0, "\(set.err)")
        #expect(LabSettings.load(env: env).translationAgent == LabAgent(harness: .pi, model: "zai/glm-5-air", effort: "minimal", mode: .call))
        #expect(await akit("translate", "model").out == "Pi · zai/glm-5-air · minimal")
        // Back to the default: nothing stored.
        #expect(await akit("translate", "model", "claude-code").code == 0)
        #expect(LabSettings.load(env: env).translationAgent == nil)
        #expect(await akit("translate", "model", "pi", "m", "huge").code != 0)
    }
}
