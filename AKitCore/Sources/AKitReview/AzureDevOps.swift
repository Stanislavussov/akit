import Foundation

/// A work item as Gather read it (`<run>/context/work-items/<id>.md`, `<run>/tracker/work-items.json`).
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

/// Azure DevOps REST (Services or Server), with a personal access token that may read work
/// items and nothing else (R2). AKit never writes to Azure DevOps.
public struct AzureDevOpsClient: Sendable {
    public let tracker: ReviewProfile.Tracker
    let token: String
    let fetch: ReviewFetch

    public init(tracker: ReviewProfile.Tracker, token: String, fetch: @escaping ReviewFetch = ReviewHTTP.network) {
        self.tracker = tracker
        self.token = token
        self.fetch = fetch
    }

    /// The items `ids`, their parents and related items one level deep (R3). Items that can't
    /// be read are skipped and named in `missing`, so Gather can report them as gaps.
    public func gather(_ ids: [Int]) async -> (items: [WorkItem], missing: [(id: Int, reason: String)]) {
        var items: [WorkItem] = []
        var missing: [(Int, String)] = []
        var seen = Set<Int>()
        func read(_ id: Int, reason: String) async -> WorkItem? {
            guard seen.insert(id).inserted else { return nil }
            do {
                var item = try await workItem(id)
                item.reason = reason
                items.append(item)
                return item
            } catch {
                missing.append((id, error.localizedDescription))
                return nil
            }
        }
        var first: [WorkItem] = []
        for id in ids { if let item = await read(id, reason: "named by the merge request") { first.append(item) } }
        for item in first {
            for parent in item.parents { _ = await read(parent, reason: "parent of #\(item.id)") }
            for related in item.related { _ = await read(related, reason: "related to #\(item.id)") }
        }
        return (items, missing)
    }

    public func workItem(_ id: Int) async throws -> WorkItem {
        let object = try await get("/_apis/wit/workitems/\(id)", query: [("$expand", "relations"), ("api-version", "7.1")], what: "work item \(id)")
        let fields = object.object("fields") ?? [:]
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
        var item = WorkItem(id: id, type: fields.string("System.WorkItemType") ?? "", title: fields.string("System.Title") ?? "",
                            state: fields.string("System.State") ?? "", description: text("System.Description"),
                            acceptanceCriteria: text("Microsoft.VSTS.Common.AcceptanceCriteria"),
                            reproSteps: text("Microsoft.VSTS.TCM.ReproSteps"), parents: parents, related: related, children: children,
                            comments: [], changes: [], reason: "")
        // Comments and history help, but an item without them is still worth reading.
        item.comments = (try? await comments(id)) ?? []
        item.changes = (try? await changes(id)) ?? []
        return item
    }

    func comments(_ id: Int) async throws -> [WorkItem.Comment] {
        let object = try await get("/_apis/wit/workItems/\(id)/comments", query: [("api-version", "7.1-preview.4")], what: "comments of \(id)")
        return object.objects("comments").map {
            WorkItem.Comment(author: $0.object("createdBy")?.string("displayName") ?? "", date: $0.string("createdDate") ?? "",
                             text: HTMLText.plain($0.string("text") ?? ""))
        }
    }

    /// What changed from one revision to the next, for the fields a reviewer cares about.
    func changes(_ id: Int) async throws -> [WorkItem.Change] {
        let object = try await get("/_apis/wit/workItems/\(id)/revisions", query: [("api-version", "7.1")], what: "history of \(id)")
        let watched = ["System.State": "State", "System.AssignedTo": "Assigned To", "System.Title": "Title",
                       "Microsoft.VSTS.Common.AcceptanceCriteria": "Acceptance Criteria", "System.IterationPath": "Iteration"]
        var previous: JSONObject = [:]
        var result: [WorkItem.Change] = []
        for revision in object.objects("value") {
            let fields = revision.object("fields") ?? [:]
            var parts: [String] = []
            for (key, name) in watched.sorted(by: { $0.value < $1.value }) {
                let old = Self.display(previous[key])
                let new = Self.display(fields[key])
                guard old != new, revision.int("rev") ?? 1 > 1 else { continue }
                parts.append(key == "Microsoft.VSTS.Common.AcceptanceCriteria" ? "\(name) changed" : "\(name): \(old.isEmpty ? "–" : old) → \(new)")
            }
            if !parts.isEmpty {
                result.append(WorkItem.Change(revision: revision.int("rev") ?? 0, date: Self.display(fields["System.ChangedDate"]),
                                              by: Self.display(fields["System.ChangedBy"]), summary: parts.joined(separator: "; ")))
            }
            previous = fields
        }
        return result
    }

    static func display(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let identity = value as? JSONObject { return identity.string("displayName") ?? "" }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    func get(_ path: String, query: [(String, String)], what: String) async throws -> JSONObject {
        let project = tracker.project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? tracker.project
        guard var components = URLComponents(string: tracker.baseURL + "/" + project + path) else {
            throw ReviewHTTP.Failure(message: "\(tracker.baseURL) is not a web address.")
        }
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else { throw ReviewHTTP.Failure(message: "Can't make an address for \(what).") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Basic " + Data(":\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await ReviewHTTP.send(request, fetch: fetch)
        guard let object = try ReviewHTTP.json(data, what: what) as? JSONObject else {
            throw ReviewHTTP.Failure(message: "\(what): Azure DevOps's answer is not an object (a sign-in page instead of the API?).")
        }
        return object
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
