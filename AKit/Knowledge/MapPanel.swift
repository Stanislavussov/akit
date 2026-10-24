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
                tabBar
                Divider()
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
                    Button("Rename…", systemImage: "character.cursor.ibeam") { model.renameRequest = id }
                        .help("Rename the map and every link to it ([[maps/…]]) in notes and maps, all or nothing, in one commit")
                    Button("Delete…", systemImage: "trash") { model.mapDeleteRequest = id }
                        .help("Move the map to the Trash and commit its removal")
                    Button("Close Map", systemImage: "xmark") { Task { await model.closeMap() } }
                        .help("Close this map's tab; your saved changes are committed now")
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
                // A note dragged from the list becomes a block linked to it (K6).
                .dropDestination(for: String.self) { ids, location in
                    guard let id = ids.first else { return false }
                    Task { await model.drop(note: id, at: location) }
                    return true
                }
            }
        }
    }

    /// The open maps of this area, one tab each; the cross closes one (its changes are committed).
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.areaMapTabs, id: \.self) { id in
                    HStack(spacing: 4) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary)
                        Text(id.split(separator: "/").dropFirst(2).joined(separator: "/")).lineLimit(1)
                        Button("Close Tab", systemImage: "xmark") { Task { await model.close(mapTab: id) } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("Close the map's tab; your saved changes are committed now")
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(id == model.map ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .onTapGesture { if id != model.map { model.open(map: id) } }
                    .help(id)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }
}

/// Rename… of a note or a map: the new name and the planned changes (every link that changes),
/// or why the rename is refused. Rename writes it all in one commit (`akit kb rename`).
struct RenameSheet: View {
    @Environment(KnowledgeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var name = ""
    @State private var working = false

    private var isMap: Bool { id.split(separator: "/").dropLast().contains("maps") }

    var body: some View {
        let new = name.trimmingCharacters(in: .whitespaces)
        let plan = new.isEmpty ? nil : model.planRename(id, to: new)
        VStack(alignment: .leading, spacing: 12) {
            Text(isMap ? "Rename Map" : "Rename Note").font(.title3.bold())
            Text("Renames \(id) and rewrites every link to it in the notes and maps of this base, keeping aliases and #headings. All or nothing, in one commit.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField(text: $name, prompt: Text(isMap ? "flows" : "invoicing")) { RequiredLabel("New name") }
                    .help(isMap ? "A name in the same maps/ folder" : "A name in the same folder, or area/name to move the note to another space")
            }
            GroupBox {
                ScrollView {
                    Group {
                        switch plan {
                        case .success(let plan)?:
                            Text("\(plan.linkCount) link\(plan.linkCount == 1 ? "" : "s") change:\n" + plan.diff)
                        case .failure(let error)?:
                            Text(error.message).foregroundStyle(.red)
                        case nil:
                            Text("Type the new name to see what changes.").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
            } label: {
                Text("Changes")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Rename") {
                    working = true
                    Task {
                        if await model.rename(id, to: new) { dismiss() }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || { if case .success? = plan { false } else { true } }())
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { name = DebugSnapshot.options?.tab == "rename" ? DebugSnapshot.options?.query ?? "" : "" }
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
