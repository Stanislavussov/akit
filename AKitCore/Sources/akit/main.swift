// `akit` command line: see AKitCLI.usage. All logic lives in the AKit modules
// (docs/design/architecture.md).
import AKitBrain
import AKitCommandLine
import AKitFoundation
import AKitHarnesses
import AKitInsights
import Foundation

// Session hooks: first and alone, so a session start pays only for one appended line
// (no harness detection, no warnings, no output), and always exit 0.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "record-session" {
    RecordSession.main(arguments: Array(CommandLine.arguments.dropFirst(2)))
    exit(0)
}
// The Pi extension's rating: also first, and it reports back (exit 0 = saved).
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "rate" {
    exit(RateRun.main(arguments: Array(CommandLine.arguments.dropFirst(2))))
}
if getuid() == 0 {
    FileHandle.standardError.write(Data("akit: don't run akit with sudo; it works in your own home folder.\n".utf8))
    exit(2)
}
let env = HarnessEnvironment.current
let installed = HarnessCatalog.detectAll(in: env).compactMap { ProjectAnswers.target(for: $0.id) }
// The app's projects folder (Settings), so a project gets the same id in both;
// AKIT_PROJECTS_ROOT overrides it.
let appDefaults = UserDefaults(suiteName: "dev.ussov.akit")
let projectsOverride = env.variables["AKIT_PROJECTS_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
let projectsRoot = env.expand(projectsOverride
    ?? appDefaults?.stringArray(forKey: "projectRoots")?.first
    ?? ProjectFinder.defaultRoots[0])
let preferences = Onboarding.Preferences(
    projectsRoot: { projectsOverride ?? appDefaults?.stringArray(forKey: "projectRoots")?.first },
    // The app's settings belong to the real home; a script with another $HOME doesn't change them.
    setProjectsRoot: { folder in
        guard env.homeDirectory.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL else { return }
        appDefaults?.set([folder], forKey: "projectRoots")
    })
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
