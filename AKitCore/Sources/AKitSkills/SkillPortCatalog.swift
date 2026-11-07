import AKitFoundation
import Foundation

/// The alternatives catalog (`docs/design/skill-port.md`, "Alternatives catalog"): families of
/// interchangeable tools (test frameworks, package managers, HTTP clients, …) as data, each member
/// with the tokens that detect it and the tokens that must not remain after switching away, plus
/// pairwise rules where they are known. The code here names no technology: the bundled data is in
/// `SkillPortCatalogData.swift`, the user's own entries in `~/.akit/port-presets/catalog.json`.
public struct SkillPortCatalog: Codable, Sendable, Hashable {
    public struct Member: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        /// Regular expressions; any match means the skill uses this member.
        public var tokens: [String]
        /// Literal tokens that must not remain once the skill switches away from it.
        public var forbid: [String]
    }

    public struct Pair: Codable, Sendable, Hashable {
        public var from: String
        public var to: String
        /// A rules text (`SkillPortRules`).
        public var rules: String
    }

    public struct Family: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var members: [Member]
        public var pairs: [Pair]
    }

    public var families: [Family]

    public init(families: [Family]) { self.families = families }

    public static var bundled: SkillPortCatalog {
        (try? JSONDecoder().decode(SkillPortCatalog.self, from: Data(bundledPortCatalog.utf8))) ?? SkillPortCatalog(families: [])
    }

    public static func userFile(env: HarnessEnvironment) -> URL {
        SkillPortRules.presetsFolder(env: env).appending(path: "catalog.json")
    }

    /// The bundled catalog with the user's entries: a family of a known id gets the user's members
    /// and pairs (a member or pair of the same id replaces the bundled one); new families are added.
    /// A user file that doesn't parse is an error, not silently ignored.
    public static func load(env: HarnessEnvironment) throws -> SkillPortCatalog {
        var catalog = bundled
        let file = userFile(env: env)
        guard let data = try? Data(contentsOf: file) else { return catalog }
        let user: SkillPortCatalog
        do { user = try JSONDecoder().decode(SkillPortCatalog.self, from: data) } catch {
            throw SkillPortRules.Failure(message: "\(file.path) is not a port catalog: \(error.localizedDescription)")
        }
        for family in user.families {
            guard let index = catalog.families.firstIndex(where: { $0.id == family.id }) else {
                catalog.families.append(family)
                continue
            }
            for member in family.members {
                catalog.families[index].members.removeAll { $0.id == member.id }
                catalog.families[index].members.append(member)
            }
            for pair in family.pairs {
                catalog.families[index].pairs.removeAll { $0.from == pair.from && $0.to == pair.to }
                catalog.families[index].pairs.append(pair)
            }
        }
        return catalog
    }

    /// Every known pair as a preset, named `<from>-to-<to>`.
    public var presets: [String: String] {
        var result: [String: String] = [:]
        for family in families {
            for pair in family.pairs { result["\(pair.from)-to-\(pair.to)"] = pair.rules }
        }
        return result
    }

    /// The members of each family the texts use.
    func found(in texts: [String]) -> [(family: Family, members: [Member])] {
        families.compactMap { family in
            let members = family.members.filter { member in
                member.tokens.contains { token in
                    guard let regex = try? NSRegularExpression(pattern: token) else { return false }
                    return texts.contains { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
                }
            }
            return members.isEmpty ? nil : (family, members)
        }
    }

    /// The rules of switching `from` to `to`: the known pair's, else a note for the model and the
    /// forbidden tokens of `from`.
    func rules(family: Family, from: Member, to: Member) -> String {
        if let pair = family.pairs.first(where: { $0.from == from.id && $0.to == to.id }) { return pair.rules }
        return (["note: Use \(to.title) instead of \(from.title) as the \(family.title): imports, APIs, config file names and commands."]
                + from.forbid.map { "forbid: \($0)" }).joined(separator: "\n")
    }
}
