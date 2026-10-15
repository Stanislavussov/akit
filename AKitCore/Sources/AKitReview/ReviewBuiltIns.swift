import Foundation

/// The first roles, scenarios and defaults (`docs/design/review.md`, step 5). They are what a
/// new brain layer `review` starts from, and what a review uses while the brain has none.
public enum ReviewBuiltIns {
    public static let defaultsYAML = """
    # AKit review defaults. A project profile's `review:` block and a single run override them.
    models:
      passes: ""        # provider/model for the brief and the roles; empty = Pi's default model
      verifier: ""      # a strong model for the verifier; empty = the passes' model
    thinking:
      passes: ""
      verifier: high
    posting:
      marker: "🤖 AKit review"
      severity_threshold: medium
      confidence_threshold: 0.8
      max_inline: 7
      nitpicks: false
    cost:
      cap_credits_per_run: 150
    """

    public static let scenarioFiles: [String: String] = [
        "feature": """
        id: feature
        title: Feature
        roles: { required: [domain, requirements], optional: [tests] }
        checks:
          - "Do the changes keep the invariants and business rules of the touched components?"
          - "Is each acceptance criterion covered by code and by a test?"
        context_required: [wi, full_files]
        detect:            # read by the classifier later; ignored now
          wi_type: [User Story, Feature, Product Backlog Item]
          branch_regex: "^(feature|feat)/"
        """,
        "bugfix": """
        id: bugfix
        title: Bugfix
        roles: { required: [bug-hunter, requirements, tests], optional: [security] }
        checks:
          - "Is the cause fixed, not the symptom (from the repro steps)?"
          - "Does a regression test reproduce the bug?"
          - "Do nearby code paths have the same defect?"
        context_required: [wi, full_files]
        detect:
          wi_type: [Bug]
          branch_regex: "^(fix|bug|hotfix)/"
        """,
        "dependency-upgrade": """
        id: dependency-upgrade
        title: Dependency upgrade
        roles: { required: [upgrade-risk, tests], optional: [security] }
        checks:
          - "Which breaking changes does the new version list, and does the code handle them?"
          - "Which transitive dependencies change with it?"
          - "Does the code use APIs the new version deprecates or removes?"
          - "Does the license change?"
        context_required: [full_files]
        detect:
          branch_regex: "^(deps|renovate|dependabot)/"
        """,
    ]

    public static let roleFiles: [String: String] = [
        "domain": role("domain", "Review a change against the domain: invariants, business rules, state transitions and boundaries of the touched components.",
                       max: 3, needs: ["diff", "full_files", "wi"],
                       doNotComment: ["style and naming", "rules the context pack doesn't state or show in code"], body: """
                       Check the change as someone who owns the business rules of these components.

                       - Which invariants does each touched aggregate, entity or service keep? Can the new code break one (an order with no lines, a negative balance, a state reached from the wrong state)?
                       - Do state changes follow the allowed transitions? Look for a new path that skips a check.
                       - Does the change move a rule into the wrong layer (domain logic in a controller, infrastructure in the domain)?
                       - Do the names in code still match the words of the work item and the knowledge notes?
                       - Does a change to a public contract (DTO, event, API) stay backward-compatible when the project's constraints ask for it?

                       Name the rule you rely on and where it is written (a knowledge note, the work item, the code). If you can't find the rule, report a context gap instead of guessing.
                       """),
        "requirements": role("requirements", "Check the change against the work item's acceptance criteria and fill the summary's coverage matrix.",
                             max: 3, needs: ["diff", "wi"], doNotComment: ["code style", "anything not tied to a criterion or a repro step"], body: """
                             You don't write inline comments. You fill the acceptance-criteria matrix of the summary.

                             For each acceptance criterion (and each repro step of a bug) say one of:
                             - `code`: the change implements it; name the file and line.
                             - `test`: a test checks it; name the test.
                             - `not found`: nothing in the change does it.
                             - `can't check`: you need something the context pack doesn't have; say what.

                             Submit the matrix as findings with `kind: "ac"`, one per criterion, `title` = the criterion, `why` = the status and the place. A criterion that is `not found` is also a finding with severity medium or higher, if the change claims to deliver it.
                             If the work item has no acceptance criteria, report a context gap.
                             """),
        "tests": role("tests", "Review whether the change is tested: missing tests for new behaviour, regression tests for bugs, weak assertions.",
                      max: 3, needs: ["diff", "full_files", "tests"],
                      doNotComment: ["test style or naming", "coverage numbers without a concrete untested path"], body: """
                      - Which new or changed behaviour has no test? Name the branch or case, not "add more tests".
                      - For a bug: does a test fail without the fix? A test that passes either way is a finding.
                      - Do assertions check the result, or only that no exception was thrown?
                      - Are there tests that the change makes wrong but leaves passing (mocks that hide the change)?
                      - If the gather step ran the tests, read their output: a failing or skipped test is a finding with high severity.
                      """),
        "bug-hunter": role("bug-hunter", "Hunt for defects the change introduces or leaves: wrong logic, edge cases, null and error paths, concurrency, resource leaks.",
                           max: 3, needs: ["diff", "full_files", "history"],
                           doNotComment: ["style and naming", "hypothetical problems without a concrete input that triggers them"], body: """
                           Look for real defects. For each one give the input or state that triggers it and what happens then.

                           - Off-by-one, wrong comparison, inverted condition, wrong operator precedence.
                           - Null or empty values, missing keys, empty collections, time zones, rounding.
                           - Errors that are swallowed, retried forever, or leave state half-changed.
                           - Concurrency: shared state without a lock, check-then-act, async calls not awaited.
                           - Resources not closed; queries in loops; unbounded growth.
                           - For a bugfix: is the cause fixed, or only the symptom? Do nearby paths have the same defect?

                           Quote the exact line as evidence. If you are not sure the input can occur, say so and lower the confidence.
                           """),
        "upgrade-risk": role("upgrade-risk", "Review a dependency upgrade: breaking changes, deprecated APIs, transitive upgrades, license changes.",
                             max: 3, needs: ["diff", "full_files"],
                             doNotComment: ["version pinning style", "risks the changelog doesn't name and the code doesn't show"], body: """
                             - Which packages change, from which version to which? Major versions first.
                             - Use the changelog or migration guide if the context pack has it. If it doesn't, report a context gap naming the package and versions.
                             - Search the code for APIs the new version removes, renames or changes in behaviour.
                             - Lock file: which transitive dependencies change with it?
                             - Does a license change (for example to a copyleft license)?
                             - Does config (build flags, runtime settings) need a change the MR doesn't make?
                             """),
        "security": role("security", "Review a change for authN/authZ, input validation, injection, secrets, SSRF, PII in logs.",
                         max: 3, needs: ["diff", "full_files"],
                         doNotComment: ["style and naming", "attacks without a path from an input to a sink"], body: """
                         Follow untrusted input to where it is used. A finding needs the whole path: where the input comes from, what it reaches, and why nothing in between stops it.

                         - Authentication and authorization: a new endpoint or handler without the check its neighbours have; checks on the wrong object (IDOR).
                         - Injection: SQL, shell, LDAP, template, path traversal, deserialization of untrusted data.
                         - SSRF: outgoing requests to an address from input.
                         - Secrets: keys or tokens in code, config or logs. Never quote a secret's value; name the file and line.
                         - Personal data in logs, errors or analytics.
                         - Crypto: home-made crypto, weak algorithms, missing certificate checks.
                         """),
    ]

    /// Ids in the order a new layer lists them.
    public static let roleIDs = ["domain", "requirements", "tests", "bug-hunter", "upgrade-risk", "security"]
    public static let scenarioIDs = ["feature", "bugfix", "dependency-upgrade"]

    public static var roles: [ReviewRole] {
        roleIDs.compactMap { id in roleFiles[id].flatMap { try? ReviewRole.parse($0, source: .builtIn) } }
    }

    public static var scenarios: [ReviewScenario] {
        scenarioIDs.compactMap { id in scenarioFiles[id].flatMap { try? ReviewScenario.parse($0, source: .builtIn) } }
    }

    static func role(_ id: String, _ description: String, max: Int, needs: [String], doNotComment: [String], body: String) -> String {
        """
        ---
        name: review-\(id)
        description: "\(description.replacingOccurrences(of: "\"", with: "\\\""))"
        akit-review:
          min_severity: medium
          max_findings: \(max)
          needs: [\(needs.joined(separator: ", "))]
          do_not_comment:
        \(doNotComment.map { "    - \($0)" }.joined(separator: "\n"))
        ---

        \(body)

        """
    }
}
