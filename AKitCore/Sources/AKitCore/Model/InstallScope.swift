import Foundation

/// Where a skill gets installed: for every project, or inside one project.
public enum InstallScope: Hashable, Sendable {
    case global
    case project(URL)
}
