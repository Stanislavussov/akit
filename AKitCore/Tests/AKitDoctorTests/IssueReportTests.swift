import Foundation
import Testing
@testable import AKitDoctor

/// Help → Report a Bug… / Suggest a Feature…: the new-issue link and its template.
struct IssueReportTests {
    /// What GitHub reads back from the link: "+" is a space there, as in a form.
    func query(_ url: URL) -> [String: String] {
        let pairs = (url.query(percentEncoded: true) ?? "").split(separator: "&").map { $0.split(separator: "=", maxSplits: 1) }
        return Dictionary(uniqueKeysWithValues: pairs.map {
            (String($0[0]), String($0[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "")
        })
    }

    @Test func linkOpensTheNewIssuePageWithLabelAndTemplate() {
        for (kind, label) in [(IssueReport.bug, "bug"), (.feature, "enhancement")] {
            let url = kind.url(appVersion: "2026.10.11 + 1*", system: "macOS 15.6.1")
            #expect(url.absoluteString.hasPrefix("https://github.com/Stanislavussov/akit/issues/new?"))
            let query = query(url)
            #expect(query["labels"] == label)
            #expect(query["body"] == kind.body(appVersion: "2026.10.11 + 1*", system: "macOS 15.6.1"))
            // GitHub answers 414 to a link much longer than 8,000 bytes.
            #expect(url.absoluteString.utf8.count < 4000)
        }
    }

    @Test func plusAndMarkdownSurviveTheLink() {
        let url = IssueReport.bug.url(appVersion: "2026.10.11 + 1", system: "macOS 15 & more #1")
        #expect(!url.absoluteString.contains("+"))
        let body = query(url)["body"] ?? ""
        #expect(body.contains("- AKit: 2026.10.11 + 1\n- macOS 15 & more #1"))
        #expect(body.contains("Help → Copy Diagnostics"))
    }

    @Test func templatesHaveTheirSectionsAndTheVersion() {
        let bug = IssueReport.bug.body(appVersion: "2026.10.11", system: "macOS 15.6.1")
        for heading in ["## What happened", "## What you expected", "## Steps to reproduce", "## Environment", "## Diagnostics"] {
            #expect(bug.contains(heading + "\n"), "\(heading)")
        }
        #expect(bug.contains("- AKit: 2026.10.11\n- macOS 15.6.1\n"))

        let feature = IssueReport.feature.body(appVersion: nil, system: "macOS 15.6.1")
        for heading in ["## Problem", "## Proposed change", "## What you do today instead", "## Environment"] {
            #expect(feature.contains(heading + "\n"), "\(heading)")
        }
        #expect(feature.contains("- AKit: unknown\n"))
        #expect(!feature.contains("Diagnostics"))
    }
}
