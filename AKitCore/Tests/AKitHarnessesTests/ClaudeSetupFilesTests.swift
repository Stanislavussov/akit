import Foundation
import Testing
@testable import AKitHarnesses

/// Where a part of the setup is defined, in a temporary fake home and project.
struct ClaudeSetupFilesTests {
    let home: URL
    let project: URL
    let fm = FileManager.default

    init() throws {
        let base = fm.temporaryDirectory.appending(path: "akit-setup-files-\(UUID().uuidString)")
        home = base.appending(path: "home")
        project = base.appending(path: "work")
        let plugin = home.appending(path: ".claude/plugins/cache/omc/omc/1.0.0").path
        try write(".claude/settings.json", in: home,
                  #"{"enabledPlugins": {"omc@omc": true}, "hooks": {"Stop": []}}"#)
        try write(".claude/plugins/installed_plugins.json", in: home,
                  #"{"plugins": {"omc@omc": [{"scope": "user", "installPath": "\#(plugin)", "version": "1.0.0"}]}}"#)
        try write(".claude/plugins/cache/omc/omc/1.0.0/skills/ralph/SKILL.md", in: home, "---\nname: ralph\n---")
        try write(".claude/plugins/cache/omc/omc/1.0.0/agents/architect.md", in: home, "agent")
        try write(".claude/plugins/cache/omc/omc/1.0.0/hooks/hooks.json", in: home, #"{"hooks": {"SessionStart": []}}"#)
        try write(".claude/plugins/cache/omc/omc/1.0.0/.mcp.json", in: home, #"{"t": {}}"#)
        try write(".claude/skills/tdd/SKILL.md", in: project, "---\nname: tdd\n---")
        try write(".claude/settings.local.json", in: project, #"{"hooks": {"Stop": []}}"#)
        try write(".mcp.json", in: project, #"{"mcpServers": {"docs": {}}}"#)
        try write(".claude/plugins/synced/acct/marketing~g2/skills/seo-audit/SKILL.md", in: home, "skill")
        try write(".claude/skills/synced/acct/pdf/SKILL.md", in: home, "skill")
        try write(".claude/skills/pdf/SKILL.md", in: home, "own skill with the same base name")
    }

    func write(_ path: String, in folder: URL, _ text: String) throws {
        let url = folder.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func files(_ kind: ClaudeSetupFiles.Kind, _ name: String) -> [String] {
        ClaudeSetupFiles.files(kind, name: name, home: home, project: project).map {
            $0.path.replacingOccurrences(of: home.path, with: "~").replacingOccurrences(of: project.path, with: "<work>")
        }
    }

    @Test func eachPartLeadsToItsFile() {
        #expect(files(.skill, "omc:ralph") == ["~/.claude/plugins/cache/omc/omc/1.0.0/skills/ralph/SKILL.md"])
        #expect(files(.skill, "tdd") == ["<work>/.claude/skills/tdd/SKILL.md"])
        #expect(files(.skill, "marketing:seo-audit") == ["~/.claude/plugins/synced/acct/marketing~g2/skills/seo-audit/SKILL.md"])
        // claude.ai account skills; an own skill of the same base name is another skill.
        #expect(files(.skill, "anthropic-skills:pdf") == ["~/.claude/skills/synced/acct/pdf/SKILL.md"])
        #expect(files(.skill, "unknown-plugin:tdd").isEmpty)
        #expect(files(.subagent, "omc:architect") == ["~/.claude/plugins/cache/omc/omc/1.0.0/agents/architect.md"])
        #expect(files(.subagent, "Explore").isEmpty, "built in")
        #expect(files(.hook, "SessionStart:startup") == ["~/.claude/plugins/cache/omc/omc/1.0.0/hooks/hooks.json"])
        // settings.local.json may hold secrets: never offered.
        #expect(files(.hook, "Stop") == ["~/.claude/settings.json"])
        #expect(files(.mcpServer, "plugin_omc_t") == ["~/.claude/plugins/cache/omc/omc/1.0.0/.mcp.json"])
        #expect(files(.mcpServer, "docs") == ["<work>/.mcp.json"])
        #expect(files(.mcpServer, "claude-in-chrome").isEmpty)
        #expect(files(.settings, "") == ["~/.claude/settings.json"])
    }
}
