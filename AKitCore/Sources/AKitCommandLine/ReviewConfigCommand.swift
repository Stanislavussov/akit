import AKitBrain
import AKitFoundation
import AKitReview
import Foundation

/// `akit review roles|scenarios|role|scenario|defaults|profile`: what Review → Roles and
/// Scenarios does in the app, for the terminal and for agents (`docs/design/review.md`, R9–R10,
/// R17). Every save shows its diff first; `--yes` writes it (a brain save is committed).
extension AKitCLI {
    static let reviewConfigUsage = """
    Roles, scenarios and configuration (as Review → Roles and Scenarios in the app):
      akit review roles [--project P] [--json]
      akit review scenarios [--project P] [--json]
                                        Every role or scenario with its source (built-in, brain,
                                        project); --project lists what that project sees
      akit review role show ID [--project P]
      akit review role new ID [--project P] [--file PATH|-] [--yes]
      akit review role save ID --file PATH|- [--project P] [--yes]
      akit review role duplicate ID --project P [--yes]
      akit review role reset ID --project P [--yes]
                                        new: a role from the template (or from --file; - reads
                                        stdin) as skills/review-ID/SKILL.md. save: replace its text.
                                        Without --project it goes to the brain layer review
                                        (committed); with it, to the project's own copy on this
                                        Mac. duplicate: the brain's text as the project's copy.
                                        reset: the project's copy goes to the Trash. Each prints
                                        the diff; --yes does it
      akit review scenario show|new|save|duplicate|reset ID …
                                        The same for a scenario (scenarios/ID.yaml)
      akit review defaults show | save --file PATH|- [--yes]
                                        The brain's review.yaml: models, thresholds, caps
      akit review profile show SLUG | new SLUG [--file PATH|-] [--yes] | save SLUG --file PATH|- [--yes]
                                        A project profile (~/.akit/local/review/projects/SLUG.yaml)
    """

    /// The kinds a terminal command names.
    static func reviewConfigKind(_ word: String) -> ReviewConfigEditor.Kind? {
        switch word {
        case "role", "roles": .role
        case "scenario", "scenarios": .scenario
        case "defaults": .defaults
        case "profile": .profile
        default: nil
        }
    }

    struct ReviewConfigItem: Encodable {
        let id: String
        let title: String
        let description: String
        let source: String
        let file: String?
    }

    /// `roles` / `scenarios`: the list.
    static func reviewConfigList(_ kind: ReviewConfigEditor.Kind, project: String?, json: Bool, catalog: ReviewCatalog,
                                 out: (String) -> Void) throws -> Int32 {
        let profile = try reviewProfile(project, catalog: catalog)
        let items: [ReviewConfigItem] = kind == .role
            ? catalog.roles(for: profile).map { ReviewConfigItem(id: $0.id, title: $0.id, description: $0.description, source: $0.source.rawValue, file: $0.file?.path) }
            : catalog.scenarios(for: profile).map {
                ReviewConfigItem(id: $0.id, title: $0.title, description: "Roles: " + ($0.required + $0.optional.map { "\($0)?" }).joined(separator: ", "),
                                 source: $0.source.rawValue, file: $0.file?.path)
            }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            out(String(decoding: try encoder.encode(items), as: UTF8.self))
        } else {
            for item in items { out("\(item.id)  [\(item.source)]  \(item.description)") }
        }
        return 0
    }

    static func reviewProfile(_ slug: String?, catalog: ReviewCatalog) throws -> ReviewProfile? {
        try slug.map { slug in
            guard let profile = catalog.profiles.first(where: { $0.slug == slug }) else { throw Failure(message: "There is no project profile \(slug).") }
            return profile
        }
    }

    /// `role|scenario|defaults|profile ACTION …`.
    static func reviewConfig(_ kind: ReviewConfigEditor.Kind, args: inout Arguments, project: String?, file: String?, yes: Bool,
                             brain: URL, env: HarnessEnvironment, cwd: URL, out: (String) -> Void, err: (String) -> Void,
                             input: () -> Data, trash: (URL) throws -> URL?) async throws -> Int32 {
        let home = env.homeDirectory
        let name = kind.rawValue
        guard let action = args.positional() else { throw Failure(message: "akit review \(name) show|new|save… (akit review --help).") }
        // The item's id: none for defaults; a profile's id is its slug.
        let id: String
        if kind == .defaults {
            id = ""
        } else {
            guard let given = args.positional() else { throw Failure(message: "Which \(name)? akit review \(name) \(action) ID.") }
            id = given.hasPrefix("review-") && kind == .role ? String(given.dropFirst("review-".count)) : given
        }
        try args.finish()
        // Ids name files: nothing like ../ may reach a path.
        if kind != .defaults, !ReviewYAML.isID(id) { throw Failure(message: "\(id) is not a \(name) id: use a-z, 0-9 and -.") }
        if let project, !ReviewYAML.isID(project) { throw Failure(message: "\(project) is not a project profile id.") }
        if kind == .profile, project != nil { throw Failure(message: "A profile is named by its slug, without --project.") }
        if kind == .defaults, project != nil { throw Failure(message: "A project's defaults live in its profile's review: block (akit review profile save).") }
        let level: ReviewConfigEditor.Level = kind == .profile ? .project(id) : project.map { .project($0) } ?? .brain
        let catalog = ReviewCatalog.load(home: home, brain: brain)
        for problem in catalog.problems { err("akit: \(problem)") }
        if kind != .profile, project != nil { _ = try reviewProfile(project, catalog: catalog) }

        func readText() throws -> String? {
            guard let file else { return nil }
            if file == "-" {
                guard let text = String(data: input(), encoding: .utf8) else { throw Failure(message: "The text on stdin isn't UTF-8.") }
                return text
            }
            let url = resolve(file, cwd: cwd, env: env)
            guard let data = try? Data(contentsOf: url) else { throw Failure(message: "Can't read \(url.path).") }
            guard let text = String(data: data, encoding: .utf8) else { throw Failure(message: "\(url.path) isn't UTF-8 text.") }
            return text
        }

        func finishSave(_ save: ReviewConfigEditor.Save) async throws -> Int32 {
            out("\(save.old == nil ? "New" : "Change to") \(name) \(save.id.isEmpty ? "review.yaml" : save.id) in \(save.level.title): \(save.file.path)")
            if save.diff.isEmpty {
                out("No change.")
                return 0
            }
            for line in save.diff { out(line) }
            if !save.workWords.isEmpty {
                err("akit: this is a work Mac, and the text names \(save.workWords.joined(separator: ", ")) from your work profiles. "
                    + "The brain may go to your personal GitHub: keep work names in a project copy (--project P) instead.")
            }
            if save.old == nil, kind == .profile, file == nil {
                out("Fill in gitlab: and checkout: (and tracker:, mcp: if needed) before a review uses it: "
                    + "akit review profile save \(id) --file PATH.")
            }
            guard yes else {
                out("Nothing written. Run again with --yes to save" + (save.level == .brain ? " (committed in the brain)." : "."))
                return 0
            }
            if save.level == .brain, let problem = await BrainGit.commitProblem(brain: brain, env: env) {
                throw Failure(message: problem)
            }
            do {
                try await ReviewConfigEditor.apply(save, brain: brain, env: env)
            } catch {
                throw Failure(message: error.localizedDescription)
            }
            out("Saved" + (save.level == .brain ? " and committed in the brain." : "."))
            return 0
        }

        do {
            switch action {
            case "show":
                if file != nil || yes { throw Failure(message: "show takes no --file or --yes.") }
                let url = ReviewConfigEditor.file(kind, id: id, level: level, home: home, brain: brain)
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    out(text)
                    return 0
                }
                // What the level sees: a project falls back to the brain, the brain to the built-ins.
                let profile = try kind == .profile ? nil : reviewProfile(project, catalog: catalog)
                let text: String? = switch kind {
                case .role: catalog.roles(for: profile).first { $0.id == id }?.text
                case .scenario: catalog.scenarios(for: profile).first { $0.id == id }?.text
                case .defaults: ReviewBuiltIns.defaultsYAML + "\n"
                case .profile: nil
                }
                guard let text else {
                    throw Failure(message: kind == .profile ? "There is no project profile \(id): create it with akit review profile new \(id)."
                                  : "There is no \(name) \(id) (akit review \(kind == .scenario ? "scenarios" : "roles") lists them).")
                }
                out(text)
                return 0
            case "new":
                guard kind != .defaults else { throw Failure(message: "The defaults already exist: akit review defaults show, then save --file.") }
                let url = ReviewConfigEditor.file(kind, id: id, level: level, home: home, brain: brain)
                if FileManager.default.fileExists(atPath: url.path) {
                    throw Failure(message: "\(level.title) already has \(name) \(id): change it with akit review \(name) save \(id) --file PATH.")
                }
                let template = switch kind {
                case .role: ReviewTemplates.role(id)
                case .scenario: ReviewTemplates.scenario(id)
                default: ReviewTemplates.profile.replacingOccurrences(of: "project: my-service\n", with: "project: \(id)\n")
                }
                let text = try readText() ?? template
                // A new brain item over a built-in one replaces it in every project.
                let builtIn = kind == .role ? ReviewBuiltIns.roles.contains { $0.id == id } : kind == .scenario && ReviewBuiltIns.scenarios.contains { $0.id == id }
                if builtIn, level == .brain {
                    out("Note: \(name) \(id) is built into AKit; this text replaces it in every project. To change it instead, "
                        + "akit review \(name) show \(id), edit that text, then akit review \(name) save \(id) --file PATH.")
                }
                return try await finishSave(try ReviewConfigEditor.plan(kind, id: id, text: text, level: level, home: home, brain: brain))
            case "save":
                guard let text = try readText() else { throw Failure(message: "Give the new text: --file PATH, or --file - for stdin.") }
                return try await finishSave(try ReviewConfigEditor.plan(kind, id: id, text: text, level: level, home: home, brain: brain))
            case "duplicate":
                guard let project, kind == .role || kind == .scenario else {
                    throw Failure(message: "akit review \(name) duplicate ID --project P: the brain's \(name) as the project's own copy.")
                }
                if file != nil { throw Failure(message: "duplicate copies the brain's text; use new or save for your own.") }
                if FileManager.default.fileExists(atPath: ReviewConfigEditor.file(kind, id: id, level: level, home: home, brain: brain).path) {
                    throw Failure(message: "\(project) already has its own \(name) \(id).")
                }
                return try await finishSave(try ReviewConfigEditor.duplicate(kind, id: id, toProject: project, catalog: catalog, home: home, brain: brain))
            case "reset":
                guard let project, kind == .role || kind == .scenario else {
                    throw Failure(message: "akit review \(name) reset ID --project P: the project's own copy goes to the Trash.")
                }
                let url = ReviewConfigEditor.file(kind, id: id, level: level, home: home, brain: brain)
                guard FileManager.default.fileExists(atPath: url.path) else { throw Failure(message: "\(project) has no own \(name) \(id).") }
                let target = kind == .role ? url.deletingLastPathComponent() : url
                let inBrain = kind == .role ? catalog.roles.contains { $0.id == id } : catalog.scenarios.contains { $0.id == id }
                let after = inBrain ? "the brain's \(name) \(id) applies again" : "\(project) has no \(name) \(id) any more"
                guard yes else {
                    out("Would move \(target.path) to the Trash; \(after). Run again with --yes to do it.")
                    return 0
                }
                try ReviewConfigEditor.resetToBrain(kind, id: id, project: project, home: home, brain: brain, trash: trash)
                out("Moved \(target.path) to the Trash; \(after).")
                return 0
            default:
                throw Failure(message: "akit review \(name) takes show, new, save, duplicate or reset, not \(action).")
            }
        } catch let failure as ReviewConfigEditor.Failure {
            throw Failure(message: failure.message)
        }
    }
}
