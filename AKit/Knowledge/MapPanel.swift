import AppKit
import SwiftUI

/// The map in view: its name and path, Edit, Show in Finder, Delete… and Close Map, and the
/// Excalidraw canvas. In view mode a click on a block or arrow opens its link: a note beside the
/// map, a map in its place, a web link in the default browser. In Edit every change is saved to
/// the file 800 ms after the last one, byte for byte as Excalidraw wrote it, and committed with
/// the other edits (U2).
struct MapPanel: View {
    @Environment(KnowledgeModel.self) private var model

    var body: some View {
        @Bindable var model = model
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
                    Toggle("Edit", systemImage: "pencil", isOn: $model.mapEditing)
                        .toggleStyle(.button)
                        .help(model.mapEditing
                            ? "Back to viewing: a click on a block opens its note. Your changes are saved already"
                            : "Edit the map. Every change is saved to the file at once and committed when you close the map, after 5 minutes without edits, or when AKit quits")
                    Button("Show in Finder", systemImage: "folder") {
                        if let base = model.base { NSWorkspace.shared.activateFileViewerSelecting([base.mapFile(id)]) }
                    }
                    .help("Show the map's .excalidraw file in Finder")
                    Button("Delete…", systemImage: "trash") { model.mapDeleteRequest = id }
                        .help("Move the map to the Trash and commit its removal")
                    Button("Close Map", systemImage: "xmark") { Task { await model.closeMap() } }
                        .help("Back to the note panel; your saved changes are committed now")
                }
                .labelStyle(.titleAndIcon)
                .controlSize(.small)
                .padding(8)
                Divider()
                MapCanvasView(scene: model.mapScene, viewMode: !model.mapEditing) { message in
                    switch message.type {
                    case "linkOpen":
                        if let link = message.body["link"] as? String { model.openLink(link) }
                    case "save":
                        if let key = message.body["key"] as? String, let json = message.body["json"] as? String { model.saveMap(key, json: json) }
                    default: break
                    }
                }
            }
        }
    }
}

/// New Map…: `akit kb new-map AREA NAME`, committed at once; the new map opens in Edit.
struct NewMapSheet: View {
    @Environment(KnowledgeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var area = ""
    @State private var name = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Map").font(.title3.bold())
            Text("An empty Excalidraw map in the space's maps/ folder. Draw blocks, give each a link to its note, like [[orders-api]], and join them with arrows.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker(selection: $area) {
                    ForEach(model.areas, id: \.name) { Text($0.name).tag($0.name) }
                } label: { RequiredLabel("Area") }
                TextField(text: $name, prompt: Text("overview")) { RequiredLabel("Name") }
            }
            if model.areas.isEmpty {
                Text("Add an area first: New Area….").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add Map") {
                    working = true
                    Task {
                        if await model.newMap(area: area, name: name) { dismiss() }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(area.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { area = model.area ?? model.areas.first?.name ?? "" }
    }
}
