// `akit` command line: see AKitCLI.usage. All logic lives in AKitCore.
import AKitCore
import Foundation

let env = HarnessEnvironment.current
let installed = HarnessCatalog.detectAll(in: env).map { $0.id == .claudeCode ? "claude" : $0.id.rawValue }
    .filter(ProjectAnswers.knownTargets.contains)
// The app's projects folder (Settings), so a project gets the same id in both;
// AKIT_PROJECTS_ROOT overrides it.
let projectsRoot = env.expand(env.variables["AKIT_PROJECTS_ROOT"]
    ?? UserDefaults(suiteName: "dev.ussov.akit")?.stringArray(forKey: "projectRoots")?.first
    ?? ProjectFinder.defaultRoots[0])
let code = await AKitCLI.run(Array(CommandLine.arguments.dropFirst()), env: env,
                             cwd: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
                             projectsRoot: projectsRoot,
                             installedTargets: installed,
                             out: { print($0) },
                             err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
exit(code)
