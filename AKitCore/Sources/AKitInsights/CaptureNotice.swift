import Foundation

/// The Insights screen's line when session capture is off or out of date on this Mac.
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
        return "Session capture is \(parts.joined(separator: "; ")). Run akit setup (or akit insights install --yes) in Terminal."
    }

    /// `a`, `a and b`, `a, b and c`.
    public static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}
