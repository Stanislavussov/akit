import Foundation

/// How Install whisper.cpp runs Homebrew: install, and when that fails, repair brew and try once more.
public enum WhisperInstall {
    /// Homebrew's name since 2025 (`whisper-cpp` is an old alias).
    public static let formula = "whisper.cpp"

    public static var install: [String] { ["install", formula] }

    /// Brew commands that fix what a failed install printed, in order. Always `brew update`; the
    /// `pkg-config` → `pkgconf` clash when brew names either; and every `brew reinstall X` or
    /// `brew link --overwrite X` brew itself suggests.
    public static func repairSteps(after output: String) -> [[String]] {
        var steps: [[String]] = [["update"]]
        if output.contains("pkgconf") || output.contains("pkg-config") {
            steps += [["uninstall", "--ignore-dependencies", "pkg-config"],
                      ["reinstall", "pkgconf"],
                      ["link", "--overwrite", "pkgconf"]]
        }
        for suggested in suggestions(in: output) where !steps.contains(suggested) {
            steps.append(suggested)
        }
        return steps
    }

    /// `brew reinstall X`, `brew link X` and `brew link --overwrite X` that brew printed as advice.
    static func suggestions(in output: String) -> [[String]] {
        let pattern = try! Regex(#"brew (reinstall|link(?: --overwrite)?) ([A-Za-z0-9@._+\-]+)"#, as: (Substring, Substring, Substring).self)
        var found: [[String]] = []
        for match in output.matches(of: pattern) {
            let name = String(match.output.2)
            guard !name.hasPrefix("-"), name != "--dry-run" else { continue }
            let command = String(match.output.1).split(separator: " ").map(String.init)
            let step = command == ["link"] ? ["link", "--overwrite", name] : command + [name]
            if !found.contains(step) { found.append(step) }
        }
        return found
    }
}
