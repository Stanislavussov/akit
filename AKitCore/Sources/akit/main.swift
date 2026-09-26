// `akit` command line: see AKitCLI.usage. All logic lives in AKitCore.
import AKitCore
import Foundation

let env = HarnessEnvironment.current
let installed = HarnessCatalog.detectAll(in: env).map { $0.id == .claudeCode ? "claude" : $0.id.rawValue }
    .filter(ProjectAnswers.knownTargets.contains)
let code = await AKitCLI.run(Array(CommandLine.arguments.dropFirst()), env: env,
                             cwd: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
                             installedTargets: installed,
                             out: { print($0) },
                             err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
exit(code)
