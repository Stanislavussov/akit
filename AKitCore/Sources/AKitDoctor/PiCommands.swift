import AKitFoundation
import Foundation

/// The few `pi` commands AKit runs for the user, so every fix Pi doctor suggests is an `akit`
/// command (`akit pi packages install|remove`) or a button
/// that runs the same thing. AKit only starts `pi` with fixed arguments and reports how it ended:
/// Pi does the work and keeps its own files, and AKit never reads a token. Flags checked against
/// `pi install|remove|update --help` (1.0.4) and packages.md. MCP sign-in is `MCPApprove.signIn`.
public enum PiCommands {
    /// What a fix runs: the shown command line is exactly what is started.
    public enum Action: Codable, Hashable, Sendable {
        /// `pi update --extensions`: installs every package the settings list (packages.md:
        /// "reconcile package installations").
        case installMissingPackages
        /// `pi install SOURCE [-l]`: installs it and adds it to the settings (in the project with `-l`).
        case installPackage(source: String, project: String?)
        /// `pi remove SOURCE [-l]`: removes it and its entry.
        case removePackage(source: String, project: String?)

        /// The `akit` command that does the same.
        public var akitCommand: String {
            switch self {
            case .installMissingPackages: "akit pi packages install"
            case .installPackage(let source, let project):
                "akit pi packages install \(PiDoctor.shellQuoted(source))\(project.map { " --project \(PiDoctor.shellQuoted($0))" } ?? "")"
            case .removePackage(let source, let project):
                "akit pi packages remove \(PiDoctor.shellQuoted(source))\(project.map { " --project \(PiDoctor.shellQuoted($0))" } ?? "")"
            }
        }

        /// A button title for the sheet.
        public var title: String {
            switch self {
            case .installMissingPackages: "Install Missing Packages…"
            case .installPackage: "Install…"
            case .removePackage: "Remove…"
            }
        }

        /// `pi`'s arguments.
        public var arguments: [String] {
            switch self {
            case .installMissingPackages: ["update", "--extensions"]
            case .installPackage(let source, let project): ["install", source] + (project == nil ? [] : ["-l"])
            case .removePackage(let source, let project): ["remove", source] + (project == nil ? [] : ["-l"])
            }
        }

        /// The folder it runs in: the project for a project package (Pi's `-l` means `.pi/` there).
        public func directory(home: URL) -> URL {
            switch self {
            case .installPackage(_, let project?), .removePackage(_, let project?): URL(filePath: project, directoryHint: .isDirectory)
            default: home
            }
        }

        /// Installs fetch from npm or git.
        var timeout: TimeInterval { 600 }

        /// What runs, for the user to read before saying yes.
        public func shown(home: URL) -> String {
            let place = directory(home: home)
            let command = (["pi"] + arguments).map(PiDoctor.shellQuoted).joined(separator: " ")
            return place.standardizedFileURL.path == home.standardizedFileURL.path ? command
                : "\(command)  (in \(FileWalk.tilde(place, home: home)))"
        }
    }

    public struct Outcome: Sendable {
        public let succeeded: Bool
        /// Pi's output, through `SecretFilter.masked`.
        public let output: String

        public init(succeeded: Bool, output: String) {
            self.succeeded = succeeded
            self.output = output
        }
    }

    /// Runs the action with `pi` from `executable` (nil: found on the environment's PATH).
    public static func run(_ action: Action, env: HarnessEnvironment, executable: URL? = nil) async -> Outcome {
        guard let pi = executable ?? env.findExecutable("pi") else {
            return Outcome(succeeded: false, output: "pi isn't on PATH.")
        }
        var variables = env.variables
        variables["PATH"] = env.pathForChildProcesses
        variables["NO_COLOR"] = "1"
        guard let result = await ProcessRunner.run(pi, arguments: action.arguments, directory: action.directory(home: env.homeDirectory),
                                                   environment: variables, timeout: action.timeout) else {
            return Outcome(succeeded: false, output: "pi couldn't be started.")
        }
        let output = SecretFilter.masked(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        if result.timedOut { return Outcome(succeeded: false, output: "pi didn't finish in \(Int(action.timeout)) s and was stopped.\n" + output) }
        return Outcome(succeeded: result.succeeded, output: output)
    }
}
