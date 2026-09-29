import Foundation

/// Finds project folders inside "project roots" such as `~/Projects`.
/// A folder counts as a project if it has harness files (.claude, .pi, .agents,
/// CLAUDE.md, AGENTS.md). Looks two levels deep (`~/Projects/x`, `~/Projects/group/x`).
public enum ProjectFinder {
    public static let defaultRoots = ["~/Projects"]
    static let markers = [".claude", ".pi", ".agents", "CLAUDE.md", "AGENTS.md"]

    public static func projects(inRoots roots: [URL], maxDepth: Int = 2) -> [URL] {
        var result: [URL] = []
        for root in roots {
            collect(root, depth: 0, maxDepth: maxDepth, into: &result)
        }
        return result
    }

    private static func collect(_ dir: URL, depth: Int, maxDepth: Int, into result: inout [URL]) {
        guard depth < maxDepth else { return }
        for child in FileWalk.children(of: dir) where FileWalk.isDirectory(child) {
            if child.lastPathComponent == "node_modules" { continue }
            if isProject(child) {
                result.append(child)
            } else {
                collect(child, depth: depth + 1, maxDepth: maxDepth, into: &result)
            }
        }
    }

    public static func isProject(_ dir: URL) -> Bool {
        markers.contains { FileManager.default.fileExists(atPath: dir.appending(path: $0).path) }
    }
}
