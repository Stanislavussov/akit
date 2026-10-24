import AppKit
import SwiftUI

/// The map in view: its name and path, and the Excalidraw canvas in view mode (nothing can be
/// edited yet). A click on a block or arrow opens its link: a note beside the map, a map in its
/// place, a web link in the default browser.
struct MapPanel: View {
    @Environment(KnowledgeModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let id = model.map {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(id.split(separator: "/").dropFirst(2).joined(separator: "/")).font(.headline).lineLimit(1)
                        Text("areas/\(id).excalidraw").font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                    }
                    Spacer()
                    if let notice = model.notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text("View only").font(.caption).foregroundStyle(.secondary)
                        .help("Maps can't be edited here yet. Click a block or an arrow to open its note")
                    Button("Show in Finder", systemImage: "folder") {
                        if let base = model.base { NSWorkspace.shared.activateFileViewerSelecting([base.areasFolder.appending(path: id + ".excalidraw")]) }
                    }
                    .help("Show the map's .excalidraw file in Finder")
                    Button("Close Map", systemImage: "xmark") { model.closeMap() }
                        .help("Back to the note panel")
                }
                .labelStyle(.titleAndIcon)
                .controlSize(.small)
                .padding(8)
                Divider()
                MapCanvasView(scene: model.mapScene) { message in
                    if message.type == "linkOpen", let link = message.body["link"] as? String { model.openLink(link) }
                }
            }
        }
    }
}
