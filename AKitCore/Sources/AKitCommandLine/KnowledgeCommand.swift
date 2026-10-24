import AKitBrain
import AKitFoundation
import AKitKnowledge
import Foundation

/// `akit kb`: the knowledge base (docs/design/knowledge.md). Agents run only the read commands;
/// the person-only ones (U1) are marked so in the help and are never in the `/akit` skill.
extension AKitCLI {
    static let knowledgeUsage = """
    akit kb: the knowledge base, notes and maps of the systems around a repository
    (docs/design/knowledge.md). A base is a folder per world, ~/.akit/local/knowledge/<world>,
    a local git repo that never has a remote: areas/<area>/ holds notes (Markdown) and maps.

    Read (agents may run these):
      akit kb areas [--json] [--base PATH|WORLD]
                                        The areas with their note and map counts
      akit kb notes [AREA] [--json] [--base PATH|WORLD]
                                        The notes (of one area): id, kind and title. An id is the
                                        path under areas/ without .md, like payments/orders-api

    Write (for a person only: an agent never runs these, it asks the user):
      akit kb init [--world NAME | --base PATH]
                                        For a person only. Create a base: areas/, inbox/, .gitignore,
                                        git without a remote, a first commit. NAME defaults to this
                                        Mac's kind (work or personal). Refused inside the brain, on
                                        a work Mac outside ~/.akit/local/, in a repo with a remote
      akit kb new-note AREA NAME [--kind K] [--base PATH|WORLD]
                                        For a person only. Create areas/AREA/NAME.md (# NAME, and
                                        kind: K in the frontmatter) and commit it at once

    Which base (--base, else in this order): the current project's entry in
    ~/.akit/local/knowledge/focus.json, the only base, the base named like this Mac's kind. With
    no base, the read commands say so (--json: {"base": null, "reason": "no base"}) and exit 0.
    """

    static func knowledge(_ arguments: [String], env: HarnessEnvironment, cwd: URL, projectsRoot: URL,
                          out: (String) -> Void) async throws -> Int32 {
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
                return try await KnowledgeBase.choose(option: baseOption, folder: cwd, env: env, projectsRoot: projectsRoot)
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
                        : areas.map { "\($0.name)  \(count($0.notes, "note")), \(count($0.maps, "map"))" }.joined(separator: "\n"))
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
            guard let base = try await chosen() else {
                throw Failure(message: "No knowledge base on this Mac. Create one first: akit kb init [--world NAME]")
            }
            let path: String
            do { path = try await base.newNote(area: area, name: name, kind: kind, env: env) } catch { throw Failure(message: error.message) }
            out("Created \(FileWalk.tilde(base.root.appending(path: path), home: env.homeDirectory)), committed.")
            return 0
        default:
            throw Failure(message: "Unknown command “kb \(command ?? "")”. Run akit kb --help.")
        }
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
