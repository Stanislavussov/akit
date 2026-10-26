import Foundation

/// `akit://<screen>[/<tab>]` links (2026-10-26, the user's request: open the notebook from
/// Raycast). The screen is a sidebar section's id, any case (`notebook`, `review`, `skillssh`);
/// for the notebook a tab may follow (`akit://notebook/Inbox`, `akit://notebook/Plans%20Q4`).
struct AppLink: Equatable {
    static let scheme = "akit"

    var section: SidebarSection
    var tab: String?

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host(percentEncoded: false)?.lowercased(),
              let section = SidebarSection.allCases.first(where: { $0.rawValue.lowercased() == host }) else { return nil }
        self.section = section
        let tab = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.tab = section == .notebook && !tab.isEmpty ? tab : nil
    }
}
