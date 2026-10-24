import AKitDoctor
import AKitFoundation
import AKitHarnesses
import AKitSkills
import Foundation

/// `akit pi packages [install [SOURCE] | remove SOURCE]`: Pi's packages, listed by AKit and
/// installed or removed by `pi` itself (packages.md). AKit shows the exact `pi` command first and
/// runs it only with `--yes`; Pi changes its settings and package folders.
extension AKitCLI {
    static let piUsage = "Use: akit pi packages [--json] | akit pi packages install [SOURCE] [--project PATH] [--yes] | akit pi packages remove SOURCE [--project PATH] [--yes]"

    static func pi(_ args: inout Arguments, yes: Bool, json: Bool, env: HarnessEnvironment, cwd: URL, projectsRoot: URL,
                   out: (String) -> Void) async throws -> Int32 {
        let projectPath = args.value("--project")
        guard args.positional() == "packages" else { throw Failure(message: piUsage) }
        let action = args.positional()
        let source = args.positional()
        try args.finish()
        let project = projectPath.map { resolve($0, cwd: cwd, env: env).standardizedFileURL.path }
        if let project, !FileWalk.isDirectory(URL(filePath: project)) { throw Failure(message: "No folder at \(project).") }
        switch action {
        case nil:
            if yes || project != nil { throw Failure(message: piUsage) }
            return piPackagesList(json: json, env: env, projectsRoot: projectsRoot, out: out)
        case "install":
            if json { throw Failure(message: "--json goes only with akit pi packages.") }
            if source == nil, project != nil { throw Failure(message: "akit pi packages install without SOURCE installs every missing package; it takes no --project.") }
            return await runPiAction(source.map { .installPackage(source: $0, project: project) } ?? .installMissingPackages,
                                     yes: yes, env: env, out: out)
        case "remove":
            guard let source, !json else { throw Failure(message: piUsage) }
            return await runPiAction(.removePackage(source: source, project: project), yes: yes, env: env, out: out)
        default:
            throw Failure(message: piUsage)
        }
    }

    /// Every package in Pi's settings (global, then projects Pi or the projects folder knows), installed or not.
    static func piPackagesList(json: Bool, env: HarnessEnvironment, projectsRoot: URL, out: (String) -> Void) -> Int32 {
        let home = env.homeDirectory
        let installations = HarnessCatalog.detectAll(in: env)
        let projects = SkillScanner.projects(installations: installations, extraProjects: ProjectFinder.projects(inRoots: [projectsRoot]), in: env)
        let listing = PiPackages.list(configRoot: env.piAgentDirectory, projects: projects, in: env)
        struct Row: Encodable {
            let source: String, name: String, version: String?, installed: Bool, settings: String, project: String?
        }
        let rows = listing.packages.map { package -> Row in
            let project: String? = if case .project(let url) = package.scope { url.path } else { nil }
            return Row(source: package.source, name: package.name, version: package.version, installed: package.isInstalled,
                       settings: FileWalk.tilde(package.settingsFile, home: home), project: project)
        }
        if json {
            out(encode(rows))
            return 0
        }
        var lines = rows.isEmpty ? ["No Pi packages in Pi's settings."] : rows.map { row in
            "\(row.installed ? "  " : "! ")\(row.source)  \(row.installed ? "\(row.name)\(row.version.map { " \($0)" } ?? "")" : "not installed")"
                + (row.project.map { "  (project \(FileWalk.tilde(URL(filePath: $0), home: home)))" } ?? "")
        }
        lines += listing.notes
        if rows.contains(where: { !$0.installed }) {
            lines.append("akit pi packages install installs the missing ones (pi update --extensions).")
        }
        out(lines.joined(separator: "\n"))
        return 0
    }
}
