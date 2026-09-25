import Foundation

/// Gets a program's version by running `<program> --version`.
/// If the program doesn't exit within `timeout` seconds it is terminated and nil is returned.
public enum VersionProbe {
    public static func version(of executable: URL, in env: HarnessEnvironment, timeout: TimeInterval = 5) async -> String? {
        var childEnv = env.variables
        childEnv["PATH"] = env.pathForChildProcesses
        childEnv["NO_COLOR"] = "1"
        guard let result = await ProcessRunner.run(executable, arguments: ["--version"], environment: childEnv,
                                                   timeout: timeout),
              result.succeeded else { return nil }
        return parse(result.output)
    }

    /// First non-empty line containing a digit (banners without digits are skipped).
    static func parse(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in !line.isEmpty && line.contains(where: \.isNumber) }
    }
}
