import AKitFoundation
import AKitKnowledge
import AKitLab
import SwiftUI

/// Knowledge → Draw Map with Pi… (5.4, K21, R-AP): an area (or a new one), a map name and what the
/// map shows. Run asks Pi, with no tools, for the map's excalidraw-cli DSL (`KnowledgeMapDrawer`),
/// labelled with the area's note names; AKit draws it with excalidraw-cli (through npx when it
/// isn't installed) and proposes the draft. It then waits in the Inbox for Accept… or Reject….
/// The prompt goes through the sending policy (purpose kb-draw). Pi without AKit does the same
/// from the terminal (the /akit skill).
struct DrawMapSheet: View {
    @Environment(KnowledgeModel.self) private var model
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// The new-area choice of the area Picker.
    private static let newAreaTag = "\u{1}new"
    @State private var area = ""
    @State private var newArea = ""
    @State private var name = ""
    @State private var prompt = ""
    @State private var modelName = ""
    @State private var models: [String] = []
    @State private var running = false
    /// Neither excalidraw-cli nor npx is on the PATH: Run stays off.
    @State private var missingDrawer: String?

    private var checkAgent: LabAgent { KnowledgeCheckModel.agent(settings: LabSettings.load(env: model.env)) }
    private var chosenArea: String { (area == Self.newAreaTag ? newArea : area).trimmingCharacters(in: .whitespaces) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// What `--tab draw-map` snapshots print.
    var manifest: String {
        "draw map: area \(chosenArea.isEmpty ? "-" : chosenArea), name \(trimmedName.isEmpty ? "-" : trimmedName), model "
            + "\(modelName.isEmpty ? checkAgent.model : modelName), prompt \(prompt.isEmpty ? "empty" : "\(prompt.count) characters"), Run "
            + (canRun ? "enabled" : "disabled") + (missingDrawer == nil ? "" : ", no excalidraw-cli or npx")
    }

    private var canRun: Bool {
        !running && missingDrawer == nil && !chosenArea.isEmpty && !trimmedName.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ![chosenArea, trimmedName].contains { $0.hasPrefix(".") || $0.contains("/") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Draw Map with Pi").font(.title3.bold())
            Text("Pi writes the map as excalidraw-cli text, with the area's note names as block labels. AKit draws it with excalidraw-cli (through npx when it isn't installed) and proposes the draft. It waits in the Inbox: Accept… links each block to its note and saves the map. Pi gets no tools and none of your skills; the prompt and the note names go through the sending policy (kb-draw).")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let missing = missingDrawer {
                Label(missing, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                Picker(selection: $area) {
                    ForEach(model.areas, id: \.name) { Text($0.name).tag($0.name) }
                    Divider()
                    Text("New Area…").tag(Self.newAreaTag)
                } label: { RequiredLabel("Area") }
                    .help("The area the map belongs to: one area per system or project (a new one is created when you accept the map)")
                if area == Self.newAreaTag {
                    TextField(text: $newArea, prompt: Text("support")) { RequiredLabel("New area") }
                }
                TextField(text: $name, prompt: Text("order-flow")) { RequiredLabel("Map name") }
                    .help("The map's file name: areas/AREA/maps/NAME.excalidraw; an existing map is replaced only when you accept")
                PiModelPicker(selection: $modelName, models: models, empty: "Knowledge check model (\(checkAgent.model))") {
                    Text("Model")
                }
                LabeledContent {
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                } label: { RequiredLabel("What the map shows") }
            }
            if !model.drawLog.isEmpty {
                GroupBox("Pi") {
                    ScrollView {
                        Text(model.drawLog.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 120)
                }
            }
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                if running {
                    Button("Stop") { model.drawTask?.cancel() }
                        .help("Stop Pi and everything it started; nothing is proposed")
                } else {
                    Button("Close", role: .cancel) { dismiss() }
                }
                Button("Run") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun)
                    .help("Start Pi with this prompt; the draft arrives in the Inbox")
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            // A sheet opened at launch (snapshots) waits for the base's areas.
            for _ in 0..<50 where model.areas.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            area = model.area ?? model.areas.first?.name ?? Self.newAreaTag
            missingDrawer = KnowledgeMapDrawer.missingDrawer(env: model.env)
            model.drawLog = []
            if DebugSnapshot.options?.tab == "draw-map" {
                if model.areas.contains(where: { $0.name == "payments" }) { area = "payments" }
                (name, prompt) = ("order-flow", DebugSnapshot.options?.query ?? "How an order reaches billing")
                print(manifest)
            }
            models = await app.labModels(for: .pi)
        }
    }

    private func run() {
        var agent = checkAgent
        let chosen = modelName.trimmingCharacters(in: .whitespaces)
        if !chosen.isEmpty { agent.model = chosen }
        let request = KnowledgeMapDrawer.Request(area: chosenArea, name: trimmedName, prompt: prompt, agent: agent)
        running = true
        model.drawTask = Task {
            if await model.drawMap(request) { dismiss() }
            running = false
            model.drawTask = nil
        }
    }
}
