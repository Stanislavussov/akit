import Foundation

/// Where a run is: the step that just ended and how often each step has started (F19's visits).
public struct FlowRunState: Codable, Equatable, Sendable {
    public var step: String
    public var visits: [String: Int]

    public init(step: String, visits: [String: Int]) {
        self.step = step
        self.visits = visits
    }
}

/// Why a run stops instead of going on.
public enum FlowStop: String, Codable, Sendable {
    /// A route said `end`, or the last step was done without a route.
    case done
    /// The next step already ran its `maxLoops` times.
    case visitCap = "visit-cap"
    /// No `outcome:reason` and no `outcome:*` route: a loud stop (a deviation).
    case noRoute = "no-route"
    /// The state's step, or a route's target, is not in the flow.
    case unknownStep = "unknown-step"
}

/// The routing answer: the next step with the visits after it starts, or a stop.
/// Same shape as the golden vectors' `expect` (`fixtures/flow-vectors/*.json`).
public struct FlowDecision: Codable, Equatable, Sendable {
    public var next: String?
    public var stop: FlowStop?
    /// For a stop, the step it concerns (the capped step, the step without a route).
    public var step: String?
    public var visits: [String: Int]

    public static func go(_ step: String, visits: [String: Int]) -> FlowDecision {
        FlowDecision(next: step, stop: nil, step: nil, visits: visits)
    }

    public static func halt(_ stop: FlowStop, step: String?, visits: [String: Int]) -> FlowDecision {
        FlowDecision(next: nil, stop: stop, step: step, visits: visits)
    }
}

/// The only home of routing in Swift (F19). Pure: the Runs screen uses it for the expected path,
/// and `flow-core.ts` must answer the same vectors.
public enum FlowRouting {
    /// The reserved route target that ends the run.
    public static let end = "end"

    /// The route key `outcome:reason` looked up first, then `outcome:*`. A `done` with no route goes
    /// to the next step in the column (the end after the last); `failed` and `blocked` need a route.
    public static func next(flow: Flow, state: FlowRunState, outcome: FlowOutcome, reason: String = "") -> FlowDecision {
        guard let index = flow.index(of: state.step) else { return .halt(.unknownStep, step: state.step, visits: state.visits) }
        let routes = flow.steps[index].routes
        let target: String
        if !reason.isEmpty, let exact = routes["\(outcome.rawValue):\(reason)"] {
            target = exact
        } else if let wildcard = routes["\(outcome.rawValue):*"] {
            target = wildcard
        } else if outcome == .done {
            target = index + 1 < flow.steps.count ? flow.steps[index + 1].id : end
        } else {
            return .halt(.noRoute, step: state.step, visits: state.visits)
        }
        if target == end { return .halt(.done, step: nil, visits: state.visits) }
        guard let next = flow.step(target) else { return .halt(.unknownStep, step: target, visits: state.visits) }
        let count = (state.visits[target] ?? 0) + 1
        if count > next.maxLoops { return .halt(.visitCap, step: target, visits: state.visits) }
        var visits = state.visits
        visits[target] = count
        return .go(target, visits: visits)
    }
}
