import Foundation
import Testing
import AKitFoundation
@testable import AKitErrorAnalysis

struct AnalysisPathsTests {
    @Test func foldersLiveUnderLab() {
        let env = HarnessEnvironment(homeDirectory: URL(filePath: "/tmp/fake-home"), variables: [:], executableSearchPaths: [])
        let paths = AnalysisPaths(env: env)
        #expect(paths.folder.path == "/tmp/fake-home/.akit/lab/analysis")
        #expect(paths.modesFile.path == "/tmp/fake-home/.akit/lab/analysis/modes/modes.json")
        #expect(paths.notes(of: "claude:abc-123").lastPathComponent == "claude_abc-123.json")
    }

    @Test func fileNamesCantEscapeTheirFolder() {
        #expect(AnalysisPaths.fileName("../../etc/passwd") == "_._.._etc_passwd")
        #expect(AnalysisPaths.fileName("pi:2026/10/01") == "pi_2026_10_01")
    }
}
