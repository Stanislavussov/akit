import Foundation

/// The app's Help → Report a Bug… and Suggest a Feature…: GitHub's new-issue page for AKit,
/// opened in the browser with a filled-in template. Nothing is sent: the user writes the issue
/// and posts it. The template carries only the AKit version and the macOS version; the
/// diagnostics report names the user's projects, so it is never put in, only asked for.
public enum IssueReport: String, Sendable, CaseIterable {
    case bug, feature

    /// AKit's repository on GitHub.
    public static let repository = "https://github.com/Stanislavussov/akit"

    public var menuTitle: String {
        switch self {
        case .bug: "Report a Bug…"
        case .feature: "Suggest a Feature…"
        }
    }

    /// One of GitHub's default labels. GitHub applies it only for people who may label issues
    /// in the repository; for everyone else it drops the label and keeps the text.
    var label: String {
        switch self {
        case .bug: "bug"
        case .feature: "enhancement"
        }
    }

    /// The issue text, Markdown. `appVersion` as the About panel shows it ("2026.10.11 + 1"),
    /// `system` e.g. "macOS 15.6.1".
    public func body(appVersion: String?, system: String) -> String {
        let environment = """
            ## Environment

            - AKit: \(appVersion ?? "unknown")
            - \(system)
            """
        switch self {
        case .bug:
            return """
                ## What happened

                <!-- What did you do, and what did AKit do? A screenshot helps. -->

                ## What you expected

                ## Steps to reproduce

                1.\u{20}
                2.\u{20}

                \(environment)

                ## Diagnostics

                <!-- Optional. In AKit: Help → Copy Diagnostics, then paste here. The report has no secrets, but it names your projects and this issue is public: read it before you post. -->

                """
        case .feature:
            return """
                ## Problem

                <!-- What are you trying to do, and what gets in the way? -->

                ## Proposed change

                <!-- What should AKit do? Name the screen or the akit command. -->

                ## What you do today instead

                \(environment)

                """
        }
    }

    /// GitHub's new-issue page with the label and the template filled in.
    public func url(appVersion: String?, system: String) -> URL {
        // URLComponents leaves "+" as it is, and GitHub reads it as a space ("2026.10.11 + 1").
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encoded(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        let query = "labels=\(encoded(label))&body=\(encoded(body(appVersion: appVersion, system: system)))"
        return URL(string: "\(Self.repository)/issues/new?\(query)")!
    }
}
