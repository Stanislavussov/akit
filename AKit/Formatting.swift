import AKitCore
import Foundation
import SwiftUI

extension URL {
    /// `/Users/name/.claude` → `~/.claude`
    var tildePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

extension SkillScope {
    var title: String {
        switch self {
        case .global: "Global"
        case .project(let url): "Project · \(url.lastPathComponent)"
        case .synced: "claude.ai (synced)"
        case .plugin(let name): "Plugin · \(name)"
        }
    }
}

/// Small colored capsule: "Claude", "Pi".
struct HarnessBadge: View {
    let harness: HarnessID

    var body: some View {
        Text(harness.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch harness {
        case .claudeCode: return .orange
        case .pi: return .blue
        default:
            // Stable color per harness id.
            let palette: [Color] = [.green, .purple, .pink, .teal, .indigo, .mint, .brown]
            let sum = harness.rawValue.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            return palette[sum % palette.count]
        }
    }
}
