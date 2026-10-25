import AKitKnowledge
import SwiftUI

/// Draw… and a double click on a drawing (NB10): the Excalidraw canvas of the maps, in Edit, for
/// one drawing of the notebook (`notebook/drawings/<name>.excalidraw`). Nothing is written while
/// you draw; Done saves the scene and its SVG picture, which the tab shows as an image
/// (`![](drawings/<name>.excalidraw.svg)`), so Obsidian shows it too.
struct NotebookDrawingSheet: View {
    @Environment(NotebookModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: NotebookModel.DrawingRequest
    @State private var working = false
    @State private var problem: String?

    /// The canvas key of a drawing: never a map's, so the map saves leave it alone.
    static let keyPrefix = "notebook:"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(request.hash == nil ? "New Drawing" : "Drawing").font(.headline)
                    Text("notebook/drawings/\(request.name).excalidraw").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if let problem { Text(problem).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Done") { Task { await done() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
                    .help(request.hash == nil ? "Save the drawing and put it into the tab at the cursor" : "Save the drawing; the tab shows the new picture")
            }
            .padding(10)
            Divider()
            MapCanvasView(scene: MapCanvasView.Scene(key: Self.keyPrefix + request.name, text: request.text), viewMode: false)
        }
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 600, idealHeight: 700)
    }

    private func done() async {
        guard let canvas = MapCanvasView.Coordinator.current, canvas.scene.key == Self.keyPrefix + request.name else { return }
        working = true
        defer { working = false }
        do {
            let scene = try await canvas.call("akitSerialize") as? String ?? ""
            let svg = try await canvas.call("akitExportSVG") as? String ?? ""
            if svg.isEmpty {
                if request.hash == nil { dismiss() } else { problem = "Draw something, or Cancel." }
                return
            }
            if await model.saveDrawing(scene: scene, svg: svg) { dismiss() }
        } catch {
            problem = "The canvas didn't answer: \(error.localizedDescription)"
        }
    }
}
