import AKitFoundation
import Foundation

/// What one step of the analysis ran with (`docs/design/error-analysis.md`, "Done key").
/// Unused fields stay nil: a code check has a `codeVersion` and no model.
public struct StepConfig: Codable, Hashable, Sendable {
    /// The step's name: `notes`, `verifier`, `matching`, `check:<mode id>`…
    public var step: String
    public var harness: String?
    public var model: String?
    public var promptVersion: Int?
    public var scrubVersion: Int?
    public var codeVersion: Int?
    /// Anything else the step's output depends on (the modes-list version for matching…).
    public var extra: [String: String]

    public init(step: String, harness: String? = nil, model: String? = nil, promptVersion: Int? = nil,
                scrubVersion: Int? = nil, codeVersion: Int? = nil, extra: [String: String] = [:]) {
        self.step = step
        self.harness = harness
        self.model = model
        self.promptVersion = promptVersion
        self.scrubVersion = scrubVersion
        self.codeVersion = codeVersion
        self.extra = extra
    }
}

/// One content-addressed rule for skipping work: a step whose key already exists is done.
public enum DoneKey {
    /// `sha256(input).sha256(configs)`. Pass the configs of the step and of every step whose
    /// output it reads, so changing one step's model changes only that step's key and the keys
    /// downstream of it. The configs are sorted by `step` and encoded with sorted keys, so
    /// their order doesn't matter.
    public static func make(input: Data, configs: [StepConfig]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding plain strings, ints and string maps can't fail.
        let configData = (try? encoder.encode(configs.sorted { $0.step < $1.step })) ?? Data()
        return Checksum.sha256(input) + "." + Checksum.sha256(configData)
    }
}
