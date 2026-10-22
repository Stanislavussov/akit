import AKitFoundation
import Foundation
import Yams

/// Where review keeps its files. Work configuration and runs live only in
/// `~/.akit/local/review/`, never in the brain (R1).
public struct ReviewPaths: Sendable {
    public let home: URL

    public init(home: URL) { self.home = home }

    public var folder: URL { home.appending(path: ".akit/local/review", directoryHint: .isDirectory) }
    public var projects: URL { folder.appending(path: "projects", directoryHint: .isDirectory) }
    public var runs: URL { folder.appending(path: "runs", directoryHint: .isDirectory) }
    public func run(_ id: String) -> URL { runs.appending(path: id, directoryHint: .isDirectory) }
    public func profile(_ slug: String) -> URL { projects.appending(path: "\(slug).yaml") }
    /// A project's own roles and scenarios: `projects/<slug>/skills/review-<id>/SKILL.md`,
    /// `projects/<slug>/scenarios/<id>.yaml`.
    public func projectFolder(_ slug: String) -> URL { projects.appending(path: slug, directoryHint: .isDirectory) }

    /// The brain layer with the generic roles, scenarios and defaults.
    public static func brainLayer(brain: URL) -> URL { brain.appending(path: "layers/review", directoryHint: .isDirectory) }
}

/// Everything review can be configured from, read from disk: the brain layer `review` (or the
/// built-ins where it has nothing), the project profiles and their own roles and scenarios.
public struct ReviewCatalog: Sendable {
    /// Roles and scenarios of the brain (built-ins for ids the brain lacks).
    public var roles: [ReviewRole]
    public var scenarios: [ReviewScenario]
    /// The built-in `review.yaml`.
    public var builtInDefaults: ReviewSettingsPatch
    /// The brain's `review.yaml`; empty when it has none.
    public var brainDefaults: ReviewSettingsPatch
    /// `pi:` of the brain's `review.yaml`: flags and steps for every run.
    public var brainPi = ReviewPiExtras()
    public var profiles: [ReviewProfile]
    /// Project roles and scenarios by profile slug.
    public var projectRoles: [String: [ReviewRole]]
    public var projectScenarios: [String: [ReviewScenario]]
    /// Files that couldn't be read, with why. They are left out, never guessed.
    public var problems: [String]

    public static func load(home: URL, brain: URL?) -> ReviewCatalog {
        var problems: [String] = []
        var roles = Dictionary(uniqueKeysWithValues: ReviewBuiltIns.roles.map { ($0.id, $0) })
        var scenarios = Dictionary(uniqueKeysWithValues: ReviewBuiltIns.scenarios.map { ($0.id, $0) })
        let builtInDefaults = (try? ReviewSettingsPatch.parse(ReviewYAML.map(ReviewBuiltIns.defaultsYAML), where: "built-in")) ?? ReviewSettingsPatch()
        var brainDefaults = ReviewSettingsPatch()
        var brainPi = ReviewPiExtras()
        if let brain {
            let layer = ReviewPaths.brainLayer(brain: brain)
            for role in readRoles(in: layer.appending(path: "skills"), source: .brain, problems: &problems) { roles[role.id] = role }
            for scenario in readScenarios(in: layer.appending(path: "scenarios"), source: .brain, problems: &problems) {
                scenarios[scenario.id] = scenario
            }
            let file = layer.appending(path: "review.yaml")
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                do {
                    brainDefaults = try ReviewSettingsPatch.parse(ReviewYAML.map(text), where: file.path)
                    brainPi = try ReviewPiExtras.parse(ReviewYAML.map(text)["pi"], where: file.path)
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
        }
        let paths = ReviewPaths(home: home)
        var profiles: [ReviewProfile] = []
        var projectRoles: [String: [ReviewRole]] = [:]
        var projectScenarios: [String: [ReviewScenario]] = [:]
        for file in FileWalk.children(of: paths.projects) where file.pathExtension == "yaml" {
            let slug = file.deletingPathExtension().lastPathComponent
            guard ReviewYAML.isID(slug) else {
                problems.append("\(file.path): the file name must use only a-z, 0-9 and -.")
                continue
            }
            do {
                profiles.append(try ReviewProfile.parse(String(contentsOf: file, encoding: .utf8), slug: slug, file: file))
            } catch {
                problems.append(error.localizedDescription)
                continue
            }
            let folder = paths.projectFolder(slug)
            projectRoles[slug] = readRoles(in: folder.appending(path: "skills"), source: .project, problems: &problems)
            projectScenarios[slug] = readScenarios(in: folder.appending(path: "scenarios"), source: .project, problems: &problems)
        }
        var catalog = ReviewCatalog(roles: ReviewCatalog.ordered(Array(roles.values), ReviewBuiltIns.roleIDs),
                                    scenarios: ReviewCatalog.ordered(Array(scenarios.values), ReviewBuiltIns.scenarioIDs),
                                    builtInDefaults: builtInDefaults, brainDefaults: brainDefaults,
                                    profiles: profiles.sorted { $0.slug < $1.slug }, projectRoles: projectRoles,
                                    projectScenarios: projectScenarios, problems: problems)
        catalog.brainPi = brainPi
        return catalog
    }

    /// The profile for a merge request: the one named, else the one whose GitLab project matches.
    public func profile(for mr: MergeRequestRef?, named slug: String? = nil) -> ReviewProfile? {
        if let slug { return profiles.first { $0.slug == slug } }
        guard let mr else { return nil }
        return profiles.first { $0.matches(mr) }
    }

    /// Roles as a project sees them: the brain's, with the project's own copies and roles on top.
    public func roles(for profile: ReviewProfile?) -> [ReviewRole] {
        var byID = Dictionary(uniqueKeysWithValues: roles.map { ($0.id, $0) })
        for role in profile.flatMap({ projectRoles[$0.slug] }) ?? [] { byID[role.id] = role }
        return ReviewCatalog.ordered(Array(byID.values), roles.map(\.id))
    }

    public func scenarios(for profile: ReviewProfile?) -> [ReviewScenario] {
        var byID = Dictionary(uniqueKeysWithValues: scenarios.map { ($0.id, $0) })
        for scenario in profile.flatMap({ projectScenarios[$0.slug] }) ?? [] { byID[scenario.id] = scenario }
        return ReviewCatalog.ordered(Array(byID.values), scenarios.map(\.id))
    }

    static func readRoles(in folder: URL, source: ReviewSource, problems: inout [String]) -> [ReviewRole] {
        FileWalk.children(of: folder).compactMap { skill in
            let file = skill.appending(path: "SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            do {
                let role = try ReviewRole.parse(text, source: source, file: file)
                guard role.skillName == skill.lastPathComponent else {
                    problems.append("\(file.path): the name \(role.skillName) doesn't match its folder.")
                    return nil
                }
                return role
            } catch {
                problems.append(error.localizedDescription)
                return nil
            }
        }
    }

    static func readScenarios(in folder: URL, source: ReviewSource, problems: inout [String]) -> [ReviewScenario] {
        FileWalk.children(of: folder).filter { $0.pathExtension == "yaml" }.compactMap { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            do {
                let scenario = try ReviewScenario.parse(text, source: source, file: file)
                guard scenario.id == file.deletingPathExtension().lastPathComponent else {
                    problems.append("\(file.path): the id \(scenario.id) doesn't match the file name.")
                    return nil
                }
                return scenario
            } catch {
                problems.append(error.localizedDescription)
                return nil
            }
        }
    }

    /// Known ids first in their order, then the rest by id.
    static func ordered<T: Identifiable>(_ items: [T], _ order: [String]) -> [T] where T.ID == String {
        items.sorted { a, b in
            let i = order.firstIndex(of: a.id) ?? Int.max
            let j = order.firstIndex(of: b.id) ?? Int.max
            return i != j ? i < j : a.id < b.id
        }
    }
}

extension ReviewSettingsPatch {
    /// This patch with every field `other` sets replaced.
    public func overridden(by other: ReviewSettingsPatch) -> ReviewSettingsPatch {
        func model(_ a: ReviewModelChoice?, _ b: ReviewModelChoice?) -> ReviewModelChoice? {
            guard let b else { return a }
            guard let a else { return b }
            return ReviewModelChoice(model: b.model.isEmpty ? a.model : b.model, thinking: b.thinking.isEmpty ? a.thinking : b.thinking)
        }
        var patch = ReviewSettingsPatch(passes: model(passes, other.passes), verifier: model(verifier, other.verifier),
                                        marker: other.marker ?? marker, severityThreshold: other.severityThreshold ?? severityThreshold,
                                        confidenceThreshold: other.confidenceThreshold ?? confidenceThreshold,
                                        maxInline: other.maxInline ?? maxInline,
                                        capCredits: other.capCredits ?? capCredits)
        patch.maxChangedLines = other.maxChangedLines ?? maxChangedLines
        return patch
    }
}

extension ReviewYAML {
    static func map(_ text: String) throws -> [String: Any] {
        (try Yams.load(yaml: text) as? [String: Any]) ?? [:]
    }
}
