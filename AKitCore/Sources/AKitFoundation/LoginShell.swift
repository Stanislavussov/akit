import Foundation

/// The environment of the user's login shell: what a harness started from a terminal gets.
/// AKit.app started from the Dock has none of the variables `~/.zshrc` exports, so a check
/// with the app's own environment would fail where a terminal works.
public enum LoginShell {
    public struct Variables: Sendable {
        public let values: [String: String]
        /// Set when the shell's environment couldn't be read and AKit's own is used.
        public let note: String?
    }

    static let marker = "__AKIT_LOGIN_SHELL_ENV__"

    /// Runs `$SHELL -l -i -c` once and reads `env -0` after a marker, so whatever the startup
    /// files print doesn't matter. Falls back to AKit's own environment, with a note.
    public static func variables(in env: HarnessEnvironment, timeout: TimeInterval = 30) async -> Variables {
        let shell = env.variables["SHELL"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) } ?? URL(filePath: "/bin/zsh")
        let script = "printf '\\n%s\\n' \(marker); /usr/bin/env -0"
        let base = env.variables.merging(["HOME": env.homeDirectory.path, "PATH": env.pathForChildProcesses]) { $1 }
        if let result = await ProcessRunner.run(shell, arguments: ["-l", "-i", "-c", script], directory: env.homeDirectory,
                                                environment: base, timeout: timeout),
           !result.timedOut, let values = parse(result.output) {
            return Variables(values: values, note: nil)
        }
        return Variables(values: env.variables,
                         note: "AKit couldn't read your login shell's environment (\(shell.path)), so the check ran with AKit's own.")
    }

    /// `KEY=value` entries separated by NUL after the marker line; nil without the marker.
    static func parse(_ output: String) -> [String: String]? {
        guard let range = output.range(of: marker + "\n", options: .backwards) else { return nil }
        var values: [String: String] = [:]
        for entry in output[range.upperBound...].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else { continue }
            values[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return values.isEmpty ? nil : values
    }
}
