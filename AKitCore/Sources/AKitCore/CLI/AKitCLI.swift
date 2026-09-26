import Foundation

/// The `akit` command: the brain and project setup for agents and terminals. Same rules
/// as the app: checks before writing, backups, the Trash for removals, answers in the brain.
public enum AKitCLI {
    public static let usage = """
        akit — harness layers from your brain repo (~/.akit/registry)

        Brain:
          akit check                      Read every layer and skill; list problems (exit 1 if any)
          akit layers [--json]            Layers with their fields, skills and files
          akit skills                     Skills in the brain

        Projects (PROJECT is a folder; default: the current one):
          akit answers [PROJECT]          Saved answers for the project (JSON)
          akit plan [PROJECT] [ANSWERS]   What would change, with diffs (exit 1 if it can't apply)
          akit apply [PROJECT] [ANSWERS] [--include PATH]... [--exclude PATH]...
                                          Write it: backup first, removals to the Trash, answers
                                          saved in the brain. Files AKit didn't write, or edited
                                          by hand since, are skipped unless --include PATH.

        ANSWERS (start from the saved answers, or empty):
          --layers a,b          Layers to use (replaces the list)
          --set field=value     A field value; bool: true/false, multi: a,b (repeatable)
          --unset field         Remove a value
          --targets claude,pi   Harnesses (default: saved, else the installed ones)
          --answers FILE        Answers JSON ({"layers":[],"values":{},"targets":[]}) instead

        Options:
          --brain DIR           Brain folder (default: ~/.akit/registry)
          --help
        """

    struct Failure: Error {
        let message: String
    }

    /// Runs one command. `out`/`err` receive text; returns the exit code.
    public static func run(_ arguments: [String], env: HarnessEnvironment, cwd: URL, projectsRoot: URL? = nil,
                           installedTargets: [String] = [], out: (String) -> Void, err: (String) -> Void,
                           trash: (URL) throws -> URL? = SkillRemover.defaultTrash) async -> Int32 {
        do {
            var args = Arguments(arguments)
            if args.flag("--help") || args.flag("-h") || args.isEmpty {
                out(usage)
                return 0
            }
            // Options first, so their values are never taken for the command or the project.
            let options = Options(brain: args.value("--brain"), json: args.flag("--json"), answersFile: args.value("--answers"),
                                  layers: args.value("--layers"), targets: args.value("--targets"),
                                  set: args.values("--set"), unset: args.values("--unset"),
                                  include: args.values("--include"), exclude: args.values("--exclude"))
            let command = args.positional()
            let projectArgument = args.positional()
            try args.finish()
            let brainRoot = options.brain.map { resolve($0, cwd: cwd, env: env) } ?? Brain.defaultRoot(home: env.homeDirectory)
            guard let brain = Brain.load(from: brainRoot) else {
                throw Failure(message: "No brain repo at \(brainRoot.path). Create it in AKit (Brain → Create Brain Repo) or pass --brain.")
            }

            switch command {
            case "check":
                return check(brain, out: out)
            case "layers":
                out(options.json ? try layersJSON(brain) : layersText(brain))
                return 0
            case "skills":
                out(brain.skills.map { "\($0.name)\t\($0.description)" }.joined(separator: "\n"))
                return 0
            case "answers", "plan", "apply":
                let project = resolve(projectArgument ?? ".", cwd: cwd, env: env)
                guard FileManager.default.fileExists(atPath: project.path) else { throw Failure(message: "No folder at \(project.path).") }
                let root = projectsRoot ?? env.homeDirectory.appending(path: "Projects")
                let id = await ProjectSetup.projectID(for: project, projectsRoot: root, env: env)
                if command == "answers" {
                    let saved = ProjectSetup.savedAnswers(id: id, brain: brain.root)
                    out(saved.map(encode) ?? "No saved answers for \(id).")
                    return saved == nil ? 1 : 0
                }
                let answers = try readAnswers(options, id: id, brain: brain, cwd: cwd, env: env, installedTargets: installedTargets)
                let include = Set(options.include), exclude = Set(options.exclude)
                let plan = ProjectSetup.plan(project: project, id: id, answers: answers, brain: brain)
                out(planText(plan))
                guard plan.canApply else { return 1 }
                guard command == "apply" else { return 0 }
                let skipped = Set(plan.changes.filter { $0.kind == .update && ($0.replacesUnmanaged || $0.editedSinceRender) }.map(\.path))
                    .subtracting(include).union(exclude)
                let outcome: ProjectSetup.Outcome
                do {
                    outcome = try await ProjectSetup.apply(plan, excluding: skipped, brain: brain, home: env.homeDirectory, env: env, trash: trash)
                } catch {
                    throw Failure(message: error.message)
                }
                out(outcomeText(outcome, skipped: skipped.intersection(plan.changes.filter { $0.kind != .same }.map(\.path)), id: id))
                return 0
            default:
                throw Failure(message: "Unknown command “\(command ?? "")”. Run akit --help.")
            }
        } catch let failure as Failure {
            err("akit: \(failure.message)")
            return 2
        } catch {
            err("akit: \(error.localizedDescription)")
            return 2
        }
    }

    // MARK: - Brain

    private static func check(_ brain: Brain, out: (String) -> Void) -> Int32 {
        var lines = ["Brain \(brain.root.path): \(brain.layers.count) layers, \(brain.skills.count) skills"]
        if brain.problems.isEmpty {
            lines.append("No problems.")
        } else {
            for problem in brain.problems {
                lines.append("- \(problem.layer.map { "layers/\($0): " } ?? "")\(problem.message)")
            }
        }
        out(lines.joined(separator: "\n"))
        return brain.problems.isEmpty ? 0 : 1
    }

    private static func layersText(_ brain: Brain) -> String {
        brain.layers.map { layer in
            var lines = ["\(layer.name)\(layer.description.isEmpty ? "" : " — \(layer.description)")"]
            if !layer.requires.isEmpty { lines.append("  requires: \(layer.requires.joined(separator: ", "))") }
            if !layer.conflicts.isEmpty { lines.append("  conflicts: \(layer.conflicts.joined(separator: ", "))") }
            for field in layer.fields {
                var line = "  field \(field.id) (\(field.kind.rawValue)\(field.required ? ", required" : "")): \(field.prompt)"
                if !field.options.isEmpty { line += " [\(field.options.joined(separator: ", "))]" }
                if let value = field.defaultValue { line += " default \(value.display)" }
                lines.append(line)
            }
            for skill in layer.skills {
                lines.append("  skill \(skill.name) \(skill.mode.rawValue)\(skill.when.isEmpty ? "" : " when \(skill.when.map(\.description).joined(separator: " and "))")")
            }
            for file in layer.files {
                lines.append("  file \(file.template) → \(file.to)\(file.when.isEmpty ? "" : " when \(file.when.map(\.description).joined(separator: " and "))")")
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private struct LayerInfo: Encodable {
        struct Field: Encodable { let id, prompt, type: String; let required: Bool; let options: [String]; let `default`: FieldValue? }
        struct Skill: Encodable { let name, mode: String; let when: [String] }
        struct File: Encodable { let template, to: String; let when: [String] }
        let name, description: String
        let requires, conflicts: [String]
        let fields: [Field]
        let skills: [Skill]
        let files: [File]
        let folder: String
        let problems: [String]
    }

    private static func layersJSON(_ brain: Brain) throws -> String {
        let infos = brain.layers.map { layer in
            LayerInfo(name: layer.name, description: layer.description, requires: layer.requires, conflicts: layer.conflicts,
                      fields: layer.fields.map { .init(id: $0.id, prompt: $0.prompt, type: $0.kind.rawValue, required: $0.required,
                                                       options: $0.options, default: $0.defaultValue) },
                      skills: layer.skills.map { .init(name: $0.name, mode: $0.mode.rawValue, when: $0.when.map(\.description)) },
                      files: layer.files.map { .init(template: $0.template, to: $0.to, when: $0.when.map(\.description)) },
                      folder: layer.folder.path, problems: brain.problems(of: layer.name).map(\.message))
        }
        return encode(infos)
    }

    // MARK: - Answers

    struct Options {
        var brain: String?
        var json: Bool
        var answersFile: String?
        var layers: String?
        var targets: String?
        var set: [String]
        var unset: [String]
        var include: [String]
        var exclude: [String]
    }

    private static func readAnswers(_ options: Options, id: String, brain: Brain, cwd: URL, env: HarnessEnvironment,
                                    installedTargets: [String]) throws -> ProjectAnswers {
        if let file = options.answersFile {
            let url = resolve(file, cwd: cwd, env: env)
            do {
                return try JSONDecoder().decode(ProjectAnswers.self, from: Data(contentsOf: url))
            } catch {
                throw Failure(message: "Can't read answers from \(url.path): \(error.localizedDescription)")
            }
        }
        var answers = ProjectSetup.savedAnswers(id: id, brain: brain.root)
            ?? ProjectAnswers(layers: [], values: [:], targets: installedTargets)
        if let layers = options.layers { answers.layers = list(layers) }
        if let targets = options.targets {
            answers.targets = list(targets)
            for target in answers.targets where !ProjectAnswers.knownTargets.contains(target) {
                throw Failure(message: "Unknown target “\(target)” (\(ProjectAnswers.knownTargets.joined(separator: ", "))).")
            }
        }
        let fields = Dictionary(brain.layers.flatMap(\.fields).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for pair in options.set {
            guard let equals = pair.firstIndex(of: "=") else { throw Failure(message: "--set wants field=value, got “\(pair)”.") }
            let key = String(pair[..<equals]), raw = String(pair[pair.index(after: equals)...])
            guard let field = fields[key] else { throw Failure(message: "No layer has a field “\(key)”.") }
            switch field.kind {
            case .bool:
                guard let flag = ["true": true, "yes": true, "false": false, "no": false][raw.lowercased()] else {
                    throw Failure(message: "\(key) is a bool: use true or false.")
                }
                answers.values[key] = .bool(flag)
            case .multi:
                let items = list(raw)
                if let bad = items.first(where: { !field.options.contains($0) }) {
                    throw Failure(message: "“\(bad)” is not an option of \(key) (\(field.options.joined(separator: ", "))).")
                }
                answers.values[key] = .list(items)
            case .choice:
                guard field.options.contains(raw) else {
                    throw Failure(message: "“\(raw)” is not an option of \(key) (\(field.options.joined(separator: ", "))).")
                }
                answers.values[key] = .text(raw)
            case .text:
                answers.values[key] = .text(raw)
            }
        }
        for key in options.unset { answers.values[key] = nil }
        return answers
    }

    // MARK: - Output

    static func planText(_ plan: ProjectSetup.Plan) -> String {
        var lines = ["Project \(plan.project.path) (brain: projects/\(plan.id))",
                     "Layers: \(plan.render.layers.isEmpty ? "none" : plan.render.layers.joined(separator: ", ")) · targets: \(plan.answers.targets.joined(separator: ", "))"]
        for error in plan.render.errors { lines.append("ERROR: \(error)") }
        for blocker in plan.blockers { lines.append("BLOCKED: \(blocker)") }
        for warning in plan.render.warnings { lines.append("warning: \(warning)") }
        let changed = plan.changes.filter { $0.kind != .same }
        if changed.isEmpty { lines.append("No changes.") }
        for change in changed {
            var note = ""
            if change.kind == .update && change.replacesUnmanaged { note = "  (AKit didn't write it: skipped unless --include)" }
            if change.kind == .update && change.editedSinceRender { note = "  (edited by hand since the last render: skipped unless --include)" }
            lines.append("")
            lines.append("\(label(change.kind)) \(change.path)\(note)")
            let new = change.kind == .remove || change.kind == .keepEdited ? "" : change.newText ?? ""
            if change.oldText != nil || change.newText != nil {
                lines += unifiedDiff(TextDiff.lines(from: change.oldText ?? "", to: new))
            }
        }
        let same = plan.changes.count - changed.count
        if same > 0 { lines.append("\n\(same) file\(same == 1 ? "" : "s") unchanged.") }
        return lines.joined(separator: "\n")
    }

    private static func label(_ kind: ProjectSetup.Change.Kind) -> String {
        switch kind {
        case .create: "NEW"
        case .update: "CHANGED"
        case .same: "SAME"
        case .remove: "REMOVE (to the Trash)"
        case .keepEdited: "KEEP (no longer rendered, but edited by hand)"
        }
    }

    /// Changed lines with 3 lines of context, like `diff -u` without headers.
    static func unifiedDiff(_ diff: [TextDiff.Line]) -> [String] {
        let changed = diff.indices.filter { if case .same = diff[$0] { false } else { true } }
        var result: [String] = []
        var last = -1
        for index in diff.indices where changed.contains(where: { abs($0 - index) <= 3 }) {
            if last >= 0, index > last + 1 { result.append("  …") }
            switch diff[index] {
            case .same(let text): result.append("  " + text)
            case .added(let text): result.append("+ " + text)
            case .removed(let text): result.append("- " + text)
            }
            last = index
        }
        return result
    }

    private static func outcomeText(_ outcome: ProjectSetup.Outcome, skipped: Set<String>, id: String) -> String {
        var lines = ["", "Applied: \(outcome.written.count) written, \(outcome.removed.count) moved to the Trash."]
        if !skipped.isEmpty { lines.append("Skipped: \(skipped.sorted().joined(separator: ", "))") }
        if let backup = outcome.backup { lines.append("Backup: \(backup.path)") }
        lines += outcome.notes.map { "Note: \($0)" }
        lines.append("Answers saved in the brain under projects/\(id). Commit the harness files in the project.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func resolve(_ path: String, cwd: URL, env: HarnessEnvironment) -> URL {
        if path.hasPrefix("~") || path.hasPrefix("/") { return env.expand(path).standardizedFileURL }
        return cwd.appending(path: path).standardizedFileURL
    }

    /// Minimal argument reader: flags and `--key value` anywhere, positionals in order.
    struct Arguments {
        private var items: [String]
        init(_ items: [String]) { self.items = items }
        var isEmpty: Bool { items.isEmpty }

        mutating func flag(_ name: String) -> Bool {
            guard let index = items.firstIndex(of: name) else { return false }
            items.remove(at: index)
            return true
        }

        mutating func value(_ name: String) -> String? { values(name).last }

        mutating func values(_ name: String) -> [String] {
            var found: [String] = []
            while let index = items.firstIndex(of: name), index + 1 < items.count {
                found.append(items[index + 1])
                items.removeSubrange(index...index + 1)
            }
            return found
        }

        mutating func positional() -> String? {
            guard let index = items.firstIndex(where: { !$0.hasPrefix("--") }) else { return nil }
            return items.remove(at: index)
        }

        func finish() throws {
            if let extra = items.first { throw Failure(message: "Unexpected “\(extra)”. Run akit --help.") }
        }
    }
}
