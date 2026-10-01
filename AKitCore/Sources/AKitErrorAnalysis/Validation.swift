import AKitFoundation
import Foundation

/// Train/dev/test splits of each mode's labels (`labels/splits.json`). Exemplars and few-shot
/// examples come only from train; a session in a test set is never an exemplar.
public struct ValidationStore: Sendable {
    public struct Split: Codable, Hashable, Sendable {
        public var train: [String]
        public var dev: [String]
        public var test: [String]

        public init(train: [String] = [], dev: [String] = [], test: [String] = []) {
            self.train = train
            self.dev = dev
            self.test = test
        }
    }

    let file: URL

    public init(env: HarnessEnvironment) { file = AnalysisPaths(env: env).labels.appending(path: "splits.json") }

    public func splits() -> [String: Split] {
        (try? Data(contentsOf: file)).flatMap { try? AnalysisJSON.decoder.decode([String: Split].self, from: $0) } ?? [:]
    }

    public func save(_ splits: [String: Split]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AnalysisJSON.encoder.encode(splits).write(to: file, options: .atomic)
    }

    /// Sessions in any mode's test set.
    public func testSessions() -> Set<String> { Set(splits().values.flatMap(\.test)) }
}
