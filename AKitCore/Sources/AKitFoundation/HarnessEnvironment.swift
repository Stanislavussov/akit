import Foundation

/// Everything an adapter needs to know about the machine: home folder, environment
/// variables, where to look for executables. Tests substitute a temporary fake home.
public struct HarnessEnvironment: Sendable {
    public var homeDirectory: URL
    public var variables: [String: String]
    /// Folders searched for executables (`claude`, `pi`).
    public var executableSearchPaths: [URL]

    public init(homeDirectory: URL, variables: [String: String] = [:], executableSearchPaths: [URL] = []) {
        self.homeDirectory = homeDirectory
        self.variables = variables
        self.executableSearchPaths = executableSearchPaths
    }

    /// The real machine.
    /// The process PATH comes first (same order as your terminal). An app launched
    /// from Finder/Dock gets a minimal PATH (`/usr/bin:/bin:...`), so common CLI
    /// install locations are appended after it.
    public static var current: HarnessEnvironment {
        let vars = ProcessInfo.processInfo.environment
        // $HOME when it is set (like other command-line tools), so a script can point akit elsewhere.
        let home = vars["HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let fromPATH = (vars["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(filePath: String($0), directoryHint: .isDirectory) }
        let common = [
            home.appending(path: ".local/bin"),
            home.appending(path: ".local/share/mise/shims"),
            home.appending(path: ".bun/bin"),
            home.appending(path: ".npm-global/bin"),
            home.appending(path: ".volta/bin"),
            URL(filePath: "/opt/homebrew/bin"),
            URL(filePath: "/usr/local/bin"),
        ]
        var seen = Set<String>()
        let paths = (fromPATH + common).filter { seen.insert($0.standardizedFileURL.path).inserted }
        return HarnessEnvironment(homeDirectory: home, variables: vars, executableSearchPaths: paths)
    }

    /// Pi's config folder: `~/.pi/agent`, or the folder from PI_CODING_AGENT_DIR.
    public var piAgentDirectory: URL {
        if let custom = variables["PI_CODING_AGENT_DIR"], !custom.isEmpty { return expand(custom) }
        return homeDirectory.appending(path: ".pi/agent")
    }

    /// `~/x` → full path; absolute paths are returned as is.
    public func expand(_ path: String) -> URL {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return homeDirectory.appending(path: String(path.dropFirst(2))) }
        return URL(filePath: path)
    }

    /// First executable with this name found in the search paths.
    public func findExecutable(_ name: String) -> URL? {
        let fm = FileManager.default
        for dir in executableSearchPaths {
            let candidate = dir.appending(path: name)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// PATH for child processes (e.g. `pi` via a mise shim needs node).
    public var pathForChildProcesses: String {
        executableSearchPaths.map(\.path).joined(separator: ":") + ":/usr/bin:/bin:/usr/sbin:/sbin"
    }
}
