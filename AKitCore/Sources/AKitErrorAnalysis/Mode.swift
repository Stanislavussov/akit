import Foundation

/// A pattern with a definition and criteria, not just a name (`docs/design/error-analysis.md`,
/// "Modes"). Kept in `modes/modes.json`; never deleted, so a rejected or merged mode still
/// steers the model and past results can be recounted through `mergedInto`.
public struct Mode: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case failure, success, efficiency

        /// Fix statuses apply to failures and inefficiencies; a success mode is a strategy to keep.
        public var takesFixes: Bool { self != .success }
    }

    /// Used only in filters and reports; matching sees every mode.
    public enum Scope: Codable, Hashable, Sendable, CustomStringConvertible {
        case general
        case project(String)

        public init(parsing text: String) throws {
            if text == "general" {
                self = .general
            } else if text.hasPrefix("project:"), text.count > "project:".count {
                self = .project(String(text.dropFirst("project:".count)))
            } else {
                throw ModeStore.Failure(message: "Unknown mode scope \"\(text)\"; it is general or project:<id>.")
            }
        }

        public var description: String {
            switch self {
            case .general: "general"
            case .project(let id): "project:\(id)"
            }
        }

        public init(from decoder: Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            do { try self.init(parsing: text) } catch {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a scope: \(text)"))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(description)
        }
    }

    public enum Origin: String, Codable, Sendable, CaseIterable {
        /// Our own observations.
        case seedPrior = "seed-prior"
        /// Published studies.
        case seedLiterature = "seed-literature"
        /// Found in the notes.
        case emergent

        public var isSeed: Bool { self != .emergent }
    }

    public enum Status: String, Codable, Sendable, CaseIterable {
        /// Takes part in matching, but isn't in reports and gets no check.
        case seedInactive = "seed-inactive"
        case candidate, active, rejected

        public var title: String {
            switch self {
            case .seedInactive: "seed, inactive"
            case .candidate: "candidate"
            case .active: "active"
            case .rejected: "rejected"
            }
        }
    }

    /// open → draft → applied(T) → confirmed / didn't help / rejected (with a reason).
    public enum FixStatus: String, Codable, Sendable, CaseIterable {
        case open, draft, applied, confirmed
        case didntHelp = "didnt-help"
        case rejected

        public var title: String {
            switch self {
            case .didntHelp: "didn't help"
            default: rawValue
            }
        }
    }

    /// Stable slug: survives renames, so results and exemplars keep pointing at the mode.
    public var id: String
    public var name: String
    public var kind: Kind
    /// 1–2 sentences.
    public var definition: String
    /// Criteria: without them the next run drifts and checks float.
    public var include: [String]
    public var exclude: [String]
    public var scope: Scope
    public var origin: Origin
    public var faultLayer: FaultLayer?
    /// Bumped by any merge, split or definition edit; invalidates the mode's test metrics.
    public var version: Int
    /// Set when the mode was merged into another; past results are recounted through it.
    public var mergedInto: String?
    public var status: Status
    /// "Rejected because…": kept so the model doesn't propose the mode again.
    public var rejectedReason: String?
    /// Failure and efficiency modes only.
    public var fix: FixStatus?
    /// T: when the user marked the fix applied, the anchor for before/after.
    public var fixAppliedAt: Date?
    /// Why the fix was rejected.
    public var fixReason: String?
    public var createdAt: Date
    /// When the user confirmed the mode in the UI.
    public var confirmedAt: Date?
    /// Run ids of independent batch matches: two activate a seed.
    public var batchMatches: [String]
    /// The sessions behind those matches: two batches that sampled the same session are not
    /// two independent cases.
    public var batchSessions: [String]?

    /// A new mode at version 1. Without a status, a seed starts inactive and an emergent mode
    /// starts as a candidate.
    public init(id: String, name: String, kind: Kind = .failure, definition: String, include: [String] = [], exclude: [String] = [],
                scope: Scope = .general, origin: Origin = .emergent, faultLayer: FaultLayer? = nil, status: Status? = nil,
                createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.kind = kind
        self.definition = definition
        self.include = include
        self.exclude = exclude
        self.scope = scope
        self.origin = origin
        self.faultLayer = faultLayer
        self.version = 1
        self.mergedInto = nil
        self.status = status ?? (origin.isSeed ? .seedInactive : .candidate)
        self.rejectedReason = nil
        self.fix = nil
        self.fixAppliedAt = nil
        self.fixReason = nil
        self.createdAt = createdAt
        self.confirmedAt = nil
        self.batchMatches = []
    }

    /// In the current list: neither merged away nor rejected.
    public var isCurrent: Bool { mergedInto == nil && status != .rejected }
}

/// One quote that shows a mode: 2–3 per mode go into every matching call. A session in a
/// test set is never one, or the test would leak through matching.
public struct Exemplar: Codable, Hashable, Sendable {
    public var modeID: String
    public var sessionKey: String
    public var step: Int
    public var quote: String
    public var noteID: String?

    public init(modeID: String, sessionKey: String, step: Int, quote: String, noteID: String? = nil) {
        self.modeID = modeID
        self.sessionKey = sessionKey
        self.step = step
        self.quote = quote
        self.noteID = noteID
    }
}

/// A mode's test metrics no longer hold: its criteria changed (`docs/design/error-analysis.md`,
/// "Validation"). Callers drop the metrics measured at an older version.
public struct Invalidation: Codable, Hashable, Sendable {
    public var modeID: String
    /// The new version; metrics of any earlier version are invalid.
    public var version: Int
    public var reason: String

    public init(modeID: String, version: Int, reason: String) {
        self.modeID = modeID
        self.version = version
        self.reason = reason
    }
}

/// What a change that bumps versions did: the modes it touched and the metrics it invalidated.
public struct ModeChange: Hashable, Sendable {
    public var modes: [Mode]
    public var invalidations: [Invalidation]

    public init(modes: [Mode], invalidations: [Invalidation]) {
        self.modes = modes
        self.invalidations = invalidations
    }
}
