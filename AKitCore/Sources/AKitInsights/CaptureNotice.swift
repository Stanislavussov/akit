import Foundation

/// The Insights screen's line when session capture is off or out of date on this Mac; its
/// Install Capture… button sets it up.
public enum CaptureNotice {
    /// nil when every part that can be on is on and current, or when the person said no to
    /// capture (or to a part) in `akit setup`. `brainPresent`: the Claude plugin lives in the brain.
    public static func text(status: CaptureInstaller.Status, brainPresent: Bool) -> String? {
        guard !status.declined else { return nil }
        let skipped = Set(status.skipped)
        var off: [String] = [], outdated: [String] = []
        if status.claude.claudeFound {
            if status.claude.installedVersion == nil {
                if brainPresent, !skipped.contains(.claude) { off.append("Claude Code") }
            } else if status.claude.versionMismatch {
                outdated.append("Claude Code")
            }
        }
        if status.pi.found, status.pi.state == "missing", !skipped.contains(.pi) { off.append("Pi") }
        if status.pi.state == "outdated" { outdated.append("Pi") }
        if !status.launchd.loaded, !skipped.contains(.launchd) { off.append("the hourly import") }
        let parts = [off.isEmpty ? nil : "off for \(list(off))", outdated.isEmpty ? nil : "out of date for \(list(outdated))"].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return "Session capture is \(parts.joined(separator: "; "))."
    }

    /// The quieter line when capture, or a part of it that could be on, is off by the person's
    /// own answer (`akit setup`, `akit insights uninstall`); nil otherwise.
    public static func offByChoice(status: CaptureInstaller.Status, brainPresent: Bool) -> String? {
        if status.declined { return "Session capture is off on this Mac (turned off in akit setup or by akit insights uninstall)." }
        let installed = CaptureInstaller.installedParts(status)
        let off = status.skipped.filter { part in
            guard !installed.contains(part) else { return false }
            return switch part {
            case .claude: status.claude.claudeFound && brainPresent
            case .pi: status.pi.found
            case .launchd: true
            }
        }
        guard !off.isEmpty else { return nil }
        let names = off.map { part in
            switch part {
            case .claude: "Claude Code"
            case .pi: "Pi"
            case .launchd: "the hourly import"
            }
        }
        return "Session capture is off for \(list(names)) (your answer in akit setup)."
    }

    /// `a`, `a and b`, `a, b and c`.
    public static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}
