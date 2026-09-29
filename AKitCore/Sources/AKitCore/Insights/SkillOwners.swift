import Foundation

/// Who a listed skill belongs to, which decides what can be done about it: a layer skill gets a
/// `layer.yaml` edit, a plugin advice, a hand-installed skill "import it into the brain", a
/// built-in skill only its size.
enum SkillOwner: Hashable {
    /// Rendered by AKit from the brain for these layers.
    case layer([String])
    /// Shipped by a Claude Code plugin (`plugin:skill`).
    case plugin(String)
    /// Installed on this Mac, not from the brain. The skill file, as the harness sees it.
    case handInstalled(String)
    /// No skill file anywhere: part of the harness itself.
    case builtIn
    /// Installed, but whether it came from the brain can't be told (no brain, or a copy AKit
    /// didn't render under the brain's name).
    case unknown
    /// These brain layers list it, but the installed copy (`file`, as the harness sees it) is not
    /// one AKit rendered, so their mode doesn't reach it (`akit apply` skips files it didn't
    /// write). Counted as `unknown` in the stats, whose owner kinds stay as they were.
    case unrendered(layers: [String], file: String)

    enum Kind: String, CaseIterable {
        case layer, plugin, handInstalled, builtIn, unknown
    }

    var kind: Kind {
        switch self {
        case .layer: .layer
        case .plugin: .plugin
        case .handInstalled: .handInstalled
        case .builtIn: .builtIn
        case .unknown, .unrendered: .unknown
        }
    }

    /// Layers joined by commas, the plugin, or the skill file; nil for built-in and unknown.
    var name: String? {
        switch self {
        case .layer(let layers): layers.joined(separator: ",")
        case .plugin(let name): name
        case .handInstalled(let path): path
        case .builtIn, .unknown, .unrendered: nil
        }
    }
}

enum SkillOwners {
    /// Owners of the listed skill names. `installed`: skills `SkillScanner` found on this Mac;
    /// `links`: their `BrainLinks`, nil without a brain (then no own skill can be told apart from
    /// a layer skill, and every one is unknown). `layers`: the brain's, to tell which of them list
    /// a skill whose installed copy AKit didn't render.
    static func classify(_ names: some Sequence<String>, installed: [Skill], links: [Skill.ID: BrainLink]?,
                         layers: [Layer] = [], home: URL) -> [String: SkillOwner] {
        let byName = Dictionary(grouping: installed, by: \.name)
        var owners: [String: SkillOwner] = [:]
        for name in names {
            owners[name] = owner(of: name, matches: byName[name] ?? [], links: links, layers: layers, home: home)
        }
        return owners
    }

    private static func owner(of name: String, matches: [Skill], links: [Skill.ID: BrainLink]?, layers brainLayers: [Layer],
                              home: URL) -> SkillOwner {
        // Claude Code lists plugin skills as `plugin:skill`; a name itself never holds ":".
        if let colon = name.firstIndex(of: ":") { return .plugin(String(name[..<colon])) }
        guard !matches.isEmpty else { return .builtIn }
        var layers: Set<String> = []
        for skill in matches {
            if case .rendered(_, let names, _)? = links?[skill.id] { layers.formUnion(names) }
        }
        if !layers.isEmpty { return .layer(layers.sorted()) }
        let own = matches.filter { skill in
            switch skill.scope {
            case .global, .project: true
            case .synced, .plugin, .bundled: false
            }
        }
        if own.isEmpty {
            if case .plugin(let plugin) = matches[0].scope { return .plugin(plugin) }
            if case .bundled = matches[0].scope { return .builtIn }
            return .handInstalled(FileWalk.tilde(matches[0].file, home: home))
        }
        guard let links else { return .unknown }
        if let hand = own.first(where: { links[$0.id] == .notInBrain }) {
            return .handInstalled(FileWalk.tilde(hand.file, home: home))
        }
        let listing = brainLayers.filter { $0.skills.contains { $0.name == name } }.map(\.name).sorted()
        if !listing.isEmpty, let copy = own.first(where: { links[$0.id] == .sameName }) {
            return .unrendered(layers: listing, file: FileWalk.tilde(copy.file, home: home))
        }
        return .unknown
    }
}
