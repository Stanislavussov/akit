import AKitBrain
import AKitFoundation
import AKitKnowledge
import Foundation

/// `akit kb`: the knowledge base (docs/design/knowledge.md). Agents run the read commands; the
/// person-only ones (U1, K22) are marked so in the help, and an agent runs them only when the user
/// asked for that action in the session.
extension AKitCLI {
    static let knowledgeUsage = """
    akit kb: the knowledge base, notes and maps of the systems around a repository
    (docs/design/knowledge.md). A base is a folder per world (by default
    ~/.akit/local/knowledge/<world>; akit kb path sets another, like one in an Obsidian vault),
    a local git repo that never has a remote: areas/<area>/ holds notes (Markdown) and maps.

    Read (agents may run these):
      akit kb areas [--json] [--base PATH|WORLD]
                                        The areas with their note and map counts
      akit kb notes [AREA] [--json] [--base PATH|WORLD]
                                        The notes (of one area): id, kind and title. An id is the
                                        path under areas/ without .md, like payments/orders-api
      akit kb kinds [--json] [--base PATH|WORLD]
                                        The kinds of notes and the fields of each, from kb.yaml in
                                        the base (the defaults when it has none)
      akit kb area AREA [--json] [--base PATH|WORLD]
                                        An area's settings from areas/AREA/area.yaml: title,
                                        description, projects (git remotes, ~/ paths, globs)
      akit kb maps [AREA] [--json] [--base PATH|WORLD]
                                        The maps (.excalidraw) of an area or of all: blocks (shapes
                                        linked to a note), arrows between them, unbound arrows, and
                                        the maps each one links to
      akit kb relations NOTE [--json] [--base PATH|WORLD]
                                        The arrows to and from a note on every map: from, kind (the
                                        arrow's label), to, flow (the note the arrow links), map
      akit kb search QUERY [--area A] [--limit 10] [--max-tokens N] [--json] [--base PATH|WORLD]
                                        The best sections of notes with every word of QUERY (BM25:
                                        a lower score is better): note, heading, snippet and the
                                        notes one arrow away on a map. Only areas/, never inbox/
      akit kb show NOTE [--section H] [--max-tokens N] [--json] [--base PATH|WORLD]
                                        A note: title, kind, repo, files and its sections (only H
                                        with --section), cut to --max-tokens (default 4000)
      akit kb index [--rebuild] [--json] [--base PATH|WORLD]
                                        Bring the search index (.akit-index.sqlite in the base,
                                        git-ignored) up to the files, or build it again. search
                                        does it itself; "stale": true means another process holds
                                        the index and the answer comes from its last state
      akit kb neighbors NOTE [--depth 1|2] [--max-tokens N] [--json] [--base PATH|WORLD]
                                        The arrows to and from a note on every map, from the index
                                        (with --depth 2 also those of the notes one arrow away)
      akit kb context [FOLDER] [--max-tokens N] [--json] [--base PATH|WORLD]
                                        The card to read at the start of a task about systems:
                                        the project's focus area (FOLDER, default the current one),
                                        its notes with a title and one line, the arrows touching
                                        them and their neighbours in other areas; at most 4000
                                        tokens unless --max-tokens
      akit kb focus [FOLDER] [--json] [--base PATH|WORLD]
                                        The focus area of a project and why: the choice in
                                        focus.json, an area.yaml that names its remote or folder,
                                        or a note whose repo: is its remote
      akit kb lint [--json] [--base PATH|WORLD]
                                        Check the base: broken and ambiguous links, map blocks with
                                        no note, unbound arrows, maps that don't parse (errors and
                                        warnings), repo: not among the known projects, files: and
                                        ~/ paths that don't exist; hints for a kind not in kb.yaml
                                        and a block of an unrelated area. --json: {base, findings:
                                        [{rule, severity, file, element, link, message, fix}], counts}

    Write (for a person only: an agent runs these only when the user asked for that action in
    this session; otherwise it proposes or asks):
      akit kb init [--world NAME | --base PATH]
                                        For a person only. Create a base: areas/, inbox/, .gitignore,
                                        git without a remote, a first commit, in the world's folder
                                        (see kb path). NAME defaults to this Mac's kind (work or
                                        personal). Refused inside the brain, in a synced folder
                                        (iCloud Drive, Dropbox, Google Drive), in a repo with a remote
      akit kb path [WORLD] [--set PATH | --move PATH | --reset] [--json]
                                        For a person only. Shows where the base of WORLD (default:
                                        this Mac's kind) lives, kept on this Mac in
                                        ~/.akit/local/knowledge/bases.json. --set makes PATH the base
                                        (an empty folder, an Obsidian vault or a base already; the old
                                        one stays as it is); --move commits the pending edits, then
                                        moves the base there; --reset goes back to the default folder
      akit kb new-note AREA NAME [--kind K] [--base PATH|WORLD]
                                        For a person only. Create areas/AREA/NAME.md (# NAME, and
                                        kind: K in the frontmatter) and commit it at once
      akit kb new-map AREA NAME [--base PATH|WORLD]
                                        For a person only. Create areas/AREA/maps/NAME.excalidraw
                                        (an empty map) and commit it at once
      akit kb set NOTE KEY=VALUE… [--unset KEY]… [--json] [--base PATH|WORLD]
                                        For a person only. Set or remove frontmatter properties of a
                                        note (kind=flow, owner=team-a, files=[a.ts, b.ts]), one line
                                        each, every other byte kept, and commit it at once
      akit kb kinds add NAME [--fields a,b] | fields NAME a,b | remove NAME | rename OLD NEW
                                        For a person only. Change the kinds in kb.yaml and commit at
                                        once. rename also rewrites kind: in every note of that
                                        kind, all or nothing, in one commit. remove leaves notes as
                                        they are (their kind is then unknown)
      akit kb area AREA [--title T] [--description D] [--project P]… [--remove-project P]…
                                        For a person only. Change areas/AREA/area.yaml and commit it
                                        at once. P is a git remote, a ~/ path or a glob
      akit kb focus [FOLDER] --set AREA | --clear [--json] [--base PATH|WORLD]
                                        For a person only. Choose the area a project's sessions
                                        start from (kept on this Mac in
                                        ~/.akit/local/knowledge/focus.json, not in the base), or
                                        clear the choice to go back to area.yaml and repo:
      akit kb rename NOTE|MAP NEW [--yes] [--json] [--base PATH|WORLD]
                                        For a person only. Rename a note or a map (NEW: a name in the
                                        same folder, or for a note area/name) and rewrite every link
                                        to it in notes and maps, keeping aliases and #headings. All
                                        or nothing: refused, with the planned diff, when another link
                                        would change its target or a map wouldn't parse. Pending
                                        edits are committed first, then the rename in one commit.
                                        Without --yes it only shows the plan
      akit kb rm NOTE|MAP|AREA [--yes] [--json] [--base PATH|WORLD]
                                        For a person only. Move a note, a map or a whole area to
                                        the Trash and commit the removal at once. Without --yes it
                                        only shows what would go. Proposals in inbox/ are rejected,
                                        not removed
      akit kb seed [--world NAME] [--json]
                                        For a person only. Write the sample base: a separate base
                                        (world sample unless named) with made-up notes that show
                                        every feature, committed. Run again, it updates an older
                                        sample base that has no changes of yours
      akit kb seed --remove [--world NAME | --base PATH|WORLD] [--yes] [--json]
                                        For a person only. Move the whole sample base to the Trash.
                                        Refused for a base that is not a sample one (no
                                        .akit-seed.json). Without --yes it only shows what would go

    Which base (--base, else in this order): the current project's entry in
    ~/.akit/local/knowledge/focus.json, the only base, the base named like this Mac's kind. With
    no base, the read commands say so (--json: {"base": null, "reason": "no base"}) and exit 0.
    The read commands also read --base PATH when PATH has areas/ but no git; changes need git.
    """

    static func knowledge(_ arguments: [String], env: HarnessEnvironment, cwd: URL, projectsRoot: URL,
                          out: (String) -> Void, trash: (URL) throws -> URL? = Trash.move) async throws -> Int32 {
        var args = Arguments(arguments)
        if args.flag("--help") || args.flag("-h") || args.isEmpty {
            out(knowledgeUsage)
            return 0
        }
        let json = args.flag("--json")
        let baseOption = args.value("--base")
        let command = args.positional()
        func chosen() async throws -> KnowledgeBase? {
            do {
                // Reads take a folder with areas/ and no git too (test fixtures); `writable` needs git.
                return try await KnowledgeBase.choose(option: baseOption, folder: cwd, env: env, projectsRoot: projectsRoot, forReading: true)
            } catch {
                throw Failure(message: error.message)
            }
        }
        switch command {
        case "areas", "notes":
            let area = command == "notes" ? args.positional() : nil
            try args.finish()
            guard let base = try await chosen() else {
                out(json ? encode(NoBase()) : "No knowledge base on this Mac (a person creates one with akit kb init).")
                return 0
            }
            if command == "areas" {
                let areas = base.areas()
                if json {
                    out(encode(AreasAnswer(base: base.root.path, areas: areas)))
                } else {
                    out(areas.isEmpty ? "No areas in \(FileWalk.tilde(base.root, home: env.homeDirectory)) yet."
                        : areas.map { area in
                            "\(area.name)  \(count(area.notes, "note")), \(count(area.maps, "map"))" + (area.title.map { "  \($0)" } ?? "")
                        }.joined(separator: "\n"))
                }
                return 0
            }
            let notes: [KnowledgeBase.NoteEntry]
            do { notes = try base.notes(area: area) } catch { throw Failure(message: error.message) }
            if json {
                out(encode(NotesAnswer(base: base.root.path, area: area, notes: notes)))
            } else {
                out(notes.isEmpty ? "No notes\(area.map { " in \($0)" } ?? "") yet."
                    : notes.map { [$0.id, $0.kind ?? "-", $0.title].joined(separator: "  ") }.joined(separator: "\n"))
            }
            return 0
        case "init":
            let world = args.value("--world")
            let brain = args.value("--brain").map { resolve($0, cwd: cwd, env: env) }
            try args.finish()
            if json { throw Failure(message: "--json doesn't go with akit kb init.") }
            if world != nil, baseOption != nil { throw Failure(message: "Use --world NAME or --base PATH, not both.") }
            let base: KnowledgeBase
            do {
                if let baseOption {
                    base = try await KnowledgeBase.create(at: resolve(baseOption, cwd: cwd, env: env), env: env, brainRoot: brain)
                } else {
                    let name = world ?? MachineProfile.load(home: env.homeDirectory).kind.rawValue
                    base = try await KnowledgeBase.create(world: name, env: env, brainRoot: brain)
                }
            } catch {
                throw Failure(message: error.message)
            }
            out("""
                Created the knowledge base \(FileWalk.tilde(base.root, home: env.homeDirectory)): areas/, inbox/, git without a remote, committed.
                Add a note: akit kb new-note AREA NAME [--kind K]
                """)
            return 0
        case "new-note":
            let kind = args.value("--kind")
            guard let area = args.positional(), let name = args.positional() else {
                throw Failure(message: "Use: akit kb new-note AREA NAME [--kind K] [--base PATH|WORLD]")
            }
            try args.finish()
            if json { throw Failure(message: "--json doesn't go with akit kb new-note.") }
            let base = try await writable(chosen)
            let path: String
            do { path = try await base.newNote(area: area, name: name, kind: kind, env: env) } catch { throw Failure(message: error.message) }
            out("Created \(FileWalk.tilde(base.root.appending(path: path), home: env.homeDirectory)), committed.")
            return 0
        case "lint":
            let brain = args.value("--brain").map { resolve($0, cwd: cwd, env: env) } ?? Brain.defaultRoot(home: env.homeDirectory)
            try args.finish()
            guard let base = try await chosen() else {
                out(json ? encode(NoBase()) : "No knowledge base on this Mac (a person creates one with akit kb init).")
                return 0
            }
            let projects = KnowledgeLint.Projects.find(home: env.homeDirectory, projectsRoot: projectsRoot, brainRoot: brain)
            let findings = KnowledgeLint.run(base, projects: projects, home: env.homeDirectory)
            if json {
                out(encode(KnowledgeLint.Answer(base: base.root.path, findings: findings)))
            } else if findings.isEmpty {
                out("No findings in \(FileWalk.tilde(base.root, home: env.homeDirectory)).")
            } else {
                let counts = KnowledgeLint.counts(findings)
                out(findings.map { finding in
                    "\(finding.severity.rawValue)  \(finding.rule.rawValue)  \(finding.file)" + (finding.element.map { "  \($0)" } ?? "")
                        + "\n    \(finding.message)" + (finding.fix.map { "\n    fix: \($0)" } ?? "")
                }.joined(separator: "\n") + "\n\(count(counts.error, "error")), \(count(counts.warning, "warning")), \(count(counts.hint, "hint")).")
            }
            return 0
        case "search", "show", "index":
            return try await knowledgeSearch(command!, &args, json: json, base: chosen, env: env, out: out)
        case "maps", "relations", "new-map":
            return try await knowledgeMaps(command!, &args, json: json, base: chosen, env: env, out: out)
        case "neighbors", "context", "focus":
            return try await knowledgeFocus(command!, &args, json: json, baseOption: baseOption, cwd: cwd, env: env,
                                            projectsRoot: projectsRoot, out: out)
        case "path":
            return try await knowledgePath(&args, json: json, cwd: cwd, env: env, out: out)
        case "kinds":
            return try await knowledgeKinds(&args, json: json, base: chosen, env: env, out: out)
        case "set":
            return try await knowledgeSet(&args, json: json, base: chosen, env: env, out: out)
        case "area":
            return try await knowledgeArea(&args, json: json, base: chosen, env: env, out: out)
        case "rm":
            let yes = args.flag("--yes")
            guard let name = args.positional() else { throw Failure(message: "Use: akit kb rm NOTE|MAP|AREA [--yes] [--json] [--base PATH|WORLD]") }
            try args.finish()
            let base = try await writable(chosen)
            let item: KnowledgeBase.Item
            do {
                item = try base.item(name)
                if yes { try await base.moveToTrash(item, env: env, trash: trash) }
            } catch {
                throw Failure(message: error.message)
            }
            if json {
                out(encode(RemoveAnswer(base: base.root.path, item: item, removed: yes)))
            } else {
                out(yes ? "Moved the \(item.kind.rawValue) \(item.id) (\(item.path)) to the Trash, committed."
                    : "Would move the \(item.kind.rawValue) \(item.id) (\(item.path)) to the Trash and commit the removal. Run again with --yes to do it.")
            }
            return 0
        case "rename":
            let yes = args.flag("--yes")
            guard let name = args.positional(), let new = args.positional() else {
                throw Failure(message: "Use: akit kb rename NOTE|MAP NEW [--yes] [--json] [--base PATH|WORLD]")
            }
            try args.finish()
            let base = try await writable(chosen)
            let plan: KnowledgeRename
            do {
                plan = try base.planRename(name, to: new)
                if yes { try await base.apply(plan, env: env) }
            } catch {
                throw Failure(message: error.message)
            }
            if json {
                out(encode(RenameAnswer(base: base.root.path, rename: plan, renamed: yes)))
            } else {
                let links = plan.linkCount == 1 ? "1 link" : "\(plan.linkCount) links"
                out((yes ? "Renamed the \(plan.kind.rawValue) \(plan.from) to \(plan.to) and \(links), committed:"
                    : "Would rename the \(plan.kind.rawValue) \(plan.from) to \(plan.to) and \(links), then commit. Run again with --yes to do it:")
                    + "\n" + plan.diff)
            }
            return 0
        case "seed":
            return try await knowledgeSeed(&args, json: json, baseOption: baseOption, base: chosen, env: env, out: out, trash: trash)
        default:
            throw Failure(message: "Unknown command “kb \(command ?? "")”. Run akit kb --help.")
        }
    }

    /// The base for a write, or the error that says to create one. A folder with `areas/` but no
    /// git, which the read commands accept, is refused: every write commits.
    private static func writable(_ base: () async throws -> KnowledgeBase?) async throws -> KnowledgeBase {
        guard let base = try await base() else {
            throw Failure(message: "No knowledge base on this Mac. Create one first: akit kb init [--world NAME]")
        }
        guard KnowledgeBase.isBase(base.root) else {
            throw Failure(message: "\(base.root.path) has areas/ but no git, so it can only be read; a change needs a base (akit kb init --base PATH).")
        }
        return base
    }

    /// `kb maps [AREA]`, `kb relations NOTE` (read) and `kb new-map AREA NAME` (person only).
    private static func knowledgeMaps(_ command: String, _ args: inout Arguments, json: Bool, base chosen: () async throws -> KnowledgeBase?,
                                      env: HarnessEnvironment, out: (String) -> Void) async throws -> Int32 {
        if command == "new-map" {
            guard let area = args.positional(), let name = args.positional() else {
                throw Failure(message: "Use: akit kb new-map AREA NAME [--base PATH|WORLD]")
            }
            try args.finish()
            if json { throw Failure(message: "--json doesn't go with akit kb new-map.") }
            let base = try await writable(chosen)
            let path: String
            do { path = try await base.newMap(area: area, name: name, env: env) } catch { throw Failure(message: error.message) }
            out("Created \(FileWalk.tilde(base.root.appending(path: path), home: env.homeDirectory)), committed.")
            return 0
        }
        let name = args.positional()
        if command == "relations", name == nil { throw Failure(message: "Use: akit kb relations NOTE [--json] [--base PATH|WORLD]") }
        try args.finish()
        guard let base = try await chosen() else {
            out(json ? encode(NoBase()) : "No knowledge base on this Mac (a person creates one with akit kb init).")
            return 0
        }
        if command == "maps" {
            let graph: MapGraph
            do { graph = try base.mapGraph(area: name) } catch { throw Failure(message: error.message) }
            if json {
                out(encode(MapsAnswer(base: base.root.path, area: name, maps: graph.maps.map(MapSummary.init))))
            } else {
                out(graph.maps.isEmpty ? "No maps\(name.map { " in \($0)" } ?? "") yet." : graph.maps.map { map in
                    "\(map.id)  " + (map.error.map { "can't be read: \($0)" }
                        ?? "\(count(map.blocks.count, "block")), \(count(map.edges.count, "arrow")), \(map.unbound.count) unbound"
                        + (map.jumps.isEmpty ? "" : ", jumps to " + map.jumps.map(\.map).joined(separator: ", ")))
                }.joined(separator: "\n"))
            }
            return 0
        }
        let note: String, relations: [MapGraph.Edge]
        do {
            note = try base.noteID(name!)
            relations = try base.mapGraph().relations(of: note)
        } catch {
            throw Failure(message: error.message)
        }
        if json {
            out(encode(RelationsAnswer(base: base.root.path, note: note, relations: relations)))
        } else {
            out(relations.isEmpty ? "No map has an arrow to or from \(note)." : relations.map { edge in
                "\(edge.from) → \(edge.to)" + (edge.kind.map { "  \"\($0)\"" } ?? "") + (edge.flow.map { "  flow \($0)" } ?? "") + "  (\(edge.map))"
            }.joined(separator: "\n"))
        }
        return 0
    }

    /// `kb search QUERY`, `kb show NOTE` and `kb index` (read, for agents; K19, K20).
    private static func knowledgeSearch(_ command: String, _ args: inout Arguments, json: Bool, base chosen: () async throws -> KnowledgeBase?,
                                        env: HarnessEnvironment, out: (String) -> Void) async throws -> Int32 {
        func number(_ name: String, _ fallback: Int) throws -> Int {
            guard let text = args.value(name) else { return fallback }
            guard let value = Int(text), value > 0 else { throw Failure(message: "\(name) takes a whole number above 0, not “\(text)”.") }
            return value
        }
        let maxTokens = try number("--max-tokens", Budget.defaultTokens)
        let home = env.homeDirectory
        func noBase() -> Int32 {
            out(json ? encode(NoBase()) : "No knowledge base on this Mac (a person creates one with akit kb init).")
            return 0
        }
        switch command {
        case "search":
            let area = args.value("--area"), limit = try number("--limit", 10)
            guard let query = args.positional() else {
                throw Failure(message: "Use: akit kb search QUERY [--area A] [--limit 10] [--max-tokens N] [--json] [--base PATH|WORLD]")
            }
            try args.finish()
            guard let base = try await chosen() else { return noBase() }
            let answer: KnowledgeIndex.SearchAnswer
            do { answer = try KnowledgeIndex(base: base).search(query, area: area, limit: limit, maxTokens: maxTokens) } catch {
                throw Failure(message: error.message)
            }
            if json {
                out(encode(answer))
            } else {
                var lines = answer.results.isEmpty ? ["No section of \(FileWalk.tilde(base.root, home: home)) has every word of “\(query)”."]
                    : answer.results.map { hit in
                        "\(hit.note)" + (hit.heading.map { "  ## \($0)" } ?? "") + "  \(hit.score)\n    \(hit.snippet)"
                            + (hit.neighbors.isEmpty ? "" : "\n    next to: " + hit.neighbors.joined(separator: ", "))
                    }
                if answer.stale { lines.append("(Another process is updating the index: these come from its last state.)") }
                out(lines.joined(separator: "\n"))
            }
            return 0
        case "show":
            let section = args.value("--section")
            guard let name = args.positional() else {
                throw Failure(message: "Use: akit kb show NOTE [--section H] [--max-tokens N] [--json] [--base PATH|WORLD]")
            }
            try args.finish()
            guard let base = try await chosen() else { return noBase() }
            let answer: KnowledgeIndex.ShowAnswer
            do { answer = try KnowledgeIndex(base: base).show(name, section: section, maxTokens: maxTokens) } catch {
                throw Failure(message: error.message)
            }
            if json {
                out(encode(answer))
            } else {
                let front = answer.frontmatter
                let facts = [front.kind.map { "kind: \($0)" }, front.repo.map { "repo: \($0)" },
                             front.files.isEmpty ? nil : "files: " + front.files.joined(separator: ", ")].compactMap(\.self)
                var parts = ["# \(answer.title)  (\(answer.note))" + (facts.isEmpty ? "" : "\n" + facts.joined(separator: "  "))]
                parts += answer.sections.map { section in (section.heading.map { "## \($0)\n" } ?? "") + section.text }
                if answer.truncated { parts.append("(Cut to \(maxTokens) tokens: ask for one --section, or a larger --max-tokens.)") }
                out(parts.joined(separator: "\n\n"))
            }
            return 0
        default:
            let rebuild = args.flag("--rebuild")
            try args.finish()
            guard let base = try await chosen() else { return noBase() }
            let index = KnowledgeIndex(base: base)
            let status: KnowledgeIndex.Status
            do { status = try index.refresh(rebuild: rebuild) } catch { throw Failure(message: error.message) }
            if json {
                out(encode(status))
            } else {
                out((status.stale ? "Another process is updating the index; as it is now: " : status.rebuilt ? "Built the index: " : "The index is up to date: ")
                    + "\(count(status.notes, "note")), \(count(status.maps, "map")), \(count(status.chunks, "section")) in "
                    + FileWalk.tilde(index.file, home: home) + ".")
            }
            return 0
        }
    }

    /// `kb neighbors NOTE`, `kb context [FOLDER]` (read, for agents; K5, K19) and `kb focus
    /// [FOLDER]` with its person-only `--set AREA` / `--clear`.
    private static func knowledgeFocus(_ command: String, _ args: inout Arguments, json: Bool, baseOption: String?, cwd: URL,
                                       env: HarnessEnvironment, projectsRoot: URL, out: (String) -> Void) async throws -> Int32 {
        let home = env.homeDirectory
        let maxText = args.value("--max-tokens"), depthText = args.value("--depth")
        let set = args.value("--set"), clear = args.flag("--clear")
        let name = args.positional()
        try args.finish()
        let maxTokens: Int
        if let maxText {
            guard command != "focus", let value = Int(maxText), value > 0 else {
                throw Failure(message: command == "focus" ? "--max-tokens doesn't go with akit kb focus."
                    : "--max-tokens takes a whole number above 0, not “\(maxText)”.")
            }
            maxTokens = value
        } else {
            maxTokens = Budget.defaultTokens
        }
        if command != "focus", set != nil || clear { throw Failure(message: "--set and --clear go with akit kb focus.") }
        if command != "neighbors", depthText != nil { throw Failure(message: "--depth goes with akit kb neighbors.") }
        if command == "neighbors", name == nil {
            throw Failure(message: "Use: akit kb neighbors NOTE [--depth 1|2] [--max-tokens N] [--json] [--base PATH|WORLD]")
        }
        if set != nil, clear { throw Failure(message: "Use --set AREA or --clear, not both.") }
        let depth = Int(depthText ?? "1") ?? 0
        guard depth == 1 || depth == 2 else { throw Failure(message: "--depth is 1 or 2, not “\(depthText ?? "")”.") }
        // context and focus name a project folder (default: the current one); it also picks the base.
        let folder = command == "neighbors" ? cwd : name.map { resolve($0, cwd: cwd, env: env) } ?? cwd
        if command != "neighbors", !FileWalk.isDirectory(folder) { throw Failure(message: "No folder \(folder.path).") }
        let found: KnowledgeBase?
        do {
            found = try await KnowledgeBase.choose(option: baseOption, folder: folder, env: env, projectsRoot: projectsRoot, forReading: true)
        } catch {
            throw Failure(message: error.message)
        }
        guard let base = found else {
            out(json ? encode(NoBase()) : "No knowledge base on this Mac (a person creates one with akit kb init).")
            return 0
        }
        let index = KnowledgeIndex(base: base)
        switch command {
        case "neighbors":
            let answer: KnowledgeIndex.NeighborsAnswer
            do { answer = try index.neighbors(name!, depth: depth, maxTokens: maxTokens) } catch { throw Failure(message: error.message) }
            if json {
                out(encode(answer))
            } else {
                var lines = answer.edges.isEmpty ? ["No map has an arrow to or from \(answer.note)."] : answer.edges.map { edge in
                    "\(edge.from) → \(edge.to)" + (edge.kind.map { "  \"\($0)\"" } ?? "") + (edge.flow.map { "  flow \($0)" } ?? "") + "  (\(edge.map))"
                }
                if answer.truncated { lines.append("(Cut to \(maxTokens) tokens: ask for a larger --max-tokens.)") }
                if answer.stale { lines.append("(Another process is updating the index: these come from its last state.)") }
                out(lines.joined(separator: "\n"))
            }
            return 0
        case "context":
            let focus = await base.focus(folder: folder, env: env, projectsRoot: projectsRoot)
            let answer: KnowledgeIndex.ContextAnswer
            do { answer = try index.context(focus: focus.choice.area, maxTokens: maxTokens) } catch { throw Failure(message: error.message) }
            if json {
                out(encode(answer))
            } else {
                guard let area = answer.focus else {
                    out("No area of \(FileWalk.tilde(base.root, home: home)) names this project (its remote or folder). See akit kb areas.")
                    return 0
                }
                var lines = ["Focus: \(area) (\(focus.choice.source?.rawValue ?? "-"))"]
                lines += answer.systems.map { "\($0.note)  \($0.title)" + ($0.line.isEmpty ? "" : ": \($0.line)") }
                lines += answer.relations.map { "\($0.from) → \($0.to)" + ($0.kind.map { "  \"\($0)\"" } ?? "") }
                if answer.truncated { lines.append("(Cut to \(maxTokens) tokens: ask for a larger --max-tokens.)") }
                if answer.stale { lines.append("(Another process is updating the index: these come from its last state.)") }
                out(lines.joined(separator: "\n"))
            }
            return 0
        default:
            var (project, choice) = await base.focus(folder: folder, env: env, projectsRoot: projectsRoot)
            if set != nil || clear {
                if let set, !base.areas().contains(where: { $0.name == set.precomposedStringWithCanonicalMapping }) {
                    throw Failure(message: "No area “\(set)” in \(base.root.path). Areas: \(base.areas().map(\.name).joined(separator: ", ")).")
                }
                do {
                    try KnowledgeBase.Focus.load(home: home)
                        .setting(area: set?.precomposedStringWithCanonicalMapping, project: project).save(home: home)
                } catch {
                    throw Failure(message: error.message)
                }
                choice = await base.focus(folder: folder, env: env, projectsRoot: projectsRoot).choice
            }
            if json {
                out(encode(FocusAnswer(base: base.root.path, project: project, focus: choice.area, source: choice.source?.rawValue)))
            } else {
                let what = choice.area.map { "\($0) (\(choice.source?.rawValue ?? "-"))" } ?? "none (no area names its remote or folder)"
                out("\(project): focus \(what)" + (set != nil ? "; set in ~/.akit/local/knowledge/focus.json." : clear ? "; your choice is cleared." : ""))
            }
            return 0
        }
    }

    /// `kb path [WORLD]` and its person-only changes `--set`, `--move`, `--reset` (K25).
    private static func knowledgePath(_ args: inout Arguments, json: Bool, cwd: URL, env: HarnessEnvironment,
                                      out: (String) -> Void) async throws -> Int32 {
        let home = env.homeDirectory
        let set = args.value("--set"), move = args.value("--move"), reset = args.flag("--reset")
        let brain = args.value("--brain").map { resolve($0, cwd: cwd, env: env) }
        let world = args.positional() ?? MachineProfile.load(home: home).kind.rawValue
        try args.finish()
        if [set != nil, move != nil, reset].filter(\.self).count > 1 { throw Failure(message: "Use one of --set PATH, --move PATH and --reset.") }
        guard KnowledgeBase.validWorld(world) else {
            throw Failure(message: "“\(world)” can't name a world: use letters, digits, - and _ (like work or personal).")
        }
        // Not `resolve`: its standardizedFileURL turns an existing /private/tmp/… into /tmp/…, and
        // the folder is kept as typed (links are not followed).
        func folder(_ path: String) -> URL {
            (path.hasPrefix("~") || path.hasPrefix("/") ? env.expand(path) : cwd.appending(path: path)).standardized
        }
        var report: String?
        do {
            if let set {
                let change = try await KnowledgeBase.setFolder(world: world, to: folder(set), env: env, brainRoot: brain)
                let path = FileWalk.tilde(change.base.root, home: home)
                report = (change.created ? "Created the knowledge base of \(world) in \(path) (git without a remote, committed)"
                    : "The base of \(world) is now \(path)") + "; kept in ~/.akit/local/knowledge/bases.json."
                    + (change.previous.map { " The old base \(FileWalk.tilde($0, home: home)) stays as it is and is no longer used." } ?? "")
            } else if let move {
                let from = KnowledgeBase.root(world: world, home: home)
                let base = try await KnowledgeBase.move(world: world, to: folder(move), env: env, brainRoot: brain)
                report = "Moved the base of \(world) from \(FileWalk.tilde(from, home: home)) to \(FileWalk.tilde(base.root, home: home))."
            } else if reset {
                let old = KnowledgeBase.root(world: world, home: home)
                let folder = try KnowledgeBase.resetFolder(world: world, home: home)
                report = "The base of \(world) is the default folder again: \(FileWalk.tilde(folder, home: home))"
                    + (KnowledgeBase.isBase(folder) ? "." : " (no base there yet: akit kb init --world \(world)).")
                    + (KnowledgeBase(root: old) == KnowledgeBase(root: folder) ? "" : " \(FileWalk.tilde(old, home: home)) stays as it is.")
            }
        } catch {
            throw Failure(message: error.message)
        }
        let root = KnowledgeBase(root: KnowledgeBase.root(world: world, home: home)).root
        let answer = PathAnswer(world: world, path: root.path, configured: KnowledgeBase.isConfigured(world: world, home: home),
                                isBase: KnowledgeBase.isBase(root), vault: Obsidian.vault(containing: root)?.standardized.path,
                                defaultPath: KnowledgeBase(root: KnowledgeBase.world(world, home: home)).root.path)
        if json {
            out(encode(answer))
        } else if let report {
            out(report)
        } else {
            var lines = ["\(world): \(FileWalk.tilde(root, home: home))"
                + (answer.configured ? " (set on this Mac in ~/.akit/local/knowledge/bases.json)" : " (the default folder)")]
            if !answer.isBase { lines.append("No base there yet (a person creates one with akit kb init --world \(world)).") }
            if let vault = answer.vault { lines.append("In the Obsidian vault \(FileWalk.tilde(URL(filePath: vault), home: home)).") }
            out(lines.joined(separator: "\n"))
        }
        return 0
    }

    /// `kb seed` and `kb seed --remove` (person only, K26).
    private static func knowledgeSeed(_ args: inout Arguments, json: Bool, baseOption: String?, base chosen: () async throws -> KnowledgeBase?,
                                      env: HarnessEnvironment, out: (String) -> Void, trash: (URL) throws -> URL?) async throws -> Int32 {
        let home = env.homeDirectory
        let remove = args.flag("--remove"), yes = args.flag("--yes")
        let world = args.value("--world")
        try args.finish()
        if world != nil, baseOption != nil { throw Failure(message: "Use --world NAME or --base PATH|WORLD, not both.") }
        guard remove else {
            if baseOption != nil { throw Failure(message: "akit kb seed names its base with --world NAME (default \(KnowledgeSeed.world)).") }
            if yes { throw Failure(message: "--yes goes with akit kb seed --remove.") }
            let outcome: KnowledgeSeed.Outcome
            do { outcome = try await KnowledgeSeed.seed(world: world ?? KnowledgeSeed.world, env: env, trash: trash) } catch {
                throw Failure(message: error.message)
            }
            let path = FileWalk.tilde(outcome.base.root, home: home)
            if json {
                out(encode(SeedAnswer(base: outcome.base.root.path, world: outcome.base.name, seedVersion: KnowledgeSeed.version,
                                      status: outcome.status.rawValue, files: outcome.files)))
            } else {
                switch outcome.status {
                case .created: out("Created the sample base \(path) (seed v\(KnowledgeSeed.version), \(count(outcome.files.count, "file"))), committed.\nSee it: akit kb areas --base \(outcome.base.name)")
                case .updated: out("Updated the sample base \(path) to seed v\(KnowledgeSeed.version), committed.")
                case .unchanged: out("The sample base \(path) is up to date (seed v\(KnowledgeSeed.version)).")
                }
            }
            return 0
        }
        let base: KnowledgeBase
        if baseOption != nil {
            base = try await writable(chosen)
        } else {
            let name = world ?? KnowledgeSeed.world
            base = KnowledgeBase(root: KnowledgeBase.root(world: name, home: home), world: name)
            guard KnowledgeBase.isBase(base.root) else {
                throw Failure(message: "No sample base of the world \(name) at \(FileWalk.tilde(base.root, home: home)).")
            }
        }
        guard KnowledgeSeed.marker(of: base) != nil else {
            throw Failure(message: "\(FileWalk.tilde(base.root, home: home)) is not a sample base (it has no \(KnowledgeSeed.markerName)), so AKit doesn't remove it. Remove notes or areas with akit kb rm.")
        }
        if yes {
            do { try KnowledgeSeed.remove(base, home: home, trash: trash) } catch { throw Failure(message: error.message) }
        }
        let path = FileWalk.tilde(base.root, home: home)
        if json {
            out(encode(SeedRemoveAnswer(base: base.root.path, world: base.world, removed: yes)))
        } else {
            out(yes ? "Moved the sample base \(path) to the Trash."
                : "Would move the sample base \(path) (the whole folder) to the Trash. Run again with --yes to do it.")
        }
        return 0
    }

    /// `kb kinds` and its person-only changes `add`, `fields`, `remove`, `rename`.
    private static func knowledgeKinds(_ args: inout Arguments, json: Bool, base chosen: () async throws -> KnowledgeBase?,
                                       env: HarnessEnvironment, out: (String) -> Void) async throws -> Int32 {
        let fieldsOption = args.value("--fields")
        let action = args.positional()
        let first = args.positional(), second = args.positional()
        try args.finish()
        func fields(_ text: String?) -> [String] { (text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        guard let action else {
            if fieldsOption != nil { throw Failure(message: "--fields goes with akit kb kinds add NAME.") }
            guard let base = try await chosen() else {
                out(json ? encode(NoBase()) : "No knowledge base on this Mac (a person creates one with akit kb init).")
                return 0
            }
            let kinds: KnowledgeKinds
            do { kinds = try base.kinds() } catch { throw Failure(message: error.message) }
            let defaults = !FileManager.default.fileExists(atPath: base.root.appending(path: KnowledgeKinds.fileName).path)
            if json {
                out(encode(KindsAnswer(base: base.root.path, file: KnowledgeKinds.fileName, defaults: defaults, kinds: kinds.kinds)))
            } else {
                out((kinds.kinds.isEmpty ? "No kinds in \(KnowledgeKinds.fileName)." : kinds.kinds.map { kind in
                    kind.name + "  " + (kind.fields.isEmpty ? "-" : kind.fields.joined(separator: ", "))
                }.joined(separator: "\n")) + (defaults ? "\n(the defaults: the base has no \(KnowledgeKinds.fileName))" : ""))
            }
            return 0
        }
        let base = try await writable(chosen)
        var kinds: KnowledgeKinds
        do { kinds = try base.kinds() } catch { throw Failure(message: error.message) }
        let message: String
        var report: String
        do {
            switch (action, first, second) {
            case ("add", let name?, nil):
                kinds = try kinds.adding(name, fields: fields(fieldsOption))
                (message, report) = ("Add kind \(name)", "Added the kind \(name)")
            case ("fields", let name?, let list?) where fieldsOption == nil:
                kinds = try kinds.settingFields(of: name, to: fields(list))
                (message, report) = ("Set the fields of kind \(name)", "Set the fields of \(name)")
            case ("remove", let name?, nil) where fieldsOption == nil:
                kinds = try kinds.removing(name)
                let using = try base.notes().filter { $0.kind == name }.count
                (message, report) = ("Remove kind \(name)", "Removed the kind \(name)"
                    + (using == 0 ? "" : " (\(count(using, "note")) still \(using == 1 ? "has" : "have") kind: \(name))"))
            case ("rename", let old?, let new?) where fieldsOption == nil:
                let paths = try await base.renameKind(old, to: new, env: env)
                kinds = try base.kinds()
                let notes = max(paths.count - 1, 0)
                report = "Renamed the kind \(old) to \(new) in \(KnowledgeKinds.fileName) and \(count(notes, "note")), committed."
                out(json ? encode(KindsAnswer(base: base.root.path, file: KnowledgeKinds.fileName, defaults: false, kinds: kinds.kinds)) : report)
                return 0
            default:
                throw Failure(message: "Use: akit kb kinds [add NAME [--fields a,b] | fields NAME a,b | remove NAME | rename OLD NEW] [--json] [--base PATH|WORLD]")
            }
            try base.save(kinds: kinds)
            try await base.commit([KnowledgeKinds.fileName], message: message, env: env)
        } catch let error as KnowledgeBase.Failure {
            throw Failure(message: error.message)
        }
        out(json ? encode(KindsAnswer(base: base.root.path, file: KnowledgeKinds.fileName, defaults: false, kinds: kinds.kinds))
            : report + ", committed.")
        return 0
    }

    /// `kb set NOTE KEY=VALUE… [--unset KEY]…` (person only).
    private static func knowledgeSet(_ args: inout Arguments, json: Bool, base chosen: () async throws -> KnowledgeBase?,
                                     env: HarnessEnvironment, out: (String) -> Void) async throws -> Int32 {
        let unset = args.values("--unset")
        guard let name = args.positional() else {
            throw Failure(message: "Use: akit kb set NOTE KEY=VALUE… [--unset KEY]… [--base PATH|WORLD]")
        }
        var pairs: [(key: String, value: KnowledgeNote.PropertyValue)] = []
        while let pair = args.positional() {
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                throw Failure(message: "“\(pair)” is not KEY=VALUE (like owner=team-a, or files=[a.ts, b.ts]).")
            }
            let value = String(pair[pair.index(after: equals)...])
            guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw Failure(message: "\(pair) has no value; remove a property with --unset \(pair.dropLast()).")
            }
            pairs.append((String(pair[..<equals]).trimmingCharacters(in: .whitespaces), .parse(value)))
        }
        try args.finish()
        guard !pairs.isEmpty || !unset.isEmpty else { throw Failure(message: "Nothing to set: give KEY=VALUE or --unset KEY.") }
        let base = try await writable(chosen)
        let id: String, path: String, changed: Bool
        do {
            id = try base.noteID(name)
            (path, changed) = try base.setProperties(note: id, set: pairs, unset: unset)
            if changed {
                let keys = pairs.map(\.key) + unset
                try await base.commit([path], message: "Set \(keys.joined(separator: ", ")) of \(id)", env: env)
            }
        } catch {
            throw Failure(message: error.message)
        }
        if json {
            out(encode(SetAnswer(base: base.root.path, note: id, path: path, changed: changed,
                                 properties: KnowledgeNote.load(base.noteFile(id))?.properties ?? [:])))
        } else {
            out(changed ? "Changed \(id) (\(path)), committed." : "Nothing changed in \(id): it has these values already.")
        }
        return 0
    }

    /// `kb area AREA` (read) and its person-only changes.
    private static func knowledgeArea(_ args: inout Arguments, json: Bool, base chosen: () async throws -> KnowledgeBase?,
                                      env: HarnessEnvironment, out: (String) -> Void) async throws -> Int32 {
        let title = args.value("--title"), description = args.value("--description")
        let add = args.values("--project"), remove = args.values("--remove-project")
        guard let name = args.positional() else {
            throw Failure(message: "Use: akit kb area AREA [--title T] [--description D] [--project P]… [--remove-project P]… [--json]")
        }
        try args.finish()
        let changes = title != nil || description != nil || !add.isEmpty || !remove.isEmpty
        let found: KnowledgeBase?
        if changes { found = try await writable(chosen) } else { found = try await chosen() }
        guard let base = found else {
            out(json ? encode(NoBase()) : "No knowledge base on this Mac (a person creates one with akit kb init).")
            return 0
        }
        var settings: KnowledgeArea
        do {
            settings = try base.settings(area: name)
            if changes {
                if let title { settings.title = title }
                if let description { settings.description = description }
                settings.projects = settings.projects.filter { !remove.contains($0) } + add
                let path = try base.save(area: name, settings: settings)
                try await base.commit([path], message: "Edit the settings of area \(name)", env: env)
                settings = try base.settings(area: name)
            }
        } catch {
            throw Failure(message: error.message)
        }
        if json {
            out(encode(AreaAnswer(base: base.root.path, area: name, file: "areas/\(name)/\(KnowledgeArea.fileName)", settings: settings)))
        } else {
            let lines = ["area: \(name)", "title: \(settings.title ?? "-")", "description: \(settings.description ?? "-")",
                         "projects: " + (settings.projects.isEmpty ? "-" : settings.projects.joined(separator: ", "))]
            out(lines.joined(separator: "\n") + (changes ? "\nSaved areas/\(name)/\(KnowledgeArea.fileName), committed." : ""))
        }
        return 0
    }

    private static func count(_ number: Int, _ word: String) -> String { "\(number) \(word)\(number == 1 ? "" : "s")" }

    struct AreasAnswer: Encodable {
        let base: String
        let areas: [KnowledgeBase.Area]
    }

    struct NotesAnswer: Encodable {
        let base: String
        let area: String?
        let notes: [KnowledgeBase.NoteEntry]

        private enum CodingKeys: String, CodingKey { case base, area, notes }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(base, forKey: .base)
            try container.encode(area, forKey: .area) // null for every area
            try container.encode(notes, forKey: .notes)
        }
    }

    struct MapsAnswer: Encodable {
        let base: String
        let area: String?
        let maps: [MapSummary]

        private enum CodingKeys: String, CodingKey { case base, area, maps }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(base, forKey: .base)
            try container.encode(area, forKey: .area) // null for every area
            try container.encode(maps, forKey: .maps)
        }
    }

    /// One map in `kb maps --json`: counts, the maps it jumps to, and an error for a file that
    /// can't be read.
    struct MapSummary: Encodable {
        let id: String
        let area: String
        let path: String
        let elements: Int
        let blocks: Int
        let arrows: Int
        let unbound: Int
        let jumps: [MapGraph.Jump]
        let error: String?

        init(_ map: MapGraph.Map) {
            (id, area, path, elements) = (map.id, map.area, map.path, map.elements)
            (blocks, arrows, unbound, jumps, error) = (map.blocks.count, map.edges.count, map.unbound.count, map.jumps, map.error)
        }
    }

    struct RelationsAnswer: Encodable {
        let base: String
        let note: String
        let relations: [MapGraph.Edge]
    }

    struct FocusAnswer: Encodable {
        let base: String
        /// The id `focus.json` keys the project by (its normalized remote, else `local/…`).
        let project: String
        let focus: String?
        /// override, area.yaml or repo; null without a focus.
        let source: String?

        private enum CodingKeys: String, CodingKey { case base, project, focus, source }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(base, forKey: .base)
            try container.encode(project, forKey: .project)
            try container.encode(focus, forKey: .focus)
            try container.encode(source, forKey: .source)
        }
    }

    struct PathAnswer: Encodable {
        let world: String
        let path: String
        /// `bases.json` sets the folder; false for the default one.
        let configured: Bool
        let isBase: Bool
        /// The Obsidian vault the folder is in (nearest folder with `.obsidian/`).
        let vault: String?
        let defaultPath: String

        private enum CodingKeys: String, CodingKey { case world, path, configured, isBase, vault, defaultPath }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(world, forKey: .world)
            try container.encode(path, forKey: .path)
            try container.encode(configured, forKey: .configured)
            try container.encode(isBase, forKey: .isBase)
            try container.encode(vault, forKey: .vault) // null outside a vault
            try container.encode(defaultPath, forKey: .defaultPath)
        }
    }

    struct KindsAnswer: Encodable {
        let base: String
        let file: String
        /// The base has no kb.yaml, so these are the defaults.
        let defaults: Bool
        let kinds: [KnowledgeKinds.Kind]
    }

    struct SetAnswer: Encodable {
        let base: String
        let note: String
        let path: String
        let changed: Bool
        let properties: [String: KnowledgeNote.PropertyValue]
    }

    struct AreaAnswer: Encodable {
        let base: String
        let area: String
        let file: String
        let settings: KnowledgeArea

        private enum CodingKeys: String, CodingKey { case base, area, file }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(base, forKey: .base)
            try container.encode(area, forKey: .area)
            try container.encode(file, forKey: .file)
            try settings.encode(to: encoder)
        }
    }

    struct RenameAnswer: Encodable {
        let base: String
        let rename: KnowledgeRename
        /// false without --yes: nothing was written.
        let renamed: Bool
    }

    struct RemoveAnswer: Encodable {
        let base: String
        let item: KnowledgeBase.Item
        /// false without --yes: nothing was removed.
        let removed: Bool

        private enum CodingKeys: String, CodingKey { case base, removed }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(base, forKey: .base)
            try item.encode(to: encoder)
            try container.encode(removed, forKey: .removed)
        }
    }

    struct SeedAnswer: Encodable {
        let base: String
        let world: String
        let seedVersion: Int
        /// created, updated or unchanged.
        let status: String
        let files: [String]
    }

    struct SeedRemoveAnswer: Encodable {
        let base: String
        let world: String?
        let removed: Bool

        private enum CodingKeys: String, CodingKey { case base, world, removed }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(base, forKey: .base)
            try container.encode(world, forKey: .world) // null for a base named by its path
            try container.encode(removed, forKey: .removed)
        }
    }

    /// P6: `{"base": null, "reason": "no base"}`.
    struct NoBase: Encodable {
        private enum CodingKeys: String, CodingKey { case base, reason }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeNil(forKey: .base)
            try container.encode("no base", forKey: .reason)
        }
    }
}
