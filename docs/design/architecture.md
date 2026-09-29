# Architecture: splitting AKitCore into swappable modules

Status: plan, written 2026-09-28, refreshed 2026-09-29 against master `fb4f1d5`
(after `session-insights` and `skills-layer-add-button` were merged). No code has
moved yet.

## Goal

Today almost all logic is one Swift target, `AKitCore` (≈ 17,900 lines in 12 folders).
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
| `AKitFoundation` | Shared toolbox with no harness knowledge: machine environment, running processes, secrets, backups, diffs, parsers, file walking, hashing. | `Support/*` except `FileProbe.swift`; `MCP/ConfigText.swift` (ConfigText, ConfigTextError, MiniTOML); `Sessions/JSONLines.swift`; new `FileWalk.swift` (`children`, `isDirectory` and `tilde`, taken out of `SkillScanner`); new `Trash.swift` (`SkillRemover.defaultTrash`); new `Checksum.swift` (`ProjectSetup.sha256`, which is the same code as `JSONLines.hash`); `TextDiff.unified` (was `AKitCLI.unifiedDiff`) |
| `AKitModel` | Shared vocabulary that several modules use. Only value types: no file access, no logic. | `Model/Harness.swift` (HarnessID, HarnessInstallation, ConfigLocation); from `Model/Skill.swift`: SkillScope, SkillRoot; `MCPSource` and `MCPApproval` (from `MCP/MCPServer.swift`); `InstallScope` (from `SkillsSh/SkillInstaller.swift`); `TokenCounts` (from `Sessions/SessionUsage.swift`) |
| `AKitHarnesses` | Detects which harnesses are installed and where each one keeps things: config folders, skill folders, MCP files, known projects. | `Adapters/*` (HarnessAdapter, the four adapters, HarnessCatalog; without `SystemPromptAccess`); `Custom/CustomHarness.swift`; `Support/FileProbe.swift`; `Skills/ProjectFinder.swift`; new `HarnessCatalog.configRoot(of:in:)` and `HarnessCatalog.adapter(for:)` |
| `AKitSkills` | Finds, lists, reads and trashes skills on disk, and knows where each skill came from. | `Model/Skill.swift` (`Skill`); `Skills/SkillScanner.swift` (+ PiNameRule, SkillLock); `SkillFiles.swift`; `SkillRemover.swift`; `SkillsSh/InstalledSkillLock.swift` |
| `AKitSkillsSh` | Searches skills.sh, downloads skills and installs them into harness folders. | `SkillsSh/SkillsShClient.swift`, `RemoteSkillFetcher.swift`, `SkillInstaller.swift` |
| `AKitSessions` | Lists saved sessions, reads transcripts, reads or captures system prompts, and reads the line format of Claude and Pi session files. | `Sessions/*` except JSONLines; `SystemPromptAccess` (from `Adapters/HarnessAdapter.swift`); per-harness dispatch taken out of the adapters (see 1.2); new `ClaudeLogFormat` and `PiLogFormat` (line readers shared with Usage and Insights, fix 24) |
| `AKitUsage` | Token usage and subscription limits for each harness. | `Usage/*`; `extension ClaudeSessions` / `extension PiSessions` in `HarnessUsage.swift` become `enum ClaudeUsage` / `enum PiUsage` |
| `AKitMCP` | Reads, edits and writes MCP servers, including Keychain secrets. | `MCP/*` except ConfigText and MCPSource |
| `AKitBrain` | The brain repo: layers, `layer.yaml`, fields, answers, sync, import, remove, create and edit layers, brain links of installed skills, this Mac's profile (work or personal), project ids and stored answers/locks. Turns layers and answers into a harness-neutral `ProjectBundle`. | `Brain/Brain.swift`, `Layer.swift`, `LayerManifest.swift`, `LayerWriter.swift`, `LayerEditor.swift`, `BrainSetup.swift`, `BrainSync.swift`, `BrainImport.swift`, `BrainRemove.swift`, `BrainLinks.swift`, `AKitSkill.swift`; `Machine.swift` (`MachineProfile`, `ProjectStore`) without `MachineProfile.change`; `ProjectAnswers`/`FieldValue`, render steps 1–2 plus template/skill selection, `skillsFolder` and `projectSource` from `Render.swift`; new `ProjectRecords.swift` (ids, `Lock`, saved answers and locks, from `ProjectSetup.swift`); new `CapturePlugin.swift` (plugin files from `CaptureInstaller`); new `BrainGit.swift` (git identity checks from `WorkFilter`) |
| `AKitInsights` | Session insights: the local SQLite index of session facts, import, capture hooks (Claude plugin, Pi extension, launchd), project binding, `akit stats`, per-Mac usage summaries in the brain, recommendations with layer patches, before/after measurement. | `Insights/*` (28 files); new `Insights/MachineChange.swift`: `MachineProfile.change` and `hasOwnGitIdentity` as an `extension MachineProfile` (fix 18) |
| `AKitRender` | **The swappable part.** Turns a `ProjectBundle` into harness files: `.agents/skills/<name>/…`, a glued `AGENTS.md`, the `CLAUDE.md` shim, the `.claude/skills` link, the manual-only skill header, clash checks. Pure: it writes nothing. | Render steps 3–5 of `Brain/Render.swift` |
| `AKitProjectSetup` | Writes rendered files into a project safely: diff preview, blockers, backup, Trash, `lock.json`, committing the answers in the brain, and the project's own skills. | `Brain/ProjectSetup.swift` (plan + apply, without the storage helpers); `Brain/ProjectSkills.swift` |
| `AKitCommandLine` | The logic behind the `akit` command, including the `akit setup` wizard. | `CLI/AKitCLI.swift`; `Brain/Onboarding.swift` (used only by the CLI) |
| `akit` (executable) | Unchanged. It now imports `AKitCommandLine`, `AKitInsights` (`RecordSession`), `AKitHarnesses`, `AKitBrain` and `AKitFoundation`. | `Sources/akit/main.swift` |
| `AKit` (app) | SwiftUI shell. | `AKit/*` |

Tests move from `Tests/AKitCoreTests/` into one test target per module (see
section 5, phase B).

### 1.1 Dependency graph (target state)

```
                        AKitFoundation   (toolbox)
                              │
                          AKitModel      (vocabulary)
                 ┌────────────┴───────────────┐
           AKitHarnesses                 AKitSessions
            │    │    │                       │
   AKitSkills  AKitMCP  (ProjectFinder)   AKitUsage
      │    │
AKitSkillsSh  AKitBrain ── Yams
     (also →   │      │
   Harnesses)  │   AKitInsights   (also → Sessions, Skills, Harnesses; SQLite3)
               │      │
          AKitRender  │           ← rulesync seam
               │      │
            AKitProjectSetup      (→ Brain, Render, Insights)
                  │
            AKitCommandLine
                  │
         akit (exe)      AKit (app → every feature module except Render)
```

Direct dependencies, for `Package.swift` (each also sees nothing it doesn't list):

| Module | Depends on |
|---|---|
| `AKitFoundation` | nothing |
| `AKitModel` | nothing (no Model type uses the toolbox today) |
| `AKitHarnesses` | Foundation, Model |
| `AKitSkills` | Foundation, Model, Harnesses |
| `AKitSkillsSh` | Foundation, Model, Harnesses, Skills |
| `AKitSessions` | Foundation, Model |
| `AKitUsage` | Foundation, Model, Sessions |
| `AKitMCP` | Foundation, Model, Harnesses |
| `AKitBrain` | Foundation, Model, Skills, Yams |
| `AKitInsights` | Foundation, Model, Harnesses, Skills, Sessions, Brain |
| `AKitRender` | Brain |
| `AKitProjectSetup` | Foundation, Brain, Render, Insights |
| `AKitCommandLine` | Foundation, Model, Harnesses, Skills, Brain, Insights, ProjectSetup |
| `akit` | CommandLine, Insights, Harnesses, Brain, Foundation |

Rules:

- Arrows point down only. Nothing imports a module above it.
- `AKitSessions` needs only `AKitModel` + `AKitFoundation`. It takes a
  `HarnessInstallation` (its `configRoot`) or a `HarnessID` and reads the
  harness's own files.
- `AKitUsage → AKitSessions` is allowed for one thing: the public line readers
  `ClaudeLogFormat` and `PiLogFormat` (tokens and cost of one recorded response).
- `AKitSkills`, `AKitMCP` and `AKitSkillsSh` ask `AKitHarnesses` where things
  are (`skillRoots`, `mcpSources`, `skillInstallRoot`), then do the work.
- `AKitBrain → AKitSkills` is allowed for two things: `SkillLock`, which says
  where a skill came from, is shown when skills are imported into the brain; and
  `BrainLinks.links(for: [Skill], …)` marks installed skills that came from the brain.
- `AKitInsights` reads the brain and session files but writes into the brain only
  through `LayerPatch` and `SummaryPublisher`. Nothing below it knows it exists.
- `AKitProjectSetup → AKitInsights` is allowed for one thing: `apply` appends an
  `apply` line to the local spool (`Spool.append`), for before/after measurement.

### 1.2 Couplings found today and how to break them

The table was built by grepping, for every type declared in one folder, its
uses in the other folders (and in `AKit/*.swift` and `Sources/akit/main.swift`).
The adapter protocol is still the central knot: `HarnessAdapter` returns Sessions,
Usage, MCP and SkillsSh types, and Sessions, Usage, Skills and MCP all call
`HarnessCatalog`. The new knot is Insights: it uses almost every folder, and
Brain calls back into it in four places.

Rows 1–15 are from the first version of this plan; all still hold unless the row
says otherwise. Rows 16–28 are new.

| # | Coupling today | Fix |
|---|---|---|
| 1 | `HarnessAdapter` declares `sessions`, `transcript`, `usage`, `limits`, `recordedPrompt`, `systemPromptAccess` and `capturePrompt` (`HarnessAdapter.swift:23–43`). The adapters call `ClaudeSessions` (`ClaudeCodeAdapter.swift:76–90`), `PiSessions`, `PiPromptProbe` (`PiAdapter.swift:109–125`), `CodexUsage` and `OpenCodeUsage`, and Sessions (`Session.swift:157`) and Usage (`UsageRecord.swift:66`, `SubscriptionLimits.swift:92`) call back through `HarnessCatalog` (a cycle). | Remove these seven methods from the protocol. `AKitSessions` gets `SessionScanner.scan(installations:env:)`, `SessionReader.transcript(of:)` and `PromptReader.access(for:)`, `.recorded(in:)` and `.capture(harness:in:env:)` (it looks up the `pi` command at call time, as the adapter did). Each one does a `switch` on `HarnessID` to call the per-harness readers that already live in `Sessions/`. `AKitUsage` does the same for `UsageScanner.scan` and `scanLimits`. The per-harness readers stay `internal`. `SystemPromptAccess` moves to `Sessions/`. The adapter protocol keeps only "where things are": `detect`, `knownProjects`, `skillRoots`, `skillInstallRoot`, `mcpSources`. |
| 2 | `Usage/HarnessUsage.swift` extends `ClaudeSessions` (line 7, declares `Run`, `CostState`, `baseModel`) and `PiSessions` (line 223). `ClaudeCostRates` uses `ClaudeSessions.Run`, `.CostState` and `.baseModel` (`ClaudeCostRates.swift:15–54`). | Rename them to `enum ClaudeUsage` / `enum PiUsage` inside Usage. `Run`, `CostState` and `baseModel` move with them. |
| 3 | `TokenCounts` lives in Sessions (`SessionUsage.swift:4`) but Usage uses it everywhere, and Insights (`SessionFacts.swift:20`) and the app (`SessionUsageView.swift:101`) use it too. | Move `TokenCounts` to `AKitModel`. `ModelUsage`, `SessionUsage` and `ToolCount` stay in Sessions. |
| 4 | `JSONLines` (Sessions) is used by Usage (29 lines) and Insights (36 lines, e.g. `ClaudeFacts.swift`, `CaptureInstaller.swift:441`). | Move to `AKitFoundation`. |
| 5 | `SkillScanner.children`, `.isDirectory` and `.tilde` are used by Sessions, Usage, MCP, SkillsSh, ProjectFinder, Insights (`SessionImporter.swift:165–177`, `CaptureInstaller.swift:439`, `ProjectBinding.swift:522–527`, `InsightsStats.swift:405`) and the CLI (`AKitCLI.swift:1280`). | New `FileWalk` in `AKitFoundation`. `hasSkillFile` stays in Skills and becomes public for SkillsSh. |
| 6 | `SkillRemover.defaultTrash` is the default in Brain (`BrainRemove`, `ProjectSetup`, `ProjectSkills.swift:91`, `Onboarding`), SkillsSh and the CLI (`AKitCLI.swift:140`). | New `Trash.move(_:)` in `AKitFoundation`. |
| 7 | `Support/SecretStore.swift` throws `ConfigTextError` (MCP). `CustomHarness` and `CodexAdapter` use `ConfigText`/`MiniTOML` (MCP internals). | Move `ConfigText.swift` to `AKitFoundation`. |
| 8 | `Support/FileProbe.swift` builds `ConfigLocation` (Model), so Support points up. | Move `FileProbe` to `AKitHarnesses` (only adapters and `CustomHarness` use it). |
| 9 | Adapters build `MCPSource` and set its internal fields (`approval`, `inactiveReason`, `turnedOff`) and the internal `MCPApproval`. | Move `MCPSource` and `MCPApproval` to `AKitModel` with public inits/settable fields. `MCPApproval.state(of:)` returns an MCP type (`MCPState`), so it stays in MCP as an extension (`MCPReader.swift`). |
| 10 | `MCPWriter.targets(from:)` calls `ClaudeCodeAdapter().stateFile(in:)` directly (`MCPWriter.swift:83`). | The Claude adapter marks its `~/.claude.json` sources with a new `MCPSource` flag (for example `writesThroughClaudeCLI`). `MCPWriter` reads the flag. The four concrete adapters can then become `internal` (after fix 23 too). |
| 11 | Skills ↔ SkillsSh cycle: `SkillLock` (Skills) reads `InstalledSkillLock` (SkillsSh, `SkillScanner.swift:231,245`), and SkillsSh uses Skills. | Move `InstalledSkillLock` to `AKitSkills`: the skill library owns "where did this come from". SkillsSh writes it through its public API. |
| 12 | `InstallScope` lives in SkillsSh but is part of the adapter protocol (`HarnessAdapter.swift:46`). | Move to `AKitModel`. |
| 13 | `HarnessCatalog.allAdapters(custom:)` needs `CustomHarnessAdapter` (`HarnessAdapter.swift:94–95`), and `CustomHarness` needs `HarnessAdapter`. | Both go into `AKitHarnesses` together. |
| 14 | `Brain/Render.swift` uses `BrainImport.copyable` (a Brain internal). `ProjectSetup` uses `Render` and also changes its result: the project's own skills shadow the brain's and get their own `.claude/skills` link (`ProjectSetup.swift:171–208`). `Onboarding` uses `ProjectSetup.plan`/`apply`, `ProjectFinder` and `BrainSync`. (Corrected: `ProjectSetup.metadataFolder` is gone; `ProjectStore` in `Machine.swift` now owns the record folders.) | Split `Render` at the seam (section 4). The post-render steps stay in `ProjectSetup`: they read the project. `Onboarding` goes to `AKitCommandLine`, which sits above everything it uses. |
| 15 | The `HarnessID` → render-target mapping (`.claudeCode ? "claude" : rawValue`) is duplicated in `AKit/AppModel.swift:227` and `Sources/akit/main.swift:16`. | One function in `AKitBrain`, for example `ProjectAnswers.target(for: HarnessID)`. |
| 16 | Brain → Insights: `BrainSetup.create` writes `CaptureInstaller.pluginFiles` into a new brain (`BrainSetup.swift:57`). | New `Brain/CapturePlugin.swift` holds `pluginFiles` and the constants they use (`pluginVersion`, `marketplace`, `marker`). `CaptureInstaller` reads them from there and keeps forwarding statics of the same names, so `CaptureTests` stay unchanged. |
| 17 | Brain → Insights: `BrainSync` uses `WorkFilter.requireOwnIdentity`, `.withoutIdentity` and `.noSigning` (`BrainSync.swift:110,231–232`). The rest of `WorkFilter` needs `LayerPatch` and `UsageSummary`, so it can't move down. | New `Brain/BrainGit.swift` with `identityVariables`, `withoutIdentity`, `noSigning` and `requireOwnIdentity` (plus the small git runner it needs). Messages stay word for word. `WorkFilter` calls `BrainGit` and wraps its failure. |
| 18 | Brain → Insights: `MachineProfile.change` reads `UsageSummary.ownKeys(home:)` from the SQLite index (`Machine.swift:243`) and `UsageSummary.projectFiles` (`Machine.swift:285`). Insights uses `MachineProfile` in 19 places, so this is a cycle. | Move `change(to:brain:home:…)` and `hasOwnGitIdentity` into `Insights/MachineChange.swift` as `extension MachineProfile`. Call sites stay `MachineProfile.change(…)` (`AppModel.swift:82`, `AKitCLI.swift:353`, `UsageSummaryTests`). Brain makes `identify(hardware:own:now:)` public and gets a public way to clear `problem` (today `public private(set)`, set to nil at `Machine.swift:232`). |
| 19 | ProjectSetup → Insights: `apply` appends a spool line with `Spool.append`, `Spool.lineVersion` and `Spool.milliseconds` (`ProjectSetup.swift:419, 439–441`). | No code change. `AKitProjectSetup` depends on `AKitInsights`, which sits below it; nothing in Insights calls `plan` or `apply`. |
| 20 | Insights → CLI: `Recommender` calls `AKitCLI.unifiedDiff` (`Recommender.swift:585`). | Move it to `TextDiff.unified(_:)` in `AKitFoundation`. The CLI's six callers use it too. |
| 21 | Insights and Brain → ProjectSetup storage: `ProjectSetup.projectID`, `homeID`, `localID`, `normalizedRemote` (`ProjectBinding.swift:83–160, 509`, `RecordSession.swift:116`, `InsightsStats.swift:393`, `Machine.swift:246,248`); `sha256` (`Recommender.swift:650`, `ProjectBinding.swift:413`, `BrainLinks.swift:44`, `Machine.swift:217`); `savedLock` and `Lock` (`Brain.swift:106`, `BrainLinks.swift:28`, `ProjectSkills.swift:31,39`). | New `enum ProjectRecords` in `Brain/ProjectRecords.swift` takes `Lock` (+ `Entry`), `homeID`, `projectID`, `localID`, `normalizedRemote` (+ `cleanPath`), `savedAnswers(id:in:)`, `savedLock` and `save` with the same signatures. Callers change only the prefix. `sha256` becomes `Checksum.sha256` in `AKitFoundation`. |
| 22 | `Render.skillsFolder` (`.agents/skills`) and `Render.projectSource` are used outside the render: `BrainLinks.swift:25`, `ProjectSkills.swift:20–98`, `Recommender.swift:635`, `ProjectSetup`, the app (`BrainView.swift:567,611`, `NewProjectSkillSheet.swift:38`) and tests. | Move both to `AKitBrain`, next to `ProjectBundle` (for example `ProjectBundle.skillsFolder`). They are part of the seam contract: lock paths, brain links, project skills and recommendations all read `.agents/skills`. |
| 23 | Insights → concrete adapters: `ClaudeCodeAdapter().configRoot` (`SessionImporter.swift:164`), `PiAdapter().configRoot` (`SessionImporter.swift:176`, `CaptureInstaller.swift:95,260`) and `PiAdapter().skillRoots` (`PiFacts.swift:147`). | New `HarnessCatalog.configRoot(of: HarnessID, in:)` and `HarnessCatalog.adapter(for: HarnessID)` in `AKitHarnesses`; Insights calls those. They return the same paths as today, also when the harness isn't installed. |
| 24 | Insights and Usage → Sessions internals: `ClaudeSessions.isSidechain`, `.promptText`, `.tag`, `.tokens(fromClaudeUsage:)` (`ClaudeFacts.swift:48–121`); `PiSessions.skillPrefixName`, `.promptTitle`, `.tokens(fromPiUsage:)`, `.cost(fromPiUsage:)` (`PiFacts.swift:51–82`) and `.folder(configRoot:in:)` (`SessionImporter.swift:176`). Usage's extensions call `tokens(fromClaudeUsage:)` (`HarnessUsage.swift:157`) and `tokens`/`cost(fromPiUsage:)` (`HarnessUsage.swift:239`). | Move these functions into two public enums in `Sessions/`: `ClaudeLogFormat` and `PiLogFormat`. `ClaudeSessions`/`PiSessions` call them and stay internal. Usage and Insights import `AKitSessions`. |
| 25 | Insights uses Brain internals: `LayerManifest.parse` (`LayerPatch.swift:118`), `Brain.requiredClosure` (`LayerHistory.swift:42`), `BrainRemove.savedAnswers` (`Recommender.swift:486–488`), `ProjectStore.savedFile` (`Dismissals.swift:48,99`), `MachineProfile.displayName(hostName:)` (`Recommender.swift:461`). | Not a cycle. Mark them public when Brain is extracted (section 3). The compiler lists any property still missing. |
| 26 | The CLI uses about 30 Insights types and members (`AKitCLI.swift:252–254`, `457–1004`, `1296`). All are internal today except `CommandRunner` and `RecordSession`. | They become public in `AKitInsights` (section 3). The CLI's text formatters (`statsText`, `recommendText`, …) stay in the CLI. |
| 27 | `SQLite3` is now imported by `Usage/HarnessUsage.swift` (OpenCode's database), `Insights/IndexDatabase.swift` (the index) and `UsageTests`. | Not a coupling. Each target imports the system module itself; `Package.swift` needs no setting (it has none today). |
| 28 | Tests cross modules upwards: `AKitCLI.run` or its text formatters in `BeforeAfterTests`, `CaptureTests`, `InsightsStatsTests`, `RecommenderTests`, `UsageSummaryTests`, `BrainRemoveTests`, `BrainSyncTests`, `OnboardingTests`; `ProjectSetup.plan`/`apply` in `CaptureTests` and `BrainRemoveTests`; `SkillScannerTests.swift:351` checks `PiSkillPaths` (Insights). | Test targets may depend on higher modules (section 5). Move the `PiSkillPaths` line into `InsightsImportTests`. |

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
| Foundation | `HarnessEnvironment` (`.current`, `expand`, `findExecutable`, `pathForChildProcesses`, `homeDirectory`), `ProcessRunner.run` (also `SelfRebuild.swift`), `SecretFilter.masked`, `KeychainSecretStore` (+ `.service`), `TextDiff.lines`/`.Line`/new `.unified`, `VersionProbe.version`, `Backup` (`MCPServerEditor.swift:301`, CLI) | Only other modules use these, so they are public for modules and not for UI: `Frontmatter`, `ConfigText`, `MiniTOML`, `JSONLines`, `FileWalk`, `Trash`, `Checksum`, `SecretStore`. `MemorySecretStore` is only for tests. |
| Model | `HarnessID`, `HarnessInstallation`, `ConfigLocation`, `SkillScope`, `InstallScope`, `TokenCounts` | Everything is public vocabulary; keep it small. |
| Harnesses | `HarnessCatalog.adapters` / `.allAdapters(custom:)` / `.detectAll`, `HarnessAdapter` (only `id`, `displayName`, and the protocol type for `adapters:` parameters), `CustomHarness` (+ `.slug`), `CustomHarnessStore.load/update/url`, `ProjectFinder.defaultRoots/projects`; for Insights: new `HarnessCatalog.configRoot(of:in:)`, `.adapter(for:)` | `ClaudeCodeAdapter`, `PiAdapter`, `CodexAdapter`, `OpenCodeAdapter`, `CustomHarnessAdapter` (reached only through `HarnessCatalog`) |
| Skills | `Skill`, `SkillScanner.scan/projects`, `SkillFiles.list/text`, `SkillRemover.moveToTrash/removesOnlyLink`, `PiNameRule.problems`, `InstalledSkillLock.load/forget/publishedOrigin` | `SkillScanner` walking internals, `SkillLock` (public only for Brain) |
| SkillsSh | `SkillsShClient.search/base/minimumQueryLength`, `RemoteSkill`, `RemoteSkillFetcher.fetch`, `FetchedSkill`, `SkillInstaller.targets/install/conflicts/blockedConflicts/nameProblems`, `InstallRequest`, `InstallTarget` | `SkillLocator`, `SkillText`, `SkillCopier` |
| Sessions | `SessionScanner.scan`, `SessionSummary`, `SessionTranscript`, `TranscriptItem`, `SessionUsage`, `PromptSnapshot`, `SessionExport.json/markdown/usageMarkdown`, `SystemPromptAccess`; new `SessionReader`, `PromptReader`; for Usage and Insights: new `ClaudeLogFormat`, `PiLogFormat` | `ClaudeSessions`, `PiSessions`, `PiPromptProbe`, `TranscriptBuilder`, `UsageCounter` |
| Usage | `UsageScanner.scan/scanLimits`, `UsageRecord`, `LimitSample`, `DailyUsageReport`, `UsageTotal`, `Subscription`, `SubscriptionLimitReport` | `ClaudeUsage`, `PiUsage`, `CodexUsage`, `OpenCodeUsage`, `ClaudeCostRates` |
| MCP | `MCPScanner.scan`, `MCPServer`, `MCPSetting`, `MCPState`, `MCPDraft` (+ `parse`, `editing`, `split/joinArguments`, `.Transport`, `.Value`), `MCPSecretMode`, `MCPWriter.targets/target/plan/removalPlan/apply/rawEntry/sourceLine/storeSecret/isEnvFileSourced`, `MCPWriter.Outcome`, `MCPWritePlan`, `MCPWriteTarget` | `MCPReader`, `MCPValues`, `MCPScanResult` internals |
| Brain | `Brain` (+ `.load`, `.defaultRoot`, `.Skill`, `.Project`), `Layer`, `LayerField`, `LayerSkill` (+ `.Mode`), `Condition`, `FieldValue`, `ProjectAnswers` (+ `.knownTargets`, new `target(for:)`), `BrainImport.plan/apply/layerAfter/defaultSource/Plan/Candidate`, `BrainRemove.*` (`layerImpact`, `skillUsers`, `removeLayer`, `skillProjects`, `removeSkill`, `layerWithoutSkill`, `forgetProject`), `BrainSetup.create`, `BrainSync.status/sync/Status/Outcome`, `LayerWriter.create/nameProblem/Draft`, `LayerEditor.Details/agentsFile/details/requirable/addSkills/setMode/update/oneLine`, `BrainLink`, `BrainLinks.links`, `MachineProfile` (`load`, `save`, `Kind`, `OwnKeys`, `currentHardwareHash`, `isWork`, `problem`), `ProjectStore` (`current`, `brain`, `local`, `folder`, `describe`), `ProjectRecords.projectID/homeID/savedAnswers/Lock`; new `ProjectBundle` (+ `skillsFolder`, `projectSource`), `RenderedFile`, `RenderResult`, `resolve`. For Insights also: `LayerManifest.parse`, `Brain.requiredClosure`, `BrainRemove.savedAnswers`, `ProjectStore.savedFile`, `MachineProfile.displayName(hostName:)`, `.identify`, `ProjectRecords.localID/normalizedRemote/savedLock`, `CapturePlugin`, `BrainGit` | `AKitSkill`, `BrainImport.copyable`, `BrainImport.addSkills`, `LayerEditor`'s text helpers (`block`, `skillItem`, `addingSkills`, …; `BrainRemove` and `BrainImport` use them inside Brain) |
| Insights | app: `MachineProfile.change` (the extension). `akit`: `RecordSession.main`. CLI: `RecordSession.run/harness`, `CommandRunner`, `IndexSchema.open` + `IndexDatabase`, `InsightsPaths` (`database`, `lock`, `spool`), `ImportLock.acquire`, `QuickImport.run`, `SessionImporter.importAndBind`, `ImportReport`, `InsightsStats.inputs/report/defaultDays/defaultTop`, `StatsReport`, `IndexQueries.debugStats/debugNotes/bindingStats/BindingStats/SessionDebug`, `BindingMethod`, `BindingSet.parse`, `Confidence`, `ProjectBinder.pathTemplates`, `BeforeAfter.changes/date/window`, `ChangesReport`, `ContextCalibration.calibration/save/summary`, `ContextSize.minimumPairs/short`, `Spool.append/lineVersion/milliseconds` (also for ProjectSetup), `CaptureInstaller` (init, `status`, `installPlan`, `uninstallPlan`, `execute`, `.Plan`, `.Status`, `.Part`), `Recommender.inputs/recommend/scoped/wholePlugin/knownProjects/defaultTop/Options`, `RecommendReport`, `SkillOwner.Kind`, `Dismissals.dismiss/showsAgainAt/Entry`, `LayerPatch.edit/commit/path/Change`, `SummaryPublisher.publish/Outcome` | The fact readers (`ClaudeFacts`, `PiFacts`, `SpoolFacts`, `Fact*`), `IndexDatabase` SQL helpers, `WorkFilter`, `UsageSummary`, `LayerHistory`, `DescriptionWindow`, `SkillOwners`, the binding resolvers |
| Render | one function: `Render.render(_ bundle: ProjectBundle, forHome:) -> RenderResult` | `substitute`, `manualOnly`, `matches` |
| ProjectSetup | `ProjectSetup.plan/apply`, `.Plan`, `.Change` (+ `.Kind`), `.Outcome`, `.Failure`; `ProjectSkills.list/create/remove/nameProblem/folder/Skill` | lock entries, `escapes`, `state`, `applyEvent`, `isProjectOwned`, `ProjectSkills.names` |
| CommandLine | `AKitCLI.run`, `Onboarding.Preferences` | the rest |

Structs built in one module and used in another need an explicit `public init`,
because Swift's automatic init is internal. This is the most common build error
while moving files.

### Where the UI depends on implementation details (fix before or during the split)

1. **Sessions through adapters**: `AppModel.swift:395–450` calls
   `adapter.transcript`, `systemPromptAccess`, `recordedPrompt` and
   `capturePrompt`. After fix 1 it calls `SessionReader` / `PromptReader`
   from `AKitSessions`. The UI then no longer needs the adapter for anything
   but names, ids and install targets.
2. **MCP writes via the Claude CLI are coded in the UI**: `AppModel.applyMCP`
   (`AppModel.swift:372–393`) builds the closure that runs `claude mcp …` with
   `ProcessRunner` and `SecretFilter`. Move it into `AKitMCP`
   (`MCPWriter.apply(plan, claude: installation, secrets:, home:, env:)`). Otherwise a
   replacement MCP module would leave dead process code in the app.
3. **The project form calls Render directly**: `ProjectSetupSheet.swift:59–62`
   calls `Render.render` for live form errors, and `:160–164` renders the layers
   alone to see which skills they bring. It should call `AKitBrain`'s `resolve`,
   which reports missing fields, unknown layers and conflicts and lists the
   skills (name, mode, source), or `ProjectSetup.plan`. Then only
   `AKitProjectSetup` calls the render module, and a rulesync swap touches one call site.
4. **`ProjectSetup.Plan.render: Render.Result`** is shown in the sheet. Keep it,
   but typed with the seam's `RenderResult` from `AKitBrain` (section 4), not a
   type owned by the render module. `ProjectSetup.plan` builds a new result
   after its own steps (`ProjectSetup.swift:207`), so `RenderResult` needs a public init.
5. **Target names** (fix 15).
6. **`Render.skillsFolder` in screens** (`BrainView.swift:567,611`,
   `NewProjectSkillSheet.swift:38`): after fix 22 it comes from `AKitBrain`.
7. **Settings changes this Mac's kind** through `MachineProfile.change`
   (`AppModel.swift:82`). After fix 18 that is `AKitInsights`, so the app imports it.
   The app has its own private `UsageSummary` view (`UsageView.swift:284`); keep
   Insights' `UsageSummary` internal (the CLI doesn't need it) so the names never meet.

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
| Insights | None known. Replacing it also means dropping the one spool line `ProjectSetup.apply` writes. |
| **Render** | **rulesync** (dyoshikawa/rulesync). Confirmed. |
| ProjectSetup | None. It holds AKit's safety rules (diff first, backup, Trash, lock) and the project's own skills. Keep it. |
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
filling, `when` conditions, `requires`/`conflicts`, answers (including the
project's own picks of brain skills, `answers.skills`), the project form and the
brain screens. rulesync does not ask per-project questions, so those stay AKit's.

Data going **into** the seam: `ProjectBundle`, defined in `AKitBrain`:

- `projectName`, `targets` (`claude`, `pi`, `opencode`, `codex`), `forHome`
- `layers`: resolved order (required first, then the user's selection order)
- `instructions`: `[(layer, to: "AGENTS.md", text)]`, Markdown fragments with fields already filled in
- `files`: `[(layer, to, data, override)]`, other template outputs with fields filled in
- `skills`: `[(name, mode: auto|manual, source, files: [relativePath: Data])]` with fields filled in the `.md` files; `source` is a layer name or `projectSource` ("this project")
- `errors` / `warnings` from resolving (missing required field, unknown layer, clash)
- the constants `skillsFolder` (`.agents/skills`) and `projectSource`

Data coming **out**: `RenderResult`, also defined in `AKitBrain`, so a
replacement module needs nothing from the old one:

- `outputs: [RenderedFile]`, each with `path` (relative to the project),
  `content` (`.data` or `.link(destination)`) and `layers`
- `layers` (render order) and `skills` (name, mode, source): the project form
  and the spool's `apply` line use them
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

Since the first version, `ProjectSetup.plan` does more after the render: the
project's own skills in `.agents/skills` win over the brain's copy, they get a
`.claude/skills` link when Claude is a target, and template files the project
edited become its own (only offered again). These stay in `ProjectSetup`,
because they read the project. They assume skills land in `skillsFolder`, and so
do `BrainLinks`, `ProjectSkills` and `akit recommend`. A replacement renderer must
put skills there too (see open questions).

## 5. Migration steps

Each step is one commit. `make build` and `make test` must pass after each one
(run `swift test` under the memory guard as usual), and a UI check is needed
only where a screen's code changes. No behavior changes anywhere.

**Phase A: untangle inside the single target** (no new modules yet; files move
between folders, nothing is renamed publicly except where a step says so). This
removes every cycle, so phase B is only moving files.

1. Refresh this plan against master `fb4f1d5` (this document). The first
   version was added in `7e3f4aa`.
2. Toolbox moves: `FileWalk`, `Trash`, `Checksum` (replaces both
   `ProjectSetup.sha256` and `JSONLines.hash`) and `TextDiff.unified` (from `AKitCLI.unifiedDiff`)
   into `Support/`; `ConfigText.swift`, `JSONLines.swift` into `Support/`;
   `FileProbe.swift` and `ProjectFinder.swift` into `Adapters/`. Update callers,
   including Insights and the CLI (fixes 4–8, 20).
3. Vocabulary moves: `MCPSource` + `MCPApproval`, `InstallScope`, `TokenCounts`
   into `Model/`; `InstalledSkillLock` into `Skills/`; the Claude-state flag on
   `MCPSource` replaces `ClaudeCodeAdapter()` in `MCPWriter` (fixes 3, 9–12).
4. Sessions out of the adapters: `SessionScanner.scan(installations:)`,
   `SessionReader`, `PromptReader` + `SystemPromptAccess` in `Sessions/`;
   `ClaudeLogFormat`/`PiLogFormat` in `Sessions/`, used by `ClaudeSessions`,
   `PiSessions`, Usage's extensions and Insights (`ClaudeFacts`, `PiFacts`,
   `SessionImporter`); remove the five session/prompt methods from
   `HarnessAdapter`; update `AppModel` and tests. UI check: Sessions screen and
   prompt view (fix 1, part 1, and fix 24).
5. Usage out of the adapters: `ClaudeUsage`/`PiUsage` enums, `UsageScanner`
   dispatches on `HarnessID`; remove `usage`/`limits` from `HarnessAdapter`.
   UI check: Usage screen (fixes 1, part 2, and 2).
6. Adapter lookups: `HarnessCatalog.configRoot(of:in:)` and `.adapter(for:)`
   replace `ClaudeCodeAdapter()` and `PiAdapter()` in Insights (fix 23). Both
   return nil for custom harnesses. After this step only `Adapters/` and
   `Custom/CustomHarness.swift` (which defines `CustomHarnessAdapter`) name the
   concrete adapters, besides the tests that check them directly
   (`DetectionTests`, `CustomHarnessTests`, `SkillScannerTests`).
7. MCP Claude-CLI runner moves from `AppModel.applyMCP` into `MCPWriter`.
   UI check: MCP editor save.
8. Project records: new `Brain/ProjectRecords.swift` takes `Lock`, the id
   functions and the saved answers/locks from `ProjectSetup` (fix 21). Callers
   in the app, the CLI, Brain, Insights and tests change only the prefix
   (`ProjectSetup.homeID` → `ProjectRecords.homeID`, …). UI check: Brain →
   Set Up Project….
9. Brain seam: add `ProjectBundle`/`RenderedFile`/`RenderResult` and
   `resolve` in `Brain/`; `skillsFolder` and `projectSource` move onto
   `ProjectBundle`; `Render.render` takes a bundle; `ProjectSetupSheet` uses
   `resolve`; one target-name function (fixes 14, 15, 22). `RenderTests` and
   `ProjectSetupTests` must pass unchanged in what they check. UI check: Brain →
   Set Up Project… and the project page's skills.
10. Brain stops calling Insights: `Brain/CapturePlugin.swift`,
    `Brain/BrainGit.swift`, and `MachineProfile.change` moves into
    `Insights/MachineChange.swift` (fixes 16–18). `CaptureTests`,
    `BrainSyncTests` and `UsageSummaryTests` must pass unchanged. UI check:
    Settings → this Mac (work/personal).
11. Move `Onboarding.swift` into `CLI/`.

**Phase B: extract modules bottom-up** (a module can only depend on modules
already extracted). Each step: add the target and its test target to
`Package.swift`, `git mv` the files into `Sources/<Module>/`, mark as `public`
only what other modules use (section 3), add `@_exported import <Module>` to
the umbrella, move the module's tests to `Tests/<Module>Tests/` with
`@testable import <Module>`, and add `@testable import` lines where a test
touches internals of two modules.

Test targets may depend on modules above their own (fix 28). While a higher
module is still inside the umbrella, the test target depends on `AKitCore` as
well, so tests that drive `AKitCLI.run` or `ProjectSetup.apply` keep compiling.
Phase C replaces that with the real modules.

12. `AKitFoundation` (ProcessRunnerTests, SecretFilterTests; move `FrontmatterTests`
    out of `SkillScannerTests.swift` into its own file here)
13. `AKitModel`
14. `AKitHarnesses` (DetectionTests.swift incl. VersionProbeTests, CustomHarnessTests)
15. `AKitSkills` (SkillScannerTests.swift incl. SkillRemoverTests, MoreHarnessTests;
    first move the `PiSkillPaths` line at `SkillScannerTests.swift:351` into
    `InsightsImportTests`)
16. `AKitSkillsSh` (SkillsShTests)
17. `AKitSessions` (SessionTests)
18. `AKitUsage`; depends on `AKitSessions`; the `SQLite3` import moves with
    `HarnessUsage.swift` (UsageTests)
19. `AKitMCP` (MCPTests, MCPWriterTests incl. ArgumentLineTests)
20. `AKitBrain`; the Yams dependency moves from the umbrella to this target
    (BrainTests.swift incl. BrainSetupTests, BrainImportTests, BrainLinksTests,
    BrainRemoveTests, BrainSyncTests, LayerEditorTests, LayerWriterTests)
21. `AKitInsights`; `IndexDatabase.swift` keeps its `SQLite3` import
    (BeforeAfterTests, CaptureTests, InsightsImportTests, InsightsStatsTests,
    ProjectBindingTests, RecommenderTests, UsageSummaryTests)
22. `AKitRender` (RenderTests)
23. `AKitProjectSetup`; depends on `AKitInsights` for `Spool` (ProjectSetupTests)
24. `AKitCommandLine`; the `akit` executable depends on it (AKitCLITests,
    OnboardingTests)

**Phase C: remove the umbrella**

25. The app imports the specific modules; `project.yml` lists one `product:`
    per module; delete the `AKitCore` target and product; each test target
    lists the modules it touches instead of `AKitCore` (from today's tests:
    Brain tests also need Render, ProjectSetup and CommandLine; Insights tests
    also need Harnesses, Skills, Sessions, Brain, ProjectSetup and CommandLine;
    Skills, SkillsSh, Sessions, Usage and MCP tests also need Harnesses); update the
    "Logic lives in the AKitCore Swift package" lines in `CLAUDE.md` and
    `README.md` to point at this document. `make install-cli`, `make release`,
    `install.sh` and `tools/demo-home.sh` stay unchanged because the package
    folder (`AKitCore/`) and the `akit` product keep their names.
    UI check: every section.

That is 25 steps, 24 of them after this refresh. Merge to master once at the
end. Phase A can be merged on its own if it takes long.

## 6. Risks and open questions

Risks:

- **`public` grows.** Helpers that were `internal` (FileWalk, ConfigText,
  JSONLines, Backup, Checksum) become public for other modules. They are toolbox
  APIs, not UI APIs. `AKitInsights` grows the most: about 30 types and members
  for the CLI (section 3). Review them in step 25.
- **Phase A steps 4–5 change the adapter protocol.** They are the only real
  refactor. Tests already cover detection, sessions and usage with a fake home,
  so regressions should show up there. Step 4 also touches the Insights fact
  readers; `InsightsImportTests` covers them.
- **Step 8 is wide.** About 70 call sites (67 today, outside `ProjectSetup.swift`)
  change their prefix, in the app, the CLI, Brain, Insights and tests. It is mechanical, but it touches many files at once.
- **Step 10 moves `MachineProfile.change` across a module line.** It sets
  `problem` (private setter) and calls `identify` (internal), so Brain needs a
  public way to do both. `UsageSummaryTests` covers the behavior.
- **`skillsFolder` is part of the seam.** Lock paths, `BrainLinks`,
  `ProjectSkills`, `ProjectSetup`'s own-skill rules and `akit recommend` all read
  `.agents/skills`. A replacement renderer that puts skills anywhere else breaks them.
- **Insights tests build the CLI.** Five Insights test files and three Brain
  test files call `AKitCLI.run` or its formatters, so their targets depend on
  `AKitCommandLine`. Running one module's tests builds more than that module.
- **More modules make clean builds a little slower** and incremental builds
  faster. No effect on the release zip.

Decided (2026-09-28):

1. One package with one library target per module (13 after this refresh), not
   a package per module.
2. Adapters shrink to "where things are"; reading sessions and usage moves
   into the Sessions and Usage modules.
3. The package folder stays `AKitCore/`.
4. Done 2026-09-29: the split waited until `session-insights` and
   `skills-layer-add-button` were merged, and this plan is refreshed against
   master `fb4f1d5`. `AKitInsights` sits between `AKitBrain` and
   `AKitProjectSetup`; `LayerEditor`, `Machine` (without `change`) and
   `BrainLinks` go to `AKitBrain`; `ProjectSkills` goes to `AKitProjectSetup`;
   the new CLI commands (`sessions`, `stats`, `insights`, `recommend`, `sync`'s
   publish) stay in `AKitCommandLine` and use `AKitInsights`' public API.
   Couplings 16–28 are new.

Still open:

- rulesync at runtime needs its binary or Node on each Mac. Is that
  acceptable, or should AKit's own renderer stay the default with rulesync
  optional? Also to check against the rulesync docs: exact target ids for
  Claude Code, Codex, OpenCode and Pi (Pi appears in its tool list); whether
  it supports manual-only skills (`disable-model-invocation`); how it
  glues several rule files into one `AGENTS.md`; and whether it can write
  skills into `.agents/skills` (see the `skillsFolder` risk).
- `ProjectSetup → Insights` for the spool line (fix 19) is the simplest cut.
  The alternative is that `apply` returns the event and the app and CLI append
  it (three call sites). Keep the dependency unless Insights is ever replaced.
- `MachineProfile.change` in Insights (fix 18) keeps all call sites unchanged.
  The alternative is to keep it in Brain and pass in the own keys and the
  published summary files; that moves Insights calls into the app and CLI instead.
