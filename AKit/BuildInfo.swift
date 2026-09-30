import Foundation

/// Where this build of AKit comes from, stamped into BuildInfo.plist in the app's
/// resources at build time (see "Stamp build source" in project.yml).
struct BuildInfo {
    let sourcePath: String?
    let branch: String?
    let commit: String?
    /// Latest date tag, e.g. "v2026.09.29", and how many commits the build is past it.
    let versionTag: String?
    let commitsSinceTag: Int
    /// The build had uncommitted changes to tracked files.
    let isDirty: Bool
    let date: Date?

    static let current: BuildInfo = {
        let info = Bundle.main.url(forResource: "BuildInfo", withExtension: "plist")
            .flatMap { NSDictionary(contentsOf: $0) as? [String: Any] } ?? [:]
        func value(_ key: String) -> String? {
            (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return BuildInfo(sourcePath: value("AKitSourcePath") ?? SelfRebuild.sourceRoot?.path,
                         branch: value("AKitGitBranch").flatMap { $0 == "HEAD" ? nil : $0 },
                         commit: value("AKitGitCommit"),
                         versionTag: value("AKitVersionTag"),
                         commitsSinceTag: value("AKitCommitsSinceTag").flatMap { Int($0) } ?? 0,
                         isDirty: value("AKitGitDirty") == "yes",
                         date: value("AKitBuildDate").flatMap { try? Date($0, strategy: .iso8601) })
    }()

    /// Built from the main branch: the copy in everyday use. Anything else is a development build.
    var isProduction: Bool { branch == "master" || branch == "main" }

    /// "2026.09.29" on a tagged commit, "2026.09.29 + 3" three commits later, "*" = uncommitted changes.
    /// Without a tag (a shallow clone) the commit stands in.
    var version: String? {
        guard let tag = versionTag else { return commit.map { "\($0)\(isDirty ? "*" : "")" } }
        let number = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return number + (commitsSinceTag > 0 ? " + \(commitsSinceTag)" : "") + (isDirty ? "*" : "")
    }

    /// "rebuild-shortcut @ 596f14f*" (* = uncommitted changes).
    var revision: String? {
        let parts = [branch, commit.map { "@ \($0)\(isDirty ? "*" : "")" }].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var sourceURL: URL? { sourcePath.map { URL(filePath: $0) } }
}
