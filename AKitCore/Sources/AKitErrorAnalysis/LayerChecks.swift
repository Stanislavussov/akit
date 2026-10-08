import AKitBrain
import AKitFoundation
import AKitLab
import Foundation

/// The setup checks of a layer eval (`docs/design/layer-evals.md`, "Isolation check"): what
/// each setup's cells must and must not show the agent, from the render. Stored in the
/// eval's manifest; every cell is checked before its agent starts and after it.
public struct LayerChecks: Codable, Sendable, Hashable {
    /// The setup without the layer (its required layers alone), and its read-only sanity cells:
    /// none of the layer's own skills, texts or files.
    public var baseline: SetupCheck
    /// The required layers and the layer: every skill the render brings with its mode, the
    /// layer's texts where Claude Code reads them, and none of the skills the layers turn off
    /// or the answers drop.
    public var layer: SetupCheck

    public init(baseline: SetupCheck, layer: SetupCheck) {
        self.baseline = baseline
        self.layer = layer
    }

    /// The check of a setup: the baseline's for `requiredOnly` and the read-only sanity setup.
    public func check(for setup: ControlSetup) -> SetupCheck {
        setup.layer?.role == .layer && !setup.readOnly ? layer : baseline
    }

    /// From the two renders. `declared`: every skill the layers of the closure name (whatever
    /// their mode or `when`); those the full render leaves out are off.
    static func make(layer name: String, full: LayerSetups.Rendered, required: LayerSetups.Rendered?, layerOverlay: ControlOverlay,
                     baseOverlay: ControlOverlay?, declared: Set<String>) -> LayerChecks {
        let baseSkills = required?.rendered ?? []
        let baseNames = Set(baseSkills.map(\.name))
        let fullNames = Set(full.rendered.map(\.name))
        // The text the baseline's own overlay writes: a text of the layer found there is the required layers'.
        let baseText = (baseOverlay?.contents.values.map { String(decoding: $0, as: UTF8.self) } ?? []).joined(separator: "\n")
        var texts: [SetupCheck.Text] = []
        var files: [SetupCheck.File] = []
        for file in full.files {
            let path = ProjectBundle.normalizedPath(file.to)
            if path.lowercased().hasSuffix(".md") {
                let text = String(decoding: file.data, as: UTF8.self).trimmingCharacters(in: .newlines)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !baseText.contains(text) else { continue }
                texts.append(SetupCheck.Text(label: "the \(name) layer's \(path) text", text: text, path: path))
            } else {
                let sha = Checksum.sha256(file.data)
                guard !(baseOverlay?.entries.contains { $0.path == path && $0.sha256 == sha } ?? false) else { continue }
                files.append(SetupCheck.File(path: path, sha256: sha))
            }
        }
        return LayerChecks(
            baseline: SetupCheck(skills: baseSkills, absentSkills: fullNames.subtracting(baseNames).sorted(), absentTexts: texts,
                                 absentFiles: files),
            layer: SetupCheck(skills: full.rendered, absentSkills: declared.subtracting(fullNames).sorted(), texts: texts))
    }

    /// For an eval queued before the checks were stored: from its two stored overlays. The
    /// skills the layers turn off are unknown there, so only the layer's own skills, texts and
    /// files are checked (a continued eval stores the full checks in its manifest).
    static func derived(layer name: String, layerOverlay: ControlOverlay?, baseOverlay: ControlOverlay?) -> LayerChecks {
        func skills(_ overlay: ControlOverlay?) -> [SetupCheck.Skill] {
            guard let overlay else { return [] }
            var names: [String] = []
            for entry in overlay.entries where entry.kind == .skillFile {
                if let skill = entry.skill, !names.contains(skill) { names.append(skill) }
            }
            return names.map { skill in
                let file = overlay.contents[".agents/skills/\(skill)/SKILL.md"].map { String(decoding: $0, as: UTF8.self) } ?? ""
                return SetupCheck.Skill(name: skill, manual: SetupCheck.header(of: file).contains { $0.key == "disable-model-invocation" && $0.value == "true" })
            }
        }
        let base = skills(baseOverlay), full = skills(layerOverlay)
        var texts: [SetupCheck.Text] = []
        var files: [SetupCheck.File] = []
        for entry in layerOverlay?.entries ?? [] {
            let baseEntry = baseOverlay?.entries.first { $0.path == entry.path }
            guard baseEntry?.sha256 != entry.sha256, let data = layerOverlay?.contents[entry.path] else { continue }
            switch entry.kind {
            case .agentsSection, .markdown:
                // The layer's text is what the full render adds to the required layers' text.
                var text = String(decoding: data, as: UTF8.self)
                if let base = baseEntry.flatMap({ baseOverlay?.contents[$0.path] }).map({ String(decoding: $0, as: UTF8.self) }) {
                    text = text.replacingOccurrences(of: base.trimmingCharacters(in: .newlines), with: "")
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                texts.append(SetupCheck.Text(label: "the \(name) layer's \(entry.path) text", text: text, path: entry.path))
            case .file:
                if let sha = entry.sha256 { files.append(SetupCheck.File(path: entry.path, sha256: sha)) }
            case .skillFile, .claudeSkillsLink:
                continue
            }
        }
        let baseNames = Set(base.map(\.name))
        return LayerChecks(baseline: SetupCheck(skills: base, absentSkills: full.map(\.name).filter { !baseNames.contains($0) },
                                                absentTexts: texts, absentFiles: files),
                           layer: SetupCheck(skills: full, texts: texts))
    }

    /// What breaks either setup's check outside the clones (`~/.claude`, the folders above the
    /// Lab's clones): every cell of that setup would fail before its agent starts, so the eval
    /// isn't queued while it is so.
    public func outsideProblems(layer name: String, home: URL) -> [String] {
        [("without \(name)", baseline), ("layer \(name)", layer)].flatMap { setup, check in
            check.outsideProblems(of: Self.cloneLocation, home: home).map { "The setup \(setup) would see what it must not: \($0)." }
        }
    }

    /// Where a cell's clone is made (`ControlCell`): its parents are what Claude Code walks up through.
    static var cloneLocation: URL { FileManager.default.temporaryDirectory.appending(path: "akit-control-check", directoryHint: .isDirectory) }

    /// The check of a layer cell's setup: the eval's stored checks, else derived from its stored
    /// overlays (an eval queued before the checks). Throws when the eval's manifest is gone: an
    /// unchecked layer cell never runs.
    public static func check(for setup: ControlSetup, env: HarnessEnvironment) throws -> SetupCheck {
        guard let variant = setup.layer else { return SetupCheck() }
        guard let manifest = LayerEvalStore.manifest(variant.evalID, env: env) else {
            throw LayerSetups.Failure(message: LayerEvalStore.problem(variant.evalID, env: env).map { "\($0) Its cells can't be checked." }
                                          ?? "The eval \(variant.evalID) can't be read, so its cells can't be checked.")
        }
        if let checks = manifest.checks { return checks.check(for: setup) }
        func overlay(_ role: LayerVariant.Role) throws -> ControlOverlay? {
            guard let hash = manifest.setups.first(where: { $0.layer?.role == role })?.layer?.overlayHash else { return nil }
            return try LayerEvalStore.overlay(hash: hash, eval: manifest.id, env: env)
        }
        return derived(layer: manifest.layer, layerOverlay: try overlay(.layer), baseOverlay: try overlay(.requiredOnly)).check(for: setup)
    }
}
