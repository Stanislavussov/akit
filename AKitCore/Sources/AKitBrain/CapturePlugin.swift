import Foundation

/// The Claude Code plugin that records session starts for `akit stats`. It lives in the brain
/// (`plugins/`, a local marketplace), so a new brain gets it and `CaptureInstaller` installs it.
public enum CapturePlugin {
    /// Version of the plugin files this akit writes; `insights status` compares it with the
    /// brain's and the installed one.
    public static let version = "1.0.1"
    public static let marketplace = "akit-brain"
    /// First line of every file AKit owns here; a file without it is someone else's.
    public static let marker = "akit-record: written by AKit"

    /// The plugin, by path inside the brain; `true` = executable.
    public static let files: [(path: String, text: String, executable: Bool)] = [
        ("plugins/.claude-plugin/marketplace.json", """
            {
              "name": "\(marketplace)",
              "owner": { "name": "AKit" },
              "description": "AKit's own Claude Code plugins, from the brain repo.",
              "plugins": [
                {
                  "name": "akit",
                  "source": "./akit",
                  "description": "Records session starts for akit stats in a local spool on this Mac.",
                  "version": "\(version)"
                }
              ]
            }

            """, false),
        ("plugins/akit/.claude-plugin/plugin.json", """
            {
              "name": "akit",
              "version": "\(version)",
              "description": "Records session starts for akit stats in a local spool on this Mac. Prints nothing.",
              "author": { "name": "AKit" }
            }

            """, false),
        ("plugins/akit/hooks/hooks.json", """
            {
              "description": "akit: one spool line per session start (akit record-session); no output",
              "hooks": {
                "SessionStart": [
                  {
                    "hooks": [
                      { "type": "command", "command": "\\"${CLAUDE_PLUGIN_ROOT}/hooks/record-session.sh\\"", "timeout": 10 }
                    ]
                  }
                ]
              }
            }

            """, false),
        ("plugins/akit/hooks/record-session.sh", """
            #!/bin/sh
            # \(marker) (akit insights install). Claude Code SessionStart hook: hands the
            # hook input to `akit record-session`, which appends one line to ~/.akit/index/spool.
            # Prints nothing (hook output would reach the agent) and never fails the session.
            if command -v akit >/dev/null 2>&1; then
              AKIT=akit
            elif [ -x "$HOME/.local/bin/akit" ]; then
              AKIT="$HOME/.local/bin/akit"
            else
              exit 0
            fi
            "$AKIT" record-session --harness claude >/dev/null 2>&1
            exit 0

            """, true),
    ]
}
