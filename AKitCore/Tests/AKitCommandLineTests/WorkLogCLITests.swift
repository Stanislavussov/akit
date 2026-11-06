import Foundation
import Testing
import AKitFoundation
import AKitKnowledge
@testable import AKitCommandLine

/// `akit worklog` in a temporary fake home; git reads no config of the real user.
struct WorkLogCLITests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-cli-worklog-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                           executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: home, projectsRoot: home.appending(path: "Projects"),
                                     hostName: "TestMac.local", out: { out.append($0) }, err: { err.append($0) })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    @Test func addStampsTodayAndShowSumsTheKinds() async throws {
        defer { try? fm.removeItem(at: home) }
        #expect(await akit("worklog", "show").out.contains("No knowledge base"))
        #expect(await akit("kb", "init", "--world", "work").code == 0)
        let added = await akit("worklog", "add", "#agent review with Pi", "--at", "00:00", "--json")
        #expect(added.code == 0, "\(added.err)")
        #expect(added.out.contains(#""kind" : "agent""#) && added.out.contains(#""time" : "00:00""#))
        let today = KnowledgeWorkLog.stamp(.now).day
        #expect(added.out.contains("worklog/\(today).md"))
        #expect(await akit("worklog", "add", "lunch", "--kind", "break").code == 0)
        let shown = await akit("worklog", "show", "--json")
        #expect(shown.out.contains(#""agent" :"#) && shown.out.contains(#""work_minutes""#))
        #expect(await akit("worklog", "show", "today").out.contains("#break  lunch"))
        #expect(await akit("worklog", "add", "x", "--at", "25:00").code != 0)
        #expect(await akit("worklog", "kinds").out.contains("#break  Break  (not work)"))
        #expect(await akit("worklog", "fill", "--thinking", "lots").err.contains("--thinking takes one of off, minimal, low"))
        #expect(await akit("worklog", "--help").out.contains("akit worklog add TEXT"))
    }

    @Test func blocksHoursAndTheReport() async throws {
        defer { try? fm.removeItem(at: home) }
        #expect(await akit("kb", "init", "--world", "work").code == 0)
        let block = await akit("worklog", "add", "Standup", "--kind", "meeting", "--at", "09:00", "--to", "09:30", "--day", "2026-11-02", "--json")
        #expect(block.code == 0, "\(block.err)")
        #expect(block.out.contains(#""end" : "09:30""#))
        #expect(await akit("worklog", "add", "x", "--to", "10:00").code != 0)
        #expect(await akit("worklog", "add", "COL-5 fix", "--kind", "bug", "--at", "10:00", "--to", "12:00", "--day", "2026-11-02").code == 0)
        #expect(await akit("worklog", "hours", "8").out.contains("8 h, Monday to Friday, committed"))
        #expect(await akit("worklog", "hours", "--day", "2026-11-03", "0").out.contains("2026-11-03: 0.00 h"))
        let report = await akit("worklog", "report", "2026-11-02..2026-11-03", "--json")
        #expect(report.code == 0, "\(report.err)")
        #expect(report.out.contains(#""work_minutes" : 150"#) && report.out.contains(#""norm_minutes" : 480"#))
        #expect(report.out.contains(#""COL-5" : 120"#))
        let csv = await akit("worklog", "report", "2026-11-02..2026-11-03", "--csv").out
        #expect(csv.contains("2026-11-02,Mon,8.00,2.50,5.50,0.00"))
        #expect(csv.contains("2026-11-03,Tue,0.00,0.00,0.00"))
        #expect(await akit("worklog", "report").out.contains("##"))
    }
}
