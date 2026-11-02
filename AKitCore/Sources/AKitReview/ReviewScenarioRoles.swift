import Foundation

/// The roles of a scenario, edited without hand-written YAML: Review → Scenarios (the Roles box),
/// Review → Roles (Add to Scenario) and `akit review scenario add-role|remove-role|move-role`.
/// Each edit returns the scenario's new text; the save shows its diff first.
public enum ReviewScenarioRoles {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The text with `roles:` set to these lists, in this order; the rest of the file as it was.
    public static func setting(required: [String], optional: [String], in text: String) throws -> String {
        let required = required.map(roleID)
        let optional = optional.map(roleID).filter { !required.contains($0) }
        for id in required + optional where !ReviewYAML.isID(id) { throw Failure(message: "\(id) is not a role id.") }
        guard !required.isEmpty else { throw Failure(message: "A scenario needs one required role.") }
        let value = "{ required: [" + required.joined(separator: ", ") + "], optional: [" + optional.joined(separator: ", ") + "] }"
        let result = ReviewConfigEditor.settingTopLevelBlock("roles", value, in: text)
        guard let parsed = try? ReviewScenario.parse(result, source: .brain), parsed.required == required, parsed.optional == optional else {
            throw Failure(message: "AKit couldn't set roles: in the scenario by itself. Set roles: \(value) in the text.")
        }
        return result
    }

    /// A role's id; its skill name (`review-<id>`) means the same role.
    public static func roleID(_ name: String) -> String { name.hasPrefix("review-") ? String(name.dropFirst("review-".count)) : name }

    /// The role added (at the end of its list) or moved to required or optional.
    public static func adding(_ role: String, required: Bool, to scenario: ReviewScenario) throws -> String {
        let role = roleID(role)
        var (req, opt) = (scenario.required.filter { $0 != role }, scenario.optional.filter { $0 != role })
        if required { req.append(role) } else { opt.append(role) }
        return try setting(required: req, optional: opt, in: scenario.text)
    }

    public static func removing(_ role: String, from scenario: ReviewScenario) throws -> String {
        let role = roleID(role)
        guard scenario.roleIDs.contains(role) else { throw Failure(message: "Scenario \(scenario.id) has no role \(role).") }
        let required = scenario.required.filter { $0 != role }
        guard !required.isEmpty else { throw Failure(message: "\(role) is the last required role of \(scenario.id): a scenario needs one.") }
        return try setting(required: required, optional: scenario.optional.filter { $0 != role }, in: scenario.text)
    }

    /// The role one place earlier (`by` -1) or later (+1) in its list: the order the passes run.
    public static func moving(_ role: String, by step: Int, in scenario: ReviewScenario) throws -> String {
        let role = roleID(role)
        var (req, opt) = (scenario.required, scenario.optional)
        func move(_ list: inout [String]) -> Bool {
            guard let at = list.firstIndex(of: role) else { return false }
            let to = min(max(at + step, 0), list.count - 1)
            list.swapAt(at, to)
            return true
        }
        guard move(&req) || move(&opt) else { throw Failure(message: "Scenario \(scenario.id) has no role \(role).") }
        return try setting(required: req, optional: opt, in: scenario.text)
    }

    /// The scenarios that name a role, and whether as required.
    public static func uses(of role: String, in scenarios: [ReviewScenario]) -> [(scenario: ReviewScenario, required: Bool)] {
        scenarios.compactMap { scenario in
            scenario.required.contains(role) ? (scenario, true) : scenario.optional.contains(role) ? (scenario, false) : nil
        }
    }
}
