import AKitFoundation
import AKitModel
import Foundation
import SwiftUI

extension URL {
    /// `/Users/name/.claude` → `~/.claude`
    var tildePath: String {
        let home = HarnessEnvironment.current.homeDirectory.path
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
        case .bundled(let harness): "Built into \(harness.displayName)"
        case .package(let name, nil): "Pi package · \(name)"
        case .package(let name, let project?): "Pi package · \(name) · \(project.lastPathComponent)"
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
        case .openCode: return .green
        case .codex: return .purple
        default:
            // Stable color per harness id.
            let palette: [Color] = [.pink, .teal, .indigo, .mint, .brown, .cyan]
            let sum = harness.rawValue.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            return palette[sum % palette.count]
        }
    }
}
