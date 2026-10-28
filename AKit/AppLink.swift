import Foundation

/// `akit://<screen>[/<tab>]` links (2026-10-26, the user's request: open the notebook from
/// Raycast). The screen is a sidebar section's id, any case (`notebook`, `review`, `skillssh`);
/// for the notebook a tab may follow (`akit://notebook/Inbox`, `akit://notebook/Plans%20Q4`).
/// The work log (2026-10-28): `akit://worklog` puts the cursor in its entry field,
/// `akit://worklog?kind=bug` chooses a kind too, and `akit://worklog/add?text=…[&kind=bug]` adds an
/// entry stamped now (Raycast: a quicklink with an argument).
struct AppLink: Equatable {
    static let scheme = "akit"

    var section: SidebarSection
    var tab: String?
    /// Work log: the kind to choose, and the text of an entry to add (`/add`).
    var kind: String?
    var add: String?

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host(percentEncoded: false)?.lowercased(),
              let section = SidebarSection.allCases.first(where: { $0.rawValue.lowercased() == host }) else { return nil }
        self.section = section
        let tab = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.tab = section == .notebook && !tab.isEmpty ? tab : nil
        if section == .worklog {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
            kind = value("kind")
            if tab.lowercased() == "add" { add = value("text") ?? "" }
        }
    }
}
