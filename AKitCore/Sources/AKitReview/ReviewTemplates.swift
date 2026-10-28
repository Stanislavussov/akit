import Foundation

/// The starting text of a new role, scenario or project profile: New Role…, New Scenario…,
/// New Profile… in the app and `akit review role|scenario|profile new` in the terminal.
public enum ReviewTemplates {
    public static func role(_ id: String) -> String {
        """
        ---
        name: review-\(id)
        description: "Review a change for …"
        akit-review:
          min_severity: medium
          max_findings: 3
          needs: [diff, full_files]
          do_not_comment:
            - style and naming
        ---

        What to check, as a list the model can follow:

        - …

        """
    }

    public static func scenario(_ id: String) -> String {
        """
        id: \(id)
        title: \(id.capitalized)
        roles: { required: [bug-hunter], optional: [] }
        checks:
          - "…"
        context_required: [full_files]

        """
    }

    public static let profile = """
    # AKit review project profile. The file name (a-z, 0-9, -) is the profile's id.
    project: my-service
    gitlab: { host: https://gitlab.example.com, project_path: group/my-service }
    checkout: ~/work/my-service            # your clone: the worktree at the reviewed commit comes from it
    # tracker: { kind: azure-devops, org: my-org, project: MyProject, wi_ref_regex: "(?i)(?:COL-|AB#|WI-)(\\\\d+)" }
    # mcp:                                 # Pi's MCP servers review may use (pi mcp list); none = those named gitlab, azure, devops, ado
    #   servers: [gitlab, azure-devops]
    #   read: []                           # more reading tools, e.g. ["wit_get_*"]; get_/list_/search_… read anyway
    #   write: ["*draft_note*"]            # the tools Send Drafts may call; only approved text passes
    #   in_passes: true                    # the brief, roles and verifier may read through MCP too
    #   all_servers: true                  # …through every server of your Pi (browser, file and fetch servers only when named)
    #   extra_servers: [figma]             # context servers on top (Figma, Confluence, a wiki): read only, in every run
    default_scenario: feature              # feature, bugfix, dependency-upgrade
    knowledge: []                          # markdown folders, e.g. [~/notes/my-service]
    # knowledge_base: work                 # a knowledge base (world or folder): Gather adds its card of the touched systems
    # knowledge_budget: 8000               # the card's size in tokens
    gather: []                             # e.g. - { name: tests, run: "npm test", timeout_s: 600 }; runs the MR's own code
    constraints: []                        # e.g. - "Public DTOs change only in backward-compatible ways"
    path_instructions: []                  # e.g. - { paths: ["**/*.generated.ts"], ignore: true }
    roles: { off: [], add: [] }            # project roles live in projects/<id>/skills/review-<role>/SKILL.md
    review: {}                             # e.g. { max_inline: 5, max_inline_medium: 3, models: { verifier: provider/model } }
    # pi:                                  # your Pi set-up in every run of this project (akit review pi lists it)
    #   flags: ["--exclude-tools", "find"]
    #   steps: ["/run reviewer", { run: "/skill:security-audit", max_findings: 3 }]

    """
}
