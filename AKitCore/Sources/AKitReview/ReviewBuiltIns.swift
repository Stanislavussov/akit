import Foundation

/// The first roles, scenarios and defaults (`docs/design/review.md`, step 5). They are what a
/// new brain layer `review` starts from, and what a review uses while the brain has none.
public enum ReviewBuiltIns {
    public static let defaultsYAML = """
    # AKit review defaults. A project profile's `review:` block and a single run override them.
    models:
      passes: ""        # provider/model for the brief and the roles; empty = Pi's default model
      verifier: ""      # required: a strong model for the verifier, best of another family than the passes'.
    thinking:
      passes: ""
      verifier: high
    posting:
      marker: "🤖"
      language: cs      # the comments' language; Send lets only Czech (cs) go to GitLab
      severity_threshold: medium
      confidence_threshold: 0.8
      max_inline: 5
      max_inline_medium: 3
    cost:
      cap_credits_per_run: 150
      max_changed_lines: 1500
    """

    public static let scenarioFiles: [String: String] = [
        "feature": """
        id: feature
        title: Feature
        roles:
          required: [contracts, domain, bug-hunter, requirements]
          optional: [architecture, tests, security, performance, concurrency, data-migrations, observability, history]
        checks:
          - "Which contracts does the change add or change, and does every consumer still work?"
          - "Does the new code sit in the right component and keep its boundaries?"
          - "Do the changes keep the invariants and business rules of the touched components?"
          - "Does the new code behave right on edge cases, errors and concurrent calls?"
          - "Is each acceptance criterion covered by code and by a test?"
        context_required: [wi, full_files]
        detect:            # read by the classifier later; ignored now
          wi_type: [User Story, Feature, Product Backlog Item]
          branch_regex: "^(feature|feat)/"
        """,
        "bugfix": """
        id: bugfix
        title: Bugfix
        roles:
          required: [bug-hunter, contracts, requirements, tests]
          optional: [architecture, security, concurrency, performance, observability, history]
        checks:
          - "Is the cause fixed, not the symptom (from the repro steps)?"
          - "Does the fix change a contract (behaviour, error, format) that other code relies on?"
          - "Does a regression test reproduce the bug?"
          - "Do nearby code paths have the same defect?"
        context_required: [wi, full_files]
        detect:
          wi_type: [Bug]
          branch_regex: "^(fix|bug|hotfix)/"
        """,
        "security": """
        id: security
        title: Security
        roles:
          required: [security, bug-hunter]
          optional: [contracts, data-migrations, observability, history]
        checks:
          - "Which inputs from users, other services or files does the change read, and where do they end up?"
          - "Does every new endpoint, handler or job check who may call it, on the right object?"
          - "Can a secret, a token or personal data reach a log, an error, a URL, the browser's storage or an analytics event?"
          - "Does the change weaken a check: validation, escaping, an allowlist, a certificate check, a rate limit?"
        context_required: [full_files]
        detect:
          branch_regex: "^(sec|security)/"
        """,
        "dependency-upgrade": """
        id: dependency-upgrade
        title: Dependency upgrade
        roles: { required: [upgrade-risk, tests], optional: [contracts, security, performance] }
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
        "contracts": role("contracts", "Review what the change promises to other code: public APIs, DTOs, events, schemas and migrations, config keys, error codes, and whether every consumer still works.",
                          max: 4, needs: ["diff", "full_files", "history"],
                          doNotComment: ["style, naming and formatting", "internal code no other component or system uses",
                                         "breaks that the project's constraints explicitly allow (a new version of a versioned API), when no consumer in the repository breaks"], body: """
                          A contract is anything another component, service, client or stored data relies on. Find each one the change adds, changes or removes, then find who relies on it.

                          1. List the contracts in the diff: function and type signatures that are public or used across modules, HTTP and RPC endpoints and their request and response shapes, DTOs and serialized formats, events and messages, database schemas and migrations, config keys and environment variables, CLI flags, error types and codes, feature flags.
                          2. For each changed one, `grep` for its consumers in the repository (callers, implementations, serializers, tests, other services' clients). Name them. A consumer in another repository: read it with your MCP tools if you can, else report a context gap naming the contract.
                          3. Then ask, with evidence:
                             - Does any consumer break: a removed or renamed field, a new required field, a changed type, unit, default, order or nullability?
                             - Does stored data still read: old rows, cached and queued messages, persisted files? Does the migration run on a big table, and can it roll back?
                             - Does behaviour change behind an unchanged signature: a new error thrown, a different meaning of null or empty, a side effect, a change in idempotency or ordering?
                             - Is a deploy order needed (server before client, migration before code), and does the code stay safe when the order is wrong?
                             - Is the contract change versioned or documented where the project wants it?

                          Every finding names the contract, the consumer that breaks and how. A contract change with no consumer at risk is not a finding.
                          """),
        "architecture": role("architecture", "Review where the change sits in the system: boundaries and layers, dependency direction, responsibilities, coupling, and fit with the existing design.",
                             max: 3, needs: ["diff", "full_files", "history"],
                             doNotComment: ["style, naming and formatting", "taste: a different design that is not clearly better for this codebase",
                                            "rewrites out of the change's scope"], body: """
                             Review the design of the change as the owner of the system's structure. Start from the brief's touched components, then open the code around them: how do neighbours solve the same problem?

                             - Boundaries: does logic land in the wrong layer or module (business rules in a controller or a view, SQL or HTTP in the domain, UI state in a service)?
                             - Dependency direction: does a low-level module now import a high-level one, or does a cycle appear? Does a module reach into another's internals instead of its public interface?
                             - Responsibility: does one unit now do two jobs, or does the change spread one concept over many places (shotgun surgery)?
                             - Duplication of a concept: does it build a second way to do what the codebase already does (a second HTTP client, retry loop, config reader, mapper)? Name the existing one.
                             - State and lifetime: new global or shared mutable state, singletons, caches without an owner or invalidation.
                             - Failure design: where do errors go, which component decides, does a failure in one part now take down another?
                             - Fit: does it follow the patterns of project-rules.md and the knowledge notes? A break from them needs a reason the code or the rules give.

                             For each finding say what the design makes hard or risky next (a change that will need touching N places, a cycle that blocks a split, a test that can't be written) and name the place in the codebase that shows the better way. When the design is doubtful but you can't show harm, submit it with `kind: "question"` to the author instead of a claim.
                             """),
        "domain": role("domain", "Review a change against the domain: invariants, business rules and state transitions of the touched components.",
                       max: 3, needs: ["diff", "full_files", "wi"],
                       doNotComment: ["style and naming", "rules the context pack doesn't state or show in code",
                                      "contracts and layering (the contracts and architecture roles own them)"], body: """
                       Check the change as someone who owns the business rules of these components.

                       - Which invariants does each touched aggregate, entity or service keep? Can the new code break one (an order with no lines, a negative balance, a state reached from the wrong state)?
                       - Do state changes follow the allowed transitions? Look for a new path that skips a check.
                       - Does the code use a domain term with a different meaning than the work item or the knowledge notes, so that a rule gets applied to the wrong thing?

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
        "performance": role("performance", "Review the cost of the change on hot paths: queries, loops, allocations, network calls, caching, and how they grow with data.",
                            max: 3, needs: ["diff", "full_files", "history"],
                            doNotComment: ["micro-optimisations without a measured or obvious hot path", "style and naming",
                                           "code that runs once at start-up or in tests"], body: """
                            Find where the change makes something slower or heavier in a way users or operators will notice. For each finding name the path, how often it runs, and how its cost grows (with rows, items, users, payload size).

                            - Database: a query inside a loop (N+1), a query without the index its filter or sort needs, a full-table read or count, a new query on every request that could be read once.
                            - Network and I/O: a call per item instead of a batch, a synchronous call on a request path or the main thread, a missing timeout, a large payload read fully into memory.
                            - Algorithms: a nested loop over two collections that grow, repeated sorting or parsing, a linear search in a hot loop.
                            - Memory: unbounded caches, lists or buffers; loading a whole file, table or response when a stream would do.
                            - Caching: a cache without an expiry or a bound, a cache key that misses on every call, invalidation that serves stale data.

                            Evidence is the line that runs per item or per request. If you can't tell how often a path runs or how big the data is, ask with `kind: "question"`.
                            """),
        "concurrency": role("concurrency", "Review shared state and parallel work: races, locks, async calls, retries and idempotency.",
                            max: 3, needs: ["diff", "full_files"],
                            doNotComment: ["style and naming", "races without two concrete callers or tasks that can overlap"], body: """
                            Find what goes wrong when two things happen at once. For each finding name the two actors (threads, tasks, requests, instances, consumers) and the order of steps that breaks.

                            - Shared mutable state without a lock, an actor or a transaction; check-then-act and read-modify-write on a shared value or row.
                            - Locks: taken in different orders (deadlock), held across a slow call or an `await`, never released on an error path.
                            - Async: a call not awaited, a task that outlives its owner, cancellation that leaves state half-changed, work on the wrong thread or queue.
                            - Distributed: two instances running the same job, a message handled twice, an event out of order. Is the handler idempotent?
                            - Retries: a retry of a call that isn't idempotent (double charge, double send), retries without backoff or a limit.

                            Quote the line where the shared state is read or written.
                            """),
        "data-migrations": role("data-migrations", "Review schema and data migrations: locks on big tables, rollbacks, data loss, and the deploy order with the code.",
                                max: 3, needs: ["diff", "full_files", "history"],
                                doNotComment: ["migration file naming and formatting", "changes with no migration, schema or stored data in them",
                                               "consumers in other code of a changed API or DTO (the contracts role owns them)"], body: """
                                Review every change to a schema or to stored data (SQL and ORM migrations, schema files, data backfills, changes to serialized formats in a store or a queue).

                                - Locks and duration: an `ALTER` that rewrites or locks a big table, an index built without the online or concurrent option, a backfill in one transaction.
                                - Data loss: a dropped or renamed column or table still read by running code, a type change that truncates, a `NOT NULL` without a default on existing rows.
                                - Rollback: can the migration go back? Does the down step lose data? Is a one-way step marked as one?
                                - Deploy order: old code running against the new schema, and new code against the old schema, during the rollout. A column the old code writes must stay until no old code runs.
                                - Data meaning: a backfill that guesses values, defaults that change what old rows mean, time zones and units.

                                Name the table and the step. If the size of a table matters and you can't know it, ask with `kind: "question"`.
                                """),
        "observability": role("observability", "Review whether operators can see and diagnose the change in production: errors, logs, metrics, traces and alerts.",
                              max: 2, needs: ["diff", "full_files"],
                              doNotComment: ["advice to add logging without a failure that would stay invisible", "log wording and levels as taste",
                                             "secrets and personal data in logs (the security role owns them)"], body: """
                              Ask: when this change fails in production, will anyone know, and can they tell why? A finding names the failure and what an operator would see (nothing, a wrong number, a log without the cause).

                              - Errors swallowed or logged without the cause, the ID of the request or the entity, or the input that failed.
                              - A new failure mode (a call to a new service, a queue, a job) with no metric, alert or health check where its neighbours have one.
                              - Metrics or traces the change breaks: a renamed metric or label dashboards and alerts use, a span not closed, a label with unbounded values (user ids, URLs).
                              - Log volume: a log line per item or per request on a hot path that will flood the logs.
                              - A background job or retry loop that can fail forever without a signal.
                              """),
        "history": role("history", "Review the change against the history of its files: old bugs coming back, fixes undone, and what people already asked for in these files.",
                        max: 2, needs: ["diff", "full_files", "history"],
                        doNotComment: ["the history itself: old commits, old merge requests, who wrote what",
                                       "a rule from an earlier thread that the project's constraints or this change's work item overrule"], body: """
                        Read `context/history.md`: the commits behind the changed lines (git blame at the base commit), the recent commits of each file, and people's threads in earlier merge requests on these files. Then ask of each hunk:

                        - Does it undo a fix? A line a commit named "fix …" added is removed or changed back: name that commit and the bug it fixed.
                        - Does an old bug come back? The same pattern a fix removed elsewhere in the history appears again.
                        - Does it go against what a person asked for in an earlier merge request on this file (a convention, a pitfall, "never call X here")? Quote the request and the merge request number.
                        - A file that changes often with "fix" commits is fragile: look harder there, but report only a concrete problem of this change.
                        """),
    ]

    /// Ids in the order a new layer lists them.
    public static let roleIDs = ["contracts", "architecture", "domain", "requirements", "tests", "bug-hunter", "upgrade-risk", "security",
                                 "performance", "concurrency", "data-migrations", "observability", "history"]
    public static let scenarioIDs = ["feature", "bugfix", "security", "dependency-upgrade"]

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
