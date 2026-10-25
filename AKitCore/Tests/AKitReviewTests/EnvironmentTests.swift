@testable import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

/// A pass gets the login shell's environment: an app started from the Dock has none of the
/// variables `~/.zshrc` exports, and Pi's MCP servers need them.
struct PassEnvironmentTests {
    @Test func shellVariablesAndPathWin() {
        let home = URL(filePath: "/Users/t", directoryHint: .isDirectory)
        let env = HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path, "PATH": "/usr/bin", "LANG": "C",
                                                                       "CLAUDECODE": "1"],
                                     executableSearchPaths: [URL(filePath: "/opt/akit/bin", directoryHint: .isDirectory)])
        let shell = LoginShell.Variables(values: ["GITLAB_TOKEN": "x", "LANG": "en_US.UTF-8", "PATH": "/opt/homebrew/bin:/usr/bin",
                                                  "HOME": "/elsewhere", "CLAUDECODE": "1"], note: nil)
        let variables = ReviewPasses.shellEnvironment(shell, env: env)
        #expect(variables["GITLAB_TOKEN"] == "x")
        #expect(variables["LANG"] == "en_US.UTF-8")
        #expect(variables["HOME"] == home.path)
        #expect(variables["CLAUDECODE"] == nil)
        let path = (variables["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(path.first == "/opt/homebrew/bin")
        #expect(path.contains("/opt/akit/bin"))
    }
}
