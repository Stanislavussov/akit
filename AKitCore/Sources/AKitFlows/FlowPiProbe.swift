import AKitFoundation
import Foundation

/// `akit doctor`'s part of `tools/pi-flow-probe.sh` (F20): this Mac's Pi version and the CLI flags
/// a flow needs, stored as `~/.akit/local/pi-capabilities.json` for the Flows screen and
/// `akit flow check`. Only `pi --version` and `pi --help` run: no env, tokens or config is read.
public enum FlowPiProbe {
    /// The flag in `pi --help` that each feature needs.
    static let flags: [(FlowPiFeature, String)] = [
        (.modeJSON, "--mode"), (.sessionDir, "--session-dir"), (.noExtensions, "--no-extensions"),
        (.noSkills, "--no-skills"), (.skill, "--skill"), (.thinking, "--thinking"),
    ]
    /// Extension API features the help text can't show. `make test-flows-e2e` proves them on
    /// `Flow.defaultMinPi`, so a Pi at that version or newer is taken to have them.
    static let apiFeatures: [FlowPiFeature] = [.toolCallBlock, .uiConfirm]

    public static func file(env: HarnessEnvironment) -> URL {
        env.homeDirectory.appending(path: ".akit/local/pi-capabilities.json")
    }

    /// What `pi --version` and `pi --help` say; nil when Pi doesn't answer.
    public static func probe(pi: URL, env: HarnessEnvironment) async -> PiCapabilities? {
        guard let version = await ProcessRunner.run(pi, arguments: ["--version"], environment: env.variables, timeout: 20),
              version.succeeded,
              let help = await ProcessRunner.run(pi, arguments: ["--help"], environment: env.variables, timeout: 20) else { return nil }
        return capabilities(version: version.output, help: help.output)
    }

    /// The features from the two outputs (pure, for tests).
    public static func capabilities(version: String, help: String) -> PiCapabilities {
        let number = version.split(whereSeparator: \.isWhitespace).map(String.init)
            .first { $0.first?.isNumber == true && $0.contains(".") }
        var features = Set(flags.filter { help.contains($0.1) }.map(\.0.rawValue))
        if let number, FlowCheck.compare(number, Flow.defaultMinPi) != .orderedAscending {
            features.formUnion(apiFeatures.map(\.rawValue))
        }
        return PiCapabilities(version: number, features: features)
    }

    /// Writes the capabilities file (sorted keys, so the same Pi gives the same file).
    public static func write(_ capabilities: PiCapabilities, env: HarnessEnvironment) throws {
        let url = file(env: env)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Sorted: Encodable { let version: String?, features: [String] }
        try encoder.encode(Sorted(version: capabilities.version, features: capabilities.features.sorted())).write(to: url, options: .atomic)
    }
}
