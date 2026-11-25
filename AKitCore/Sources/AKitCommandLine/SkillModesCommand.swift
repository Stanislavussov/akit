import AKitBrain
import AKitFoundation
import AKitHarnesses
import AKitModel
import AKitProjectSetup
import AKitSkills
import Foundation

/// `akit skills mode`, `akit skills resolve` and `akit skills extension` (skill-modes.md): a
/// skill's mode per project in `~/.akit/local/skill-modes.json`, applied in Pi by its extension.
extension AKitCLI {
    static let skillModeUsage = """
        Use: akit skills mode [--project PATH] [--json]
             akit skills mode NAME auto|manual|off [--project PATH] [--yes] [--json]
             akit skills mode NAME --reset [--project PATH] [--yes] [--json]
             akit skills mode --reset-project [--project PATH] [--yes] [--json]
             akit skills mode NAME auto|manual --global [--yes]
        """
    static let skillsResolveUsage = "Use: akit skills resolve --harness pi --cwd DIR [--json] < {\"skills\":[{\"name\",\"scope\",\"origin\",\"path\"}]}"

    // MARK: - resolve (the Pi extension's ask)

    /// `akit skills resolve --harness pi --cwd DIR --json`: the loaded skills on stdin, the
    /// project's modes on stdout. Reads one small file and walks `.git`; no brain, no harness
    /// detection (the akit binary runs it first, main.swift). Exit 0 when the arguments are
    /// valid (a bad stdin is a problem in the answer), 2 on a usage error.
    public static func skillsResolve(_ arguments: [String], env: HarnessEnvironment, projectsRoot: URL, input: () -> Data,
                                     out: (String) -> Void, err: (String) -> Void) -> Int32 {
        var harness: String?, cwd: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json": break
            case "--harness", "--cwd":
                guard index + 1 < arguments.count else {
                    err("akit: \(argument) needs a value. \(skillsResolveUsage)")
                    return 2
                }
                index += 1
                if argument == "--harness" { harness = arguments[index] } else { cwd = arguments[index] }
            default:
                err("akit: unexpected “\(argument)”. \(skillsResolveUsage)")
                return 2
            }
            index += 1
        }
        guard harness == "pi" else {
            err("akit: \(harness == nil ? "--harness pi is needed" : "only --harness pi has skill modes"). \(skillsResolveUsage)")
            return 2
        }
        guard let cwd, !cwd.isEmpty else {
            err("akit: --cwd DIR is needed. \(skillsResolveUsage)")
            return 2
        }
        let folder = cwd.hasPrefix("/") ? URL(filePath: cwd, directoryHint: .isDirectory) : env.expand(cwd)
        let project = ProjectRecords.projectID(ofFolder: folder, projectsRoot: projectsRoot.path)
        let reading = SkillModes.read(SkillModes.file(home: env.homeDirectory), home: env.homeDirectory)
        struct Request: Decodable { let skills: [SkillModes.LoadedSkill] }
        guard let request = try? JSONDecoder().decode(Request.self, from: input()) else {
            var answer = SkillModes.Resolution(project: project)
            answer.problems = [.init(kind: "input", message: "stdin is not {\"skills\":[…]}; no skill modes apply.")]
            out(answer.json)
            return 0
        }
        out(SkillModes.resolve(file: reading, skills: request.skills, projectID: project,
                               userFolders: SkillModes.piUserFolders(in: env)).json)
        return 0
    }

    // MARK: - mode

    struct ModeRow: Encodable {
        let name: String
        let mode: SkillMode
        /// `project` (an entry) or `skill` (its SKILL.md).
        let from: String
        /// `yours`, `project` or `package`.
        let source: String
        let file: String
        /// A rename: the name the project's skill keeps.
        var renamedFrom: String?
    }

    struct ModeList: Encodable {
        let project: String?
        let file: String
        let fileUsable: Bool
        let `extension`: SkillModesExtension.State
        let extensionFile: String
        let skills: [ModeRow]
        /// Entries of the project no skill here has, with their mode.
        let notFound: [String: SkillMode]
        let problems: [SkillModes.Problem]
    }

    static func skillModes(_ args: inout Arguments, json: Bool, yes: Bool, brainRoot: URL, env: HarnessEnvironment, cwd: URL,
                           projectsRoot: URL, hostName: String, installedTargets: [String], out: (String) -> Void,
                           trash: @escaping (URL) throws -> URL?) async throws -> Int32 {
        let reset = args.flag("--reset"), resetProject = args.flag("--reset-project"), global = args.flag("--global")
        let projectPath = args.value("--project")
        let name = args.positional(), word = args.positional()
        try args.finish()
        let home = env.homeDirectory
        if global {
            guard let name, let word, !reset, !resetProject, projectPath == nil else { throw Failure(message: skillModeUsage) }
            if json { throw Failure(message: "--json doesn't go with --global.") }
            return try await globalMode(name, word: word, yes: yes, brainRoot: brainRoot, env: env, projectsRoot: projectsRoot,
                                        hostName: hostName, installedTargets: installedTargets, out: out, trash: trash)
        }
        let folder = projectPath.map { resolve($0, cwd: cwd, env: env) } ?? cwd
        guard FileWalk.isDirectory(folder) else { throw Failure(message: "No folder at \(folder.path).") }
        let project = ProjectRecords.projectID(ofFolder: folder, projectsRoot: projectsRoot.path)

        // The list.
        if name == nil, !reset, !resetProject {
            if yes { throw Failure(message: skillModeUsage) }
            let list = modeList(folder: folder, project: project, env: env)
            out(json ? encode(list) : modeListText(list, home: home))
            return 0
        }
        guard let project else {
            throw Failure(message: "\(FileWalk.tilde(folder, home: home)) is not in a git repository. Skill modes are per project (a repository); outside one only the skill's SKILL.md applies.")
        }
        let plan: SkillModes.Plan
        var warnings: [String] = []
        do {
            if resetProject {
                guard name == nil, word == nil, !reset else { throw Failure(message: skillModeUsage) }
                plan = try SkillModes.plan(resetProject: project, home: home)
            } else if reset {
                guard let name, word == nil else { throw Failure(message: skillModeUsage) }
                plan = try SkillModes.plan(reset: name, project: project, home: home)
            } else {
                guard let name, let word else { throw Failure(message: skillModeUsage) }
                guard let mode = SkillMode(rawValue: word) else { throw Failure(message: "The mode is auto, manual or off. \(skillModeUsage)") }
                plan = try SkillModes.plan(set: mode, name: name, project: project, home: home)
                let list = modeList(folder: folder, project: project, env: env)
                if !list.skills.contains(where: { $0.name == name }) {
                    warnings.append("No skill named \(name) is loaded here by Pi; the entry applies once one is (akit skills mode lists them).")
                }
            }
        } catch let error as SkillModes.Failure {
            throw Failure(message: error.message)
        }
        let state = SkillModesExtension(env: env).status().state
        if state != .current {
            warnings.append(state == .missing ? "The Pi extension that applies skill modes is not installed: akit skills extension install"
                            : "The Pi extension that applies skill modes is \(state.rawValue): akit skills extension install")
        }
        var backup: URL?
        let written = yes && !plan.changesNothing
        if written {
            do { backup = try SkillModes.apply(plan, home: home) } catch { throw Failure(message: error.message) }
        }
        if json {
            struct Result: Encodable {
                let project: String, summary: String, file: String, changes: Bool, written: Bool
                let backup: String?, diff: [String], warnings: [String]
            }
            out(encode(Result(project: project, summary: plan.summary, file: plan.file.path, changes: !plan.changesNothing, written: written,
                              backup: backup?.path, diff: TextDiff.unified(plan.diff), warnings: warnings)))
            return 0
        }
        var lines = [plan.summary + (plan.changesNothing ? ". Nothing to do." : ".")]
        if !plan.changesNothing {
            lines.append("\(plan.creates ? "Creates" : "Changes") \(FileWalk.tilde(plan.file, home: home)):")
            lines += TextDiff.unified(plan.diff)
        }
        lines += warnings.map { "note: \($0)" }
        if !plan.changesNothing {
            lines.append(written ? "Done.\(backup.map { " A backup is in \(FileWalk.tilde($0, home: home))." } ?? "") Pi uses it from its next run."
                         : "Run again with --yes to do it.")
        }
        out(lines.joined(separator: "\n"))
        return 0
    }

    /// The skills Pi loads in `folder`, in Pi's order of precedence (project, yours, packages; the
    /// first of a name wins), as the extension would report them.
    static func piSkillsHere(folder: URL, env: HarnessEnvironment) -> [SkillModes.LoadedSkill] {
        let installations = HarnessCatalog.detectAll(in: env).filter { $0.id == .pi }
        guard !installations.isEmpty else { return [] }
        let here = folder.standardizedFileURL.path
        func isHere(_ url: URL?) -> Bool { url.map { $0.standardizedFileURL.path == here } ?? false }
        var ranked: [(rank: Int, skill: SkillModes.LoadedSkill)] = []
        for skill in SkillScanner.scan(installations: installations, projects: [folder], in: env) where skill.visibleTo.contains(.pi) {
            let place = skill.places[.pi]
            let path = (place?.file ?? skill.file).path
            switch place?.scope ?? skill.scope {
            case .project(let url) where isHere(url):
                ranked.append((0, .init(name: skill.name, scope: "project", origin: "top-level", path: path)))
            case .global:
                ranked.append((1, .init(name: skill.name, scope: "user", origin: "top-level", path: path)))
            case .package(_, let project) where project == nil || isHere(project):
                ranked.append((2, .init(name: skill.name, scope: project == nil ? "user" : "project", origin: "package", path: path)))
            default:
                continue
            }
        }
        var seen = Set<String>()
        return ranked.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element.skill).filter { seen.insert($0.name).inserted }
    }

    static func modeList(folder: URL, project: String?, env: HarnessEnvironment) -> ModeList {
        let home = env.homeDirectory
        let file = SkillModes.file(home: home)
        let reading = SkillModes.read(file, home: home)
        let skills = piSkillsHere(folder: folder, env: env)
        let resolution = SkillModes.resolve(file: reading, skills: skills, projectID: project, userFolders: SkillModes.piUserFolders(in: env))
        var rows: [ModeRow] = []
        for skill in skills {
            let source = skill.origin == "package" ? "package" : skill.scope == "project" ? "project" : "yours"
            let own: SkillMode = (skill.path.flatMap { FileWalk.head(of: URL(filePath: $0), limit: 256 << 10) }
                .map { Frontmatter.disablesModelInvocation(String(decoding: $0, as: UTF8.self)) } ?? false) ? .manual : .auto
            let entry = resolution.modes[skill.name]
            rows.append(ModeRow(name: skill.name, mode: entry ?? own, from: entry == nil ? "skill" : "project", source: source,
                                file: skill.path ?? ""))
        }
        for (name, rename) in resolution.renames.sorted(by: { $0.key < $1.key }) {
            rows.append(ModeRow(name: name, mode: rename.mode, from: rename.from, source: "yours", file: rename.file, renamedFrom: rename.original))
        }
        rows.sort { $0.name < $1.name }
        let names = Set(rows.map(\.name))
        let notFound = reading.entries(for: project).filter { !names.contains($0.key) }
        return ModeList(project: project, file: file.path, fileUsable: reading.usable, extension: SkillModesExtension(env: env).status().state,
                        extensionFile: SkillModesExtension(env: env).file.path, skills: rows, notFound: notFound, problems: resolution.problems)
    }

    static func modeListText(_ list: ModeList, home: URL) -> String {
        let file = FileWalk.tilde(URL(filePath: list.file), home: home)
        var lines = [list.project.map { "Skill modes in \($0) (\(file)):" }
                     ?? "Not in a git repository: no project, so each skill's SKILL.md decides."]
        if list.skills.isEmpty { lines.append("  No skills Pi loads here (is Pi installed?).") }
        let width = min(list.skills.map(\.name.count).max() ?? 0, 40)
        for row in list.skills {
            let name = row.name.padding(toLength: max(width, row.name.count), withPad: " ", startingAt: 0)
            let mode = row.mode.title.padding(toLength: 6, withPad: " ", startingAt: 0)
            let from = (row.from == "project" ? "project" : "SKILL.md").padding(toLength: 8, withPad: " ", startingAt: 0)
            let source = row.source.padding(toLength: 7, withPad: " ", startingAt: 0)
            let renamed = row.renamedFrom.map { "  (yours; the project's \($0) has the name)" } ?? ""
            lines.append("  \(name)  \(mode)  from \(from)  \(source)  \(FileWalk.tilde(URL(filePath: row.file), home: home))\(renamed)")
        }
        for (name, mode) in list.notFound.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(name): \(mode.title), not found here")
        }
        lines += list.problems.map { "! \($0.message)" }
        switch list.extension {
        case .current: break
        case .missing: lines.append("! The Pi extension that applies skill modes is not installed: akit skills extension install")
        case .outdated: lines.append("! The Pi extension that applies skill modes is outdated: akit skills extension install")
        case .foreign: lines.append("! \(FileWalk.tilde(URL(filePath: list.extensionFile), home: home)) is not AKit's; skill modes may not apply.")
        }
        return lines.joined(separator: "\n")
    }

    /// `--global`: the skill's own SKILL.md, through Model invocation (`SkillInvocation`).
    static func globalMode(_ name: String, word: String, yes: Bool, brainRoot: URL, env: HarnessEnvironment, projectsRoot: URL,
                           hostName: String, installedTargets: [String], out: (String) -> Void,
                           trash: @escaping (URL) throws -> URL?) async throws -> Int32 {
        if word == SkillMode.off.rawValue {
            throw Failure(message: "--global off isn't a skill mode: the skill's file has only Auto and Manual. To turn it off in Pi everywhere: akit skills set \(name) --harness pi --state off")
        }
        guard let mode = SkillMode(rawValue: word) else { throw Failure(message: "--global takes auto or manual.") }
        let context = await skillContext(brainRoot: brainRoot, env: env, projectsRoot: projectsRoot, hostName: hostName,
                                         installedTargets: installedTargets)
        let matches = context.installed.filter { $0.name == name && $0.scope == .global }
        guard let skill = matches.first else { throw Failure(message: "No skill of yours named \(name) (a global one: ~/.agents/skills, ~/.claude/skills, ~/.pi/agent/skills).") }
        if matches.count > 1 {
            let places = matches.map { FileWalk.tilde($0.file, home: env.homeDirectory) }.joined(separator: ", ")
            throw Failure(message: "Several skills of yours named \(name): \(places). Change the one you mean on the Skills screen.")
        }
        let brain = Brain.load(from: brainRoot)
        let link = brain.flatMap { BrainLinks.links(for: [skill], brain: $0, folders: context.projectFolders, store: context.store)[skill.id] }
        let plan: SkillInvocation.Plan
        do {
            plan = try SkillInvocation.plan(skill, link: link, manual: mode == .manual, brain: brain, context: context)
        } catch {
            throw Failure(message: error.message)
        }
        if plan.changesNothing {
            out("\(name) is already \(mode.title) everywhere (its SKILL.md). Nothing to do.")
            return 0
        }
        var lines = ["\(name) everywhere: \(mode.title) (its SKILL.md\(plan.layer.map { ", through the \($0) layer" } ?? "")):"]
        for diff in plan.diffs {
            lines.append(diff.title)
            lines += TextDiff.unified(diff.lines)
        }
        lines += plan.notes.map { "note: \($0)" }
        if !yes {
            lines.append("Run again with --yes to do it.")
            out(lines.joined(separator: "\n"))
            return 0
        }
        let backup: URL?
        do {
            backup = try await SkillInvocation.apply(plan, brain: brain, env: env, trash: trash)
        } catch {
            throw Failure(message: error.message)
        }
        lines.append("Done.\(backup.map { " A backup is in \(FileWalk.tilde($0, home: env.homeDirectory))." } ?? "")")
        out(lines.joined(separator: "\n"))
        return 0
    }

    // MARK: - extension

    static func skillModesExtension(_ args: inout Arguments, json: Bool, yes: Bool, env: HarnessEnvironment, out: (String) -> Void,
                                    trash: (URL) throws -> URL?) throws -> Int32 {
        let use = "Use: akit skills extension install|status|uninstall [--yes] [--json]"
        guard let action = args.positional() else { throw Failure(message: use) }
        try args.finish()
        let installer = SkillModesExtension(env: env)
        let home = env.homeDirectory
        if action == "status" {
            if yes { throw Failure(message: use) }
            let status = installer.status()
            if json {
                out(encode(status))
            } else {
                let shown = FileWalk.tilde(URL(filePath: status.path), home: home)
                let what = switch status.state {
                case .missing: "not installed (akit skills extension install)"
                case .current: "installed, current"
                case .outdated: "installed, outdated (akit skills extension install)"
                case .foreign: "a file AKit didn't write is there; left alone"
                }
                out("Pi skill modes extension \(shown): \(what)\(status.piFound ? "" : "; Pi was not found").")
            }
            return 0
        }
        let plan: SkillModesExtension.Plan
        switch action {
        case "install":
            do { plan = try installer.installPlan() } catch { throw Failure(message: error.message) }
        case "uninstall":
            plan = installer.uninstallPlan()
        default:
            throw Failure(message: use)
        }
        var backup: URL?
        let written = yes && !plan.isEmpty
        if written {
            do { backup = try installer.execute(plan, trash: trash) } catch { throw Failure(message: error.message) }
        }
        if json {
            struct Result: Encodable { let action: String, file: String, changes: Bool, written: Bool, backup: String?, plan: String }
            out(encode(Result(action: action, file: plan.file.path, changes: !plan.isEmpty, written: written, backup: backup?.path,
                              plan: plan.text(home: home))))
            return 0
        }
        var lines = [plan.text(home: home)]
        if !plan.isEmpty {
            lines.append(written ? "Done.\(backup.map { " The old file is in \(FileWalk.tilde($0, home: home))." } ?? "")"
                         : "Run again with --yes to do it.")
        }
        out(lines.joined(separator: "\n"))
        return 0
    }
}
