import Foundation

/// The user's verdict on each finding at approval (`docs/design/review.md`, "Quality"), read
/// from every run's `requests.json` and `missed.json`, so nothing is kept twice.
public enum ReviewQuality {
    public enum Label: String, Codable, Sendable, CaseIterable {
        case approved
        case approvedEdited = "approved_edited"
        case rejected
        case missedByFilter = "missed-by-filter"
        case missed
    }

    public struct Entry: Codable, Sendable, Hashable {
        public var run: String
        public var finding: String?
        public var role: String?
        public var scenario: String
        public var model: String
        public var label: Label
        public var reason: ReviewRequest.Reason?
        public var comment: String?
        public var title: String
    }

    /// approved / (approved + rejected).
    public struct Precision: Sendable, Hashable {
        public var key: String
        public var approved = 0
        public var rejected = 0
        public var value: Double? { approved + rejected == 0 ? nil : Double(approved) / Double(approved + rejected) }
    }

    public static func entries(home: URL) -> [Entry] {
        ReviewRuns.list(home: home).flatMap { item -> [Entry] in
            guard let run = try? ReviewWorkflow.load(ReviewPaths(home: home).run(item.id)) else { return [] }
            return entries(of: run)
        }
    }

    public static func entries(of run: ReviewWorkflow.Run) -> [Entry] {
        let model = run.spec.passes.value.model.isEmpty ? "Pi's default" : run.spec.passes.value.model
        var result: [Entry] = []
        for request in run.plan?.requests ?? [] where request.findingID != nil && request.decision != .pending {
            let finding = run.finding(request.findingID)
            let label: Label = request.decision == .rejected ? .rejected
                : request.movedByUser ? .missedByFilter : (request.edited == nil ? .approved : .approvedEdited)
            result.append(Entry(run: run.id, finding: request.findingID, role: request.role, scenario: run.spec.scenario.value, model: model,
                                label: label, reason: request.reason, comment: request.comment, title: finding?.title ?? ""))
        }
        for missed in run.missed {
            result.append(Entry(run: run.id, finding: nil, role: nil, scenario: run.spec.scenario.value, model: model, label: .missed,
                                reason: nil, comment: nil, title: missed.text))
        }
        return result
    }

    /// Precision by role, by scenario and by model. A finding moved inline by hand counts as
    /// approved: the filter, not the reviewer, was wrong.
    public static func precision(_ entries: [Entry]) -> (roles: [Precision], scenarios: [Precision], models: [Precision]) {
        func group(_ key: (Entry) -> String?) -> [Precision] {
            var table: [String: Precision] = [:]
            for entry in entries {
                guard let name = key(entry) else { continue }
                var value = table[name] ?? Precision(key: name)
                switch entry.label {
                case .approved, .approvedEdited, .missedByFilter: value.approved += 1
                case .rejected: value.rejected += 1
                case .missed: continue
                }
                table[name] = value
            }
            return table.values.sorted { $0.key < $1.key }
        }
        return (group(\.role), group { $0.scenario }, group { $0.model })
    }
}
