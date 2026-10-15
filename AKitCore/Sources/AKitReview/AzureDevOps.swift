import Foundation

/// A work item as the fetch pass read it (`<run>/context/work-items/<id>.md`, `<run>/tracker/work-items.json`).
public struct WorkItem: Codable, Sendable, Hashable {
    public struct Comment: Codable, Sendable, Hashable {
        public var author: String
        public var date: String
        public var text: String
    }

    public struct Change: Codable, Sendable, Hashable {
        public var revision: Int
        public var date: String
        public var by: String
        /// "State: New → Active", "Assigned To: …".
        public var summary: String
    }

    public var id: Int
    public var type: String
    public var title: String
    public var state: String
    public var description: String
    public var acceptanceCriteria: String
    public var reproSteps: String
    public var parents: [Int]
    public var related: [Int]
    public var children: [Int]
    public var comments: [Comment]
    public var changes: [Change]
    /// Why Gather read it: given, found in the MR, parent of …, related to ….
    public var reason: String
}

/// Reads Azure DevOps's JSON, as its REST API and the Azure DevOps MCP servers that pass it on
/// return it: work items with `fields` and `relations`, and their comments.
public enum AzureDevOpsJSON {
    public static func workItem(_ object: JSONObject) -> WorkItem? {
        guard let id = object.int("id"), let fields = object.object("fields"),
              fields["System.Title"] != nil || fields["System.WorkItemType"] != nil else { return nil }
        var parents: [Int] = []
        var related: [Int] = []
        var children: [Int] = []
        for relation in object.objects("relations") {
            guard let url = relation.string("url"), let target = url.split(separator: "/").last.flatMap({ Int($0) }) else { continue }
            switch relation.string("rel") {
            case "System.LinkTypes.Hierarchy-Reverse": parents.append(target)
            case "System.LinkTypes.Hierarchy-Forward": children.append(target)
            case "System.LinkTypes.Related": related.append(target)
            default: break
            }
        }
        func text(_ key: String) -> String { HTMLText.plain(fields.string(key) ?? "") }
        return WorkItem(id: id, type: fields.string("System.WorkItemType") ?? "", title: fields.string("System.Title") ?? "",
                        state: fields.string("System.State") ?? "", description: text("System.Description"),
                        acceptanceCriteria: text("Microsoft.VSTS.Common.AcceptanceCriteria"),
                        reproSteps: text("Microsoft.VSTS.TCM.ReproSteps"), parents: parents, related: related, children: children,
                        comments: [], changes: [], reason: "")
    }

    /// One comment (`…/comments`): the item it belongs to and the comment.
    public static func comment(_ object: JSONObject) -> (item: Int, comment: WorkItem.Comment)? {
        guard let item = object.int("workItemId"), let text = object.string("text") else { return nil }
        return (item, WorkItem.Comment(author: object.object("createdBy")?.string("displayName") ?? "", date: object.string("createdDate") ?? "",
                                       text: HTMLText.plain(text)))
    }

    /// Work item numbers in a text, by the profile's pattern (its first group is the number).
    public static func references(in texts: [String], pattern: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [Int] = []
        for text in texts {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let group = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                guard let range = Range(group, in: text), let id = Int(text[range]), !result.contains(id) else { continue }
                result.append(id)
            }
        }
        return result
    }
}

/// Azure DevOps keeps descriptions as HTML: plain text with line breaks for the agent.
enum HTMLText {
    static func plain(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html.trimmingCharacters(in: .whitespacesAndNewlines) }
        var text = html
        for (pattern, replacement) in [("(?i)<br\\s*/?>", "\n"), ("(?i)</(p|div|h[1-6]|tr)>", "\n"), ("(?i)<li[^>]*>", "\n- "),
                                       ("(?i)</li>", ""), ("<[^>]+>", "")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
