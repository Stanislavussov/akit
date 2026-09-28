# Architecture: splitting AKitCore into swappable modules

Status: plan, 2026-09-28. No code has moved yet.

## Goal

Today almost all logic is one Swift target, `AKitCore` (≈ 9,800 lines in 11 folders).
The goal is one module per area, each with a small public API, so that one area
can later be replaced by a third-party tool or library without touching the
rest. AKit itself (the app in `AKit/` and the `akit` command) becomes a thin
shell on top.

What this plan does not add: no new protocols, no dependency injection, no
runtime switches. A module boundary is a Swift module (a separate compile unit).
Anything not marked `public` is invisible outside it, and the compiler enforces
that. Replacing a module later means deleting it, adding the replacement as a
dependency, and fixing the few call sites the compiler points to.

Words used below:

- **Module**: a Swift target. Other code sees only what it marks `public`.
- **Seam**: the place where a module could be cut out and replaced. It is made of
  plain data structs (no protocols).
- **Umbrella**: a temporary `AKitCore` module that re-exports all new modules,
  so the app and CLI keep compiling with `import AKitCore` while files move.

## 1. Module map

Every module name starts with `AKit`. A Swift module that contains a type with
its own name (module `Brain` with struct `Brain`) breaks qualified names such as
`Brain.Skill`, so the prefix is needed.

| Module | Responsibility | Files that move there (from `AKitCore/Sources/AKitCore/`) |
|---|---|---|
| `AKitFoundation` | Shared toolbox with no harness knowledge: machine environment, running processes, secrets, backups, diffs, parsers, file walking. | `Support/*` except `FileProbe.swift`; `MCP/ConfigText.swift` (ConfigText, ConfigTextError, MiniTOML); `Sessions/JSONLines.swift`; new `FileWalk.swift` (`children`, `isDirectory` and `tilde`, taken out of `SkillScanner`); new `Trash.swift` (`SkillRemover.defaultTrash`) |
| `AKitModel` | Shared vocabulary that several modules use. Only value types: no file access, no logic. | `Model/Harness.swift` (HarnessID, HarnessInstallation, ConfigLocation); from `Model/Skill.swift`: SkillScope, SkillRoot; `MCPSource` and `MCPApproval` (from `MCP/MCPServer.swift`); `InstallScope` (from `SkillsSh/SkillInstaller.swift`); `TokenCounts` (from `Sessions/SessionUsage.swift`) |
| `AKitHarnesses` | Detects which harnesses are installed and where each one keeps things: config folders, skill folders, MCP files, known projects. | `Adapters/*` (HarnessAdapter, the four adapters, HarnessCatalog); `Custom/CustomHarness.swift`; `Support/FileProbe.swift`; `Skills/ProjectFinder.swift` |
| `AKitSkills` | Finds, lists, reads and trashes skills on disk, and knows where each skill came from. | `Model/Skill.swift` (`Skill`); `Skills/SkillScanner.swift` (+ PiNameRule, SkillLock); `SkillFiles.swift`; `SkillRemover.swift`; `SkillsSh/InstalledSkillLock.swift` |
| `AKitSkillsSh` | Searches skills.sh, downloads skills and installs them into harness folders. | `SkillsSh/SkillsShClient.swift`, `RemoteSkillFetcher.swift`, `SkillInstaller.swift` |
| `AKitSessions` | Lists saved sessions, reads transcripts, and reads or captures system prompts. | `Sessions/*` except JSONLines; per-harness dispatch taken out of the adapters (see 1.2) |
| `AKitUsage` | Token usage and subscription limits for each harness. | `Usage/*`; `extension ClaudeSessions` / `extension PiSessions` in `HarnessUsage.swift` become `enum ClaudeUsage` / `enum PiUsage` |
| `AKitMCP` | Reads, edits and writes MCP servers, including Keychain secrets. | `MCP/*` except ConfigText and MCPSource |
| `AKitBrain` | The brain repo: layers, `layer.yaml`, fields, answers, sync, import, remove, create layer, project ids and stored answers/locks. Turns layers and answers into a harness-neutral `ProjectBundle`. | `Brain/Brain.swift`, `Layer.swift`, `LayerManifest.swift`, `LayerWriter.swift`, `BrainSetup.swift`, `BrainSync.swift`, `BrainImport.swift`, `BrainRemove.swift`, `AKitSkill.swift`; `ProjectAnswers`/`FieldValue` and render steps 1–2 plus template/skill selection from `Render.swift`; storage helpers (`metadataFolder`, `savedAnswers`, `savedLock`, `save`, `projectID`, `homeID`) from `ProjectSetup.swift` |
| `AKitRender` | **The swappable part.** Turns a `ProjectBundle` into harness files: `.agents/skills/<name>/…`, a glued `AGENTS.md`, the `CLAUDE.md` shim, the `.claude/skills` link, the manual-only skill header, clash checks. Pure: it writes nothing. | Render steps 3–5 of `Brain/Render.swift` |
| `AKitProjectSetup` | Writes rendered files into a project safely: diff preview, blockers, backup, Trash, `lock.json`, and committing the answers in the brain. | `Brain/ProjectSetup.swift` (plan + apply) |
| `AKitCommandLine` | The logic behind the `akit` command, including the `akit setup` wizard. | `CLI/AKitCLI.swift`; `Brain/Onboarding.swift` (used only by the CLI) |
| `akit` (executable) | Unchanged. It now imports `AKitCommandLine`, `AKitHarnesses` and `AKitBrain`. | `Sources/akit/main.swift` |
| `AKit` (app) | SwiftUI shell. | `AKit/*` |

Tests move from `Tests/AKitCoreTests/` into one test target per module (see step 5).

### 1.1 Dependency graph (target state)

```
                        AKitFoundation   (toolbox)
                              │
                          AKitModel      (vocabulary)
                 ┌────────────┼──────────────────────┐
           AKitHarnesses   AKitSessions         AKitUsage
            │    │    │
   AKitSkills  AKitMCP  (ProjectFinder)
      │    │
AKitSkillsSh  AKitBrain ── Yams
     (also →      │
   Harnesses)  AKitRender        ← rulesync seam
                  │
            AKitProjectSetup  (→ Brain, Render)
                  │
            AKitCommandLine   (→ Brain, ProjectSetup, Harnesses)
                  │
         akit (exe)      AKit (app → every feature module)
```

Rules:

- Arrows point down only. Nothing imports a module above it.
- `AKitSessions` and `AKitUsage` need only `AKitModel` + `AKitFoundation`. They
  take a `HarnessInstallation` (its `configRoot` and `executableURL`) and read
  the harness's own files.
- `AKitSkills`, `AKitMCP` and `AKitSkillsSh` ask `AKitHarnesses` where things
  are (`skillRoots`, `mcpSources`, `skillInstallRoot`), then do the work.
- `AKitBrain → AKitSkills` is allowed for one thing: `SkillLock`, which says where
  a skill came from, is shown when skills are imported into the brain.

### 1.2 Couplings found today and how to break them

The table was built from type references between folders. The adapter protocol
is the central knot: `HarnessAdapter` returns Sessions, Usage, MCP and SkillsSh
types, and Sessions, Usage, Skills and MCP all call `HarnessCatalog`. Every
feature therefore depends on every other through the adapters.

| # | Coupling today | Fix |
|---|---|---|
| 1 | `HarnessAdapter` declares `sessions`, `transcript`, `usage`, `limits`, `recordedPrompt`, `systemPromptAccess` and `capturePrompt`. The adapters call `ClaudeSessions`, `PiSessions`, `PiPromptProbe`, `CodexUsage` and `OpenCodeUsage`, and Sessions and Usage call back through `HarnessCatalog` (a cycle). | Remove these seven methods from the protocol. `AKitSessions` gets `SessionScanner.scan(installations:env:)`, `SessionReader.transcript(of:)` and `PromptReader.access(for:)`, `.recorded(in:)` and `.capture(installation:project:env:)`. Each one does a `switch` on `HarnessID` to call the per-harness readers that already live in `Sessions/`. `AKitUsage` does the same for `UsageScanner.scan` and `scanLimits`. The per-harness readers stay `internal`. The adapter protocol keeps only "where things are": `detect`, `knownProjects`, `skillRoots`, `skillInstallRoot`, `mcpSources`. |
| 2 | `Usage/HarnessUsage.swift` extends `ClaudeSessions` and `PiSessions` (Sessions internals). `ClaudeCostRates` uses `ClaudeSessions.CostState` and `.baseModel`. | Rename them to `enum ClaudeUsage` / `enum PiUsage` inside Usage. `CostState` and `baseModel` move with them. |
| 3 | `TokenCounts` lives in Sessions but Usage uses it everywhere. | Move `TokenCounts` to `AKitModel`. `ModelUsage`, `SessionUsage` and `ToolCount` stay in Sessions. |
| 4 | `JSONLines` (Sessions) is used by Usage. | Move to `AKitFoundation`. |
| 5 | `SkillScanner.children`, `.isDirectory` and `.tilde` are used by Sessions, Usage, MCP, SkillsSh and ProjectFinder. | New `FileWalk` in `AKitFoundation`. `hasSkillFile` stays in Skills and becomes public for SkillsSh. |
| 6 | `SkillRemover.defaultTrash` is the default in Brain, SkillsSh, ProjectSetup and the CLI. | New `Trash.move(_:)` in `AKitFoundation`. |
| 7 | `Support/SecretStore.swift` throws `ConfigTextError` (MCP). `CustomHarness` and `CodexAdapter` use `ConfigText`/`MiniTOML` (MCP internals). | Move `ConfigText.swift` to `AKitFoundation`. |
| 8 | `Support/FileProbe.swift` builds `ConfigLocation` (Model), so Support points up. | Move `FileProbe` to `AKitHarnesses` (only adapters use it). |
| 9 | Adapters build `MCPSource` and set its internal fields (`approval`, `inactiveReason`, `turnedOff`) and the internal `MCPApproval`. | Move `MCPSource` and `MCPApproval` to `AKitModel` with public inits/settable fields. |
| 10 | `MCPWriter.targets(from:)` calls `ClaudeCodeAdapter().stateFile(in:)` directly. | The Claude adapter marks its `~/.claude.json` sources with a new `MCPSource` flag (for example `writesThroughClaudeCLI`). `MCPWriter` reads the flag. The four concrete adapters can then become `internal`. |
| 11 | Skills ↔ SkillsSh cycle: `SkillLock` (Skills) reads `InstalledSkillLock` (SkillsSh), and SkillsSh uses Skills. | Move `InstalledSkillLock` to `AKitSkills`: the skill library owns "where did this come from". SkillsSh writes it through its public API. |
| 12 | `InstallScope` lives in SkillsSh but is part of the adapter protocol. | Move to `AKitModel`. |
| 13 | `HarnessCatalog.allAdapters(custom:)` needs `CustomHarnessAdapter`, and `CustomHarness` needs `HarnessAdapter`. | Both go into `AKitHarnesses` together. |
| 14 | `Brain/Render.swift` uses `BrainImport.copyable`. `ProjectSetup` uses `Render`. `BrainRemove.forgetProject` uses `ProjectSetup.metadataFolder`. `Onboarding` uses `ProjectSetup.plan`/`apply`, `ProjectFinder` and `BrainSync`. | Split `Render` at the seam (section 4). Storage helpers go to Brain. `Onboarding` goes to `AKitCommandLine`, which sits above everything it uses. |
| 15 | The `HarnessID` → render-target mapping (`.claudeCode ? "claude" : rawValue`) is duplicated in `AKit/AppModel.swift:164` and `Sources/akit/main.swift:10`. | One function in `AKitBrain`, for example `ProjectAnswers.target(for: HarnessID)`. |

## 2. Packaging choice

**Recommendation: one package with one target per module.** The package stays in
`AKitCore/` (`AKitCore/Sources/<Module>/`, `AKitCore/Tests/<Module>Tests/`).
Local packages under `Packages/<Name>/Package.swift` are the alternative.

Why:

- **Swapping costs the same either way.** Replacing a module means changing
  one dependency line (`"AKitUsage"` → `.product(name: "X", package: "x")`) in
  the modules that use it, plus fixing call sites. Separate packages don't make
  that easier.
- **Boundaries hold equally well.** Each target is its own module, so
  `internal` is private to it. The one leak inside a single package is the
  `package` access keyword. Rule: never use `package` in AKit code. With that
  rule, every module can be moved into its own package later without code changes.
- **Much less to maintain.** One `Package.swift` and one `Package.resolved`. One
  `swift test` still runs every test (`make test` unchanged). Separate packages
  would each build their dependencies again in their own `.build` folder, and
  `make test` would have to loop over them.
- **Scripts stay the same.** `make install-cli`, `make release`, `install.sh`
  (it checks for `AKitCore/`), `tools/demo-home.sh` and `.gitignore` all point
  at `AKitCore/` and the `akit` product. Keeping both names means none of them change.

If a module is later published or replaced by someone else's Swift package,
move that one folder into its own `Package.swift` at that point.

**Umbrella**: keep a temporary `AKitCore` target whose only file is
`Exports.swift` (`@_exported import AKitFoundation`, …) while modules are
extracted, so the app and CLI need no edits during the move. Remove it in the
last step. The app then imports exactly the modules each screen uses, and
Xcode shows each screen's dependencies. `@_exported` is an underscored
(unofficial) attribute, which is fine for a transition but not something to keep.

`project.yml`: unchanged during the transition (the app depends on product
`AKitCore`). In the last step it lists one `product:` per module the app imports.

## 3. Public API per module

"Used by" comes from grepping `AKit/*.swift`, `CLI/AKitCLI.swift` and
`Sources/akit/main.swift`. Everything else becomes or stays `internal`.
Tests use `@testable import`, so they still see internals.

| Module | Used by app / CLI today (stays public) | Make internal |
|---|---|---|
| Foundation | `HarnessEnvironment` (`.current`, `expand`, `findExecutable`, `pathForChildProcesses`), `ProcessRunner.run`, `SecretFilter.masked`, `KeychainSecretStore` (+ `.service`), `TextDiff.lines`/`.Line`, `VersionProbe.version` | Only other modules use these, so they are public for modules and not for UI: `Backup`, `Frontmatter`, `ConfigText`, `MiniTOML`, `JSONLines`, `FileWalk`, `Trash`, `SecretStore`. `MemorySecretStore` is only for tests. |
| Model | `HarnessID`, `HarnessInstallation`, `ConfigLocation`, `SkillScope` | Everything is public vocabulary; keep it small. |
| Harnesses | `HarnessCatalog.adapters` / `.allAdapters(custom:)` / `.detectAll`, `HarnessAdapter` (only `id`, `displayName`), `CustomHarness` (+ `.slug`), `CustomHarnessStore.load/update/url`, `ProjectFinder.defaultRoots/projects` | `ClaudeCodeAdapter`, `PiAdapter`, `CodexAdapter`, `OpenCodeAdapter`, `CustomHarnessAdapter` (reached only through `HarnessCatalog`) |
| Skills | `Skill`, `SkillScanner.scan/projects`, `SkillFiles.list/text`, `SkillRemover.moveToTrash/removesOnlyLink`, `PiNameRule.problems`, `InstalledSkillLock.load/forget/publishedOrigin` | `SkillScanner` walking internals, `SkillLock` (public only for Brain) |
| SkillsSh | `SkillsShClient.search/base/minimumQueryLength`, `RemoteSkill`, `RemoteSkillFetcher.fetch`, `FetchedSkill`, `SkillInstaller.targets/install/conflicts/blockedConflicts/nameProblems`, `InstallRequest`, `InstallTarget` | `SkillLocator`, `SkillText`, `SkillCopier` |
| Sessions | `SessionScanner.scan`, `SessionSummary`, `SessionTranscript`, `TranscriptItem`, `SessionUsage`, `PromptSnapshot`, `SessionExport.json/markdown/usageMarkdown`; new `SessionReader`, `PromptReader`, `SystemPromptAccess` | `ClaudeSessions`, `PiSessions`, `PiPromptProbe`, `TranscriptBuilder`, `UsageCounter` |
| Usage | `UsageScanner.scan/scanLimits`, `UsageRecord`, `LimitSample`, `DailyUsageReport`, `UsageTotal`, `Subscription`, `SubscriptionLimitReport` | `ClaudeUsage`, `PiUsage`, `CodexUsage`, `OpenCodeUsage`, `ClaudeCostRates` |
| MCP | `MCPScanner.scan`, `MCPServer`, `MCPSetting`, `MCPState`, `MCPDraft` (+ `parse`, `editing`, `split/joinArguments`), `MCPSecretMode`, `MCPWriter.targets/target/plan/removalPlan/apply/rawEntry/sourceLine/storeSecret/isEnvFileSourced`, `MCPWritePlan`, `MCPWriteTarget` | `MCPReader`, `MCPValues`, `MCPScanResult` internals |
| Brain | `Brain` (+ `.load`, `.defaultRoot`, `.Skill`), `Layer`, `LayerField`, `LayerSkill.Mode`, `Condition`, `FieldValue`, `ProjectAnswers`, `BrainImport.plan/apply/coreAfter/defaultSource`, `BrainRemove.*`, `BrainSetup.create`, `BrainSync.status/sync`, `LayerWriter.create/nameProblem/Draft`; storage `projectID/homeID/savedAnswers`; new `ProjectBundle`, `RenderedFile`, `resolve` | `LayerManifest`, `AKitSkill`, `copyable`, `addSkills` |
| Render | one function: `Render.render(_ bundle: ProjectBundle, forHome:) -> RenderResult` | `substitute`, `manualOnly`, `matches` |
| ProjectSetup | `ProjectSetup.plan/apply`, `.Plan`, `.Change`, `.Outcome`, `.Failure` | lock entries, `escapes`, `state` |
| CommandLine | `AKitCLI.run`, `Onboarding.Preferences` | the rest |

Structs built in one module and used in another need an explicit `public init`,
because Swift's automatic init is internal. This is the most common build error
while moving files.

### Where the UI depends on implementation details (fix before or during the split)

1. **Sessions through adapters**: `AppModel.swift:318–366` calls
   `adapter.transcript`, `recordedPrompt`, `capturePrompt` and
   `systemPromptAccess`. After fix 1 it calls `SessionReader` / `PromptReader`
   from `AKitSessions`. The UI then no longer needs the adapter for anything
   but names and ids.
2. **MCP writes via the Claude CLI are coded in the UI**: `AppModel.applyMCP`
   (`AppModel.swift:294–310`) builds the closure that runs `claude mcp …` with
   `ProcessRunner` and `SecretFilter`. Move it into `AKitMCP`
   (`MCPWriter.apply(plan, claude: installation, secrets:, env:)`). Otherwise a
   replacement MCP module would leave dead process code in the app.
3. **The project form calls Render directly**: `ProjectSetupSheet.swift:53–56`
   calls `Render.render` for live form errors. It should call
   `AKitBrain`'s `resolve`, which reports missing fields, unknown layers and
   conflicts, or `ProjectSetup.plan`. Then only `AKitProjectSetup` calls the
   render module, and a rulesync swap touches one call site.
4. **`ProjectSetup.Plan.render: Render.Result`** is shown in the sheet. Keep it,
   but typed with the seam's `RenderedFile`/`RenderResult` from `AKitBrain`
   (section 4), not a type owned by the render module.
5. **Target names** (fix 15).

## 4. Swap-readiness

Only real, known tools are named here. "None known" means none were found, not
that none exist.

| Module | Possible replacement |
|---|---|
| Foundation | Parts only: `KeychainAccess` (kishikawakatsumi) for Keychain, `swift-subprocess` (swiftlang) for `ProcessRunner`, Yams (already a dependency) for frontmatter, `TOMLKit` for TOML. Not worth swapping as a whole. |
| Model | None. It is AKit's own vocabulary. |
| Harnesses | None known. rulesync knows many tools' file paths for *writing*, but it doesn't detect installs or read existing configs. |
| Skills | None known for scanning. |
| SkillsSh | `npx skills` (vercel-labs/skills), the official CLI behind skills.sh. AKit already calls the same search endpoint. The swap would run the CLI instead of `RemoteSkillFetcher` + `SkillInstaller`. |
| Sessions | None known. |
| Usage | `ccusage` (npm) reads Claude Code usage from the JSONL files, and has a Codex companion. It prices tokens from a price table by default. AKit shows only recorded costs, so its recorded-cost mode would need checking. |
| MCP | None known that edits all four formats. rulesync writes project MCP files from `.rulesync/mcp.json`, which could cover the planned "MCP in layers" step. `claude mcp add` is already used for Claude's user/local scopes. |
| Brain | None. It is AKit's own idea (layers, questions, answers). |
| **Render** | **rulesync** (dyoshikawa/rulesync). Confirmed. |
| ProjectSetup | None. It holds AKit's safety rules (diff first, backup, Trash, lock). Keep it. |
| CommandLine | `swift-argument-parser` (apple) could replace hand-written argument parsing. |

### The rulesync seam (Brain → Render → ProjectSetup)

Today `Render.render(answers, brain:, projectName:, forHome:)` does five steps.
Steps 1–2 plus picking skills and templates are about AKit's layers. Steps 3–5
are about harness file layout. The cut goes between them:

```
AKitBrain (AKit keeps)      AKitRender (swappable)       AKitProjectSetup (AKit keeps)
answers + layers  ──►  ProjectBundle  ──►  RenderResult  ──►  diff / backup / Trash / lock / commit
+ brain UI                 (seam in)          (seam out)
```

AKit keeps: the brain repo, layers, `layer.yaml`, fields and `{{field}}`
filling, `when` conditions, `requires`/`conflicts`, answers, the project form
and the brain screens. rulesync does not ask per-project questions, so those
stay AKit's.

Data going **into** the seam: `ProjectBundle`, defined in `AKitBrain`:

- `projectName`, `targets` (`claude`, `pi`, `opencode`, `codex`), `forHome`
- `layers`: resolved order (required first, then the user's selection order)
- `instructions`: `[(layer, to: "AGENTS.md", text)]`, Markdown fragments with fields already filled in
- `files`: `[(layer, to, data, override)]`, other template outputs with fields filled in
- `skills`: `[(name, mode: auto|manual, layer, files: [relativePath: Data])]` with fields filled in the `.md` files
- `errors` / `warnings` from resolving (missing required field, unknown layer, clash)

Data coming **out**: `RenderResult`, also defined in `AKitBrain`, so a
replacement module needs nothing from the old one:

- `outputs: [RenderedFile]`, each with `path` (relative to the project),
  `content` (`.data` or `.link(destination)`) and `layers`
- `errors`, `warnings`

A rulesync-based `AKitRender` would:

1. write the bundle into a temporary folder as `.rulesync/rules/*.md` (the
   AGENTS.md fragments), `.rulesync/skills/<name>/` and `rulesync.jsonc`
   (targets + features);
2. run `rulesync generate --targets … --features rules,skills` there, through
   `ProcessRunner` (rulesync ships through npm, Homebrew and as a single binary);
3. read back every file it wrote and return them as `RenderedFile`s.

AKit's `ProjectSetup` then shows the diff, backs up, writes and records
`lock.json` exactly as today. That keeps the CLAUDE.md rule "safe writing:
backup + diff first". Letting rulesync write into the project directly would
lose the preview, the lock and the Trash cleanup, so this plan doesn't do that.

## 5. Migration steps

Each step is one commit. `make build` and `make test` must pass after each one
(run `swift test` under the memory guard as usual), and a UI check is needed
only where a screen's code changes. No behavior changes anywhere.

**Phase A: untangle inside the single target** (no new modules yet; files move
between folders, nothing is renamed publicly). This removes every cycle, so
phase B is only moving files.

1. Add `docs/design/architecture.md` (this plan).
2. Toolbox moves: `FileWalk` and `Trash` into `Support/`; `ConfigText.swift`,
   `JSONLines.swift` into `Support/`; `FileProbe.swift` into `Adapters/`;
   `ProjectFinder.swift` into `Adapters/`. Update callers (fixes 4–8).
3. Vocabulary moves: `MCPSource` + `MCPApproval`, `InstallScope`, `TokenCounts`
   into `Model/`; `InstalledSkillLock` into `Skills/`; the Claude-state flag on
   `MCPSource` replaces `ClaudeCodeAdapter()` in `MCPWriter` (fixes 3, 9–12).
4. Sessions out of the adapters: `SessionScanner.scan(installations:)`,
   `SessionReader`, `PromptReader` + `SystemPromptAccess` in `Sessions/`; remove
   the five session/prompt methods from `HarnessAdapter`; update `AppModel` and
   tests. UI check: Sessions screen and prompt view (fix 1, part 1).
5. Usage out of the adapters: `ClaudeUsage`/`PiUsage` enums, `UsageScanner`
   dispatches on `HarnessID`; remove `usage`/`limits` from `HarnessAdapter`.
   UI check: Usage screen (fixes 1, part 2, and 2).
6. MCP Claude-CLI runner moves from `AppModel.applyMCP` into `MCPWriter`.
   UI check: MCP editor save.
7. Brain seam: add `ProjectBundle`/`RenderedFile`/`RenderResult` and
   `resolve` in `Brain/`; `Render.render` takes a bundle; storage helpers move
   from `ProjectSetup` to Brain; `ProjectSetupSheet` uses `resolve`; one
   target-name function (fixes 14–15). `RenderTests`/`ProjectSetupTests` must
   pass unchanged in what they check. UI check: Brain → Set Up Project….
8. Move `Onboarding.swift` into `CLI/`.

**Phase B: extract modules bottom-up** (a module can only depend on modules
already extracted). Each step: add the target and its test target to
`Package.swift`, `git mv` the files into `Sources/<Module>/`, mark as `public`
only what other modules use (section 3), add `@_exported import <Module>` to
the umbrella, move the module's tests to `Tests/<Module>Tests/` with
`@testable import <Module>`, and add `@testable import` lines where a test
touches internals of two modules.

9. `AKitFoundation` (ProcessRunnerTests, SecretFilterTests; move `FrontmatterTests` out of `SkillScannerTests.swift` into its own file here)
10. `AKitModel`
11. `AKitHarnesses` (DetectionTests.swift incl. VersionProbeTests, CustomHarnessTests)
12. `AKitSkills` (SkillScannerTests.swift incl. SkillRemoverTests, MoreHarnessTests)
13. `AKitSkillsSh` (SkillsShTests)
14. `AKitSessions` (SessionTests)
15. `AKitUsage` (UsageTests; the `SQLite3` import moves with it)
16. `AKitMCP` (MCPTests, MCPWriterTests incl. ArgumentLineTests)
17. `AKitBrain`; the Yams dependency moves from the umbrella to this target
    (BrainTests, BrainSetupTests, BrainImportTests, BrainRemoveTests,
    BrainSyncTests, LayerWriterTests)
18. `AKitRender` (RenderTests)
19. `AKitProjectSetup` (ProjectSetupTests)
20. `AKitCommandLine`; the `akit` executable depends on it (AKitCLITests,
    OnboardingTests)

**Phase C: remove the umbrella**

21. The app imports the specific modules; `project.yml` lists one `product:`
    per module; delete the `AKitCore` target and product; update the
    "Logic lives in the AKitCore Swift package" lines in `CLAUDE.md` and
    `README.md` to point at this document. `make install-cli`, `make release`,
    `install.sh` and `tools/demo-home.sh` stay unchanged because the package
    folder (`AKitCore/`) and the `akit` product keep their names.
    UI check: every section.

That is 21 steps, 20 of them after this document. Merge to master once at the
end. Phase A can be merged on its own if it takes long.

## 6. Risks and open questions

Risks:

- **`public` grows.** Helpers that were `internal` (FileWalk, ConfigText,
  JSONLines, Backup) become public for other modules. They are toolbox APIs,
  not UI APIs; review them in step 21.
- **Phase A steps 4–5 change the adapter protocol.** They are the only real
  refactor. Tests already cover detection, sessions and usage with a fake home,
  so regressions should show up there.
- **More modules make clean builds a little slower** and incremental builds
  faster. No effect on the release zip.

Decided (2026-09-28):

1. One package with 12 targets, not a package per module.
2. Adapters shrink to "where things are"; reading sessions and usage moves
   into the Sessions and Usage modules.
3. The package folder stays `AKitCore/`.
4. The split waits until `session-insights` and `skills-layer-add-button`
   are merged into master, because both touch most of the files it moves.
   Before starting, refresh this plan against the new master: add an
   `AKitInsights` module for `Insights/`, place `LayerEditor` and the new CLI
   commands, and recheck the couplings.

Still open:

- rulesync at runtime needs its binary or Node on each Mac. Is that
  acceptable, or should AKit's own renderer stay the default with rulesync
  optional? Also to check against the rulesync docs: exact target ids for
  Claude Code, Codex, OpenCode and Pi (Pi appears in its tool list); whether
  it supports manual-only skills (`disable-model-invocation`); and how it
  glues several rule files into one `AGENTS.md`.
