import AppKit
import SwiftUI

/// Bottom of the sidebar: Production (main branch) or Development, with branch,
/// commit and source folder, so several running copies can be told apart.
struct BuildBadge: View {
    let info: BuildInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(info.isProduction ? "Production" : "Development",
                  systemImage: info.isProduction ? "checkmark.seal.fill" : "hammer.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(info.isProduction ? .green : .orange)
            if let revision = info.revision {
                Text(revision).monospaced()
            }
            if let folder = info.sourceURL?.lastPathComponent {
                Label(folder, systemImage: "folder")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help(tooltip)
        .contextMenu {
            if let url = info.sourceURL {
                Button("Show Source in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Copy Source Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            }
        }
    }

    private var tooltip: String {
        var lines = ["Built from \(info.sourceURL?.tildePath ?? "an unknown folder")"]
        if let revision = info.revision { lines.append("Branch \(revision)") }
        if info.isDirty { lines.append("* the build had uncommitted changes") }
        if let date = info.date { lines.append("Built \(date.formatted(date: .abbreviated, time: .shortened))") }
        return lines.joined(separator: "\n")
    }
}
