import Foundation
import Testing
import AKitFoundation
@testable import AKitDoctor

/// `akit doctor`'s Flows lines: each project with flows keeps `/.pi/akit-flow` out of git.
struct DoctorFlowsTests {
    @Test func theExcludeOfRunRecordsIsChecked() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "akit-doctor-flows-\(UUID().uuidString)")
        let project = home.appending(path: "Projects/app")
        try fm.createDirectory(at: project.appending(path: ".pi/flows"), withIntermediateDirectories: true)
        let env = HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path])
        let git = ProcessRunner.runAndWait(URL(filePath: "/usr/bin/git"), arguments: ["-C", project.path, "init", "-q"],
                                           environment: env.variables, timeout: 30)
        #expect(git?.succeeded == true)
        var lines = await Doctor.flowLines(nil, projects: [project], env: env, tilde: { $0.lastPathComponent })
        #expect(lines.contains("  no Pi: flows run in Pi only"))
        #expect(lines.contains { $0.hasPrefix("! app: /.pi/akit-flow is not in .git/info/exclude") })
        let exclude = project.appending(path: ".git/info/exclude")
        try fm.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# >>> akit flows (run records of AKit flows; managed by AKit)\n/.pi/akit-flow\n# <<< akit flows\n".utf8).write(to: exclude)
        lines = await Doctor.flowLines(nil, projects: [project], env: env, tilde: { $0.lastPathComponent })
        #expect(lines.contains("  app: run records kept out of git"))
    }
}
