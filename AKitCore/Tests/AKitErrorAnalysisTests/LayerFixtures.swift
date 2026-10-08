import Foundation
import AKitFoundation

/// A temporary brain and task repository for layer evals: layers `base` and
/// `swiftui requires base`, the skill `swiftui-expert`, a repository whose value.txt holds 1.
struct LayerFixture {
    let home: URL
    let fm = FileManager.default

    var brain: URL { home.appending(path: "brain", directoryHint: .isDirectory) }
    var repo: URL { home.appending(path: "repo", directoryHint: .isDirectory) }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com",
        ], executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func write(_ path: String, _ text: String, in folder: URL, executable: Bool = false) throws {
        let url = folder.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    @discardableResult
    func git(_ args: String..., in folder: URL) async -> String? {
        let result = await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", folder.path] + args,
                                             environment: env.gitVariables, timeout: 60)
        return result?.succeeded == true ? result?.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    func commitAll(_ folder: URL, _ message: String = "Change") async {
        await git("add", "-A", in: folder)
        await git("commit", "-q", "-m", message, in: folder)
    }

    /// `swiftuiYAML` replaces the swiftui layer's layer.yaml.
    func makeBrain(swiftuiYAML: String? = nil) async throws {
        try write("skills/swiftui-expert/SKILL.md", "---\nname: swiftui-expert\ndescription: SwiftUI\n---\nUse {{project_name}}.\n", in: brain)
        try write("skills/swiftui-expert/refs.json", "{\"a\": 1}\n", in: brain)
        try write("layers/core/layer.yaml", "files:\n  - template: core.md\n    to: AGENTS.md\n", in: brain)
        try write("layers/core/templates/core.md", "- CORE\n", in: brain)
        try write("layers/base/layer.yaml", "files:\n  - template: base.md\n    to: AGENTS.md\n", in: brain)
        try write("layers/base/templates/base.md", "- BASE-RULE\n", in: brain)
        try write("layers/swiftui/layer.yaml", swiftuiYAML ?? """
            requires: [base]
            fields:
              - id: ui_check
                prompt: Command that checks the screen
                default: make snapshot
            skills: [swiftui-expert]
            files:
              - template: swiftui.md
                to: AGENTS.md

            """, in: brain)
        try write("layers/swiftui/templates/swiftui.md", "- LAYER-MARKER: check with {{ui_check}}\n", in: brain)
        try write("layers/solo/layer.yaml", "files:\n  - template: solo.md\n    to: AGENTS.md\n", in: brain)
        try write("layers/solo/templates/solo.md", "- SOLO\n", in: brain)
        await git("init", "-q", "-b", "main", in: brain)
        await commitAll(brain, "Brain")
    }

    /// value.txt holds 1; CLAUDE.md is the project's own. Returns the base commit.
    func makeRepo(_ extra: [String: String] = [:]) async throws -> String {
        try write("value.txt", "1\n", in: repo)
        try write("CLAUDE.md", "# Rules\n", in: repo)
        try write("Tests/ValueTests.swift", "@Test func one() {}\n", in: repo)
        for (path, text) in extra { try write(path, text, in: repo) }
        await git("init", "-q", "-b", "master", in: repo)
        await commitAll(repo, "Start")
        return await git("rev-parse", "HEAD", in: repo) ?? ""
    }

    /// A fake `claude`: it writes value 2 only when the clone's CLAUDE.md has the layer's
    /// marker, reports a Claude Code version, records `git status` as the agent saw it, and
    /// leaves a marker file that proves the fake ran (not a real, paid Claude Code). As the
    /// real one does, its stream's init names every skill of the clone's `.claude/skills` and
    /// its transcript's `skill_listing` those that aren't manual; both add the names in
    /// `~/also-listed.txt` (a skill from somewhere the setup check doesn't read).
    func fakeClaude() throws {
        try write("bin/claude", #"""
            #!/bin/sh
            if [ "$1 $2" = "auth status" ]; then
              echo '{"loggedIn":true,"apiProvider":"firstParty","email":"me@example.com","orgName":"Me"}'; exit 0
            fi
            id=""; prev=""
            for a in "$@"; do [ "$prev" = "--session-id" ] && id="$a"; prev="$a"; done
            touch "$HOME/fake-claude-ran"
            printf '%s\n' "$@" > "$HOME/args-$id.txt"
            git status --porcelain > "$HOME/status-$id.txt"
            mkdir -p "$HOME/.claude/projects/-fake"
            t="$HOME/.claude/projects/-fake/$id.jsonl"
            echo '{"type":"user","cwd":"/fake","timestamp":"2026-10-01T10:00:00Z","message":{"role":"user","content":"Make value 2"}}' > "$t"
            names=""; loaded=""
            for d in .claude/skills/*/; do
              [ -d "$d" ] || continue
              n="$(basename "$d")"; loaded="$loaded\"$n\","
              grep -q "disable-model-invocation: true" "$d/SKILL.md" 2>/dev/null || names="$names\"$n\","
            done
            if [ -f "$HOME/also-listed.txt" ]; then
              for n in $(cat "$HOME/also-listed.txt"); do names="$names\"$n\","; loaded="$loaded\"$n\","; done
            fi
            echo '{"type":"attachment","attachment":{"type":"skill_listing","isInitial":true,"names":['"${names%,}"'],"content":""}}' >> "$t"
            if grep -q LAYER-MARKER CLAUDE.md; then echo 2 > value.txt; fi
            echo '{"type":"assistant","timestamp":"2026-10-01T10:00:09Z","message":{"id":"m9","model":"claude-opus-5-5","content":[{"type":"text","text":"Finished."}],"usage":{"input_tokens":10,"output_tokens":5}}}' >> "$t"
            echo '{"type":"system","subtype":"init","model":"claude-opus-5-5","claude_code_version":"2.1.290","session_id":"'"$id"'","skills":['"${loaded%,}"']}'
            echo '{"type":"result","num_turns":2,"duration_ms":1000,"usage":{"input_tokens":20,"output_tokens":10},"total_cost_usd":0.01}'
            """#, in: home, executable: true)
    }
}
