// `akit` command line: see AKitCLI.usage. All logic lives in AKitCore.
import AKitCore
import Foundation

let env = HarnessEnvironment.current
let installed = HarnessCatalog.detectAll(in: env).map { $0.id == .claudeCode ? "claude" : $0.id.rawValue }
    .filter(ProjectAnswers.knownTargets.contains)
// The app's projects folder (Settings), so a project gets the same id in both;
// AKIT_PROJECTS_ROOT overrides it.
let appDefaults = UserDefaults(suiteName: "dev.ussov.akit")
let projectsOverride = env.variables["AKIT_PROJECTS_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
let projectsRoot = env.expand(projectsOverride
    ?? appDefaults?.stringArray(forKey: "projectRoots")?.first
    ?? ProjectFinder.defaultRoots[0])
let preferences = Onboarding.Preferences(
    projectsRoot: { projectsOverride ?? appDefaults?.stringArray(forKey: "projectRoots")?.first },
    setProjectsRoot: { appDefaults?.set([$0], forKey: "projectRoots") })
// Questions only when a person is typing (not in scripts or CI).
let ask: ((String) -> String?)? = isatty(0) != 0 ? { question in
    print(question, terminator: " ")
    fflush(stdout)
    return readLine()
} : nil
let code = await AKitCLI.run(Array(CommandLine.arguments.dropFirst()), env: env,
                             cwd: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
                             projectsRoot: projectsRoot,
                             installedTargets: installed,
                             out: { print($0) },
                             err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
                             ask: ask, preferences: preferences)
exit(code)
