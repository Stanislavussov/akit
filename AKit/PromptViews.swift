import AKitModel
import AKitSessions
import AppKit
import SwiftUI

/// Pi: caught on request (see PiPromptProbe), for the project of a session.
struct CapturedPromptView: View {
    @Environment(AppModel.self) private var model
    let harness: HarnessID
    let project: URL
    @State private var isCapturing = false
    @State private var error: String?

    var body: some View {
        Group {
            if let prompt = model.capturedPrompt(harness: harness, project: project) {
                PromptSnapshotView(snapshot: prompt) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(captionText(prompt))
                        Spacer()
                        captureButton("Capture Again")
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("\(harness.displayName) doesn't save its system prompt", systemImage: "doc.plaintext")
                } description: {
                    Text("AKit can start \(harness.displayName) in \(project.tildePath) and read the prompt it would send. No message goes to the model and no session is saved. Its extensions do load, as in a normal start.")
                    if let error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                } actions: {
                    captureButton("Capture System Prompt")
                }
            }
        }
        .task(id: "\(harness)|\(project.path)") {
            error = nil
            if DebugSnapshot.options?.capture == true, model.capturedPrompt(harness: harness, project: project) == nil {
                await capture()
            }
        }
    }

    private func captionText(_ prompt: PromptSnapshot) -> String {
        guard case .captured(let folder, let date) = prompt.source else { return "" }
        return "Caught from \(harness.displayName) in \(folder.tildePath) at \(date.formatted(date: .omitted, time: .shortened)). Extensions may still change it for a given message."
    }

    private func captureButton(_ title: String) -> some View {
        Button {
            Task { await capture() }
        } label: {
            if isCapturing {
                ProgressView().controlSize(.small)
            } else {
                Text(title)
            }
        }
        .disabled(isCapturing)
    }

    private func capture() async {
        isCapturing = true
        error = nil
        do {
            try await model.capturePrompt(harness: harness, project: project)
        } catch {
            self.error = error.localizedDescription
        }
        isCapturing = false
    }
}

/// The prompt, the tools and the loaded context of one snapshot.
struct PromptSnapshotView<Caption: View>: View {
    let snapshot: PromptSnapshot
    @ViewBuilder let caption: Caption

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    caption
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(summary).font(.callout.weight(.medium))
                        Spacer()
                        Button("Copy Prompt", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(snapshot.systemPrompt, forType: .string)
                        }
                        .help("Copy the system prompt text")
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(snapshot.sections.enumerated()), id: \.offset) { index, section in
                            if index > 0 { Divider() }
                            LongText(text: section, monospaced: true, limit: 12_000)
                        }
                    }
                    .padding(4)
                } label: {
                    Text("System prompt").font(.headline)
                }

                if !snapshot.tools.isEmpty {
                    section("Tools (\(snapshot.tools.count))") {
                        ForEach(snapshot.tools) { tool in
                            Collapsible(title: tool.name, icon: "wrench.and.screwdriver", tint: .teal,
                                        text: tool.schema.isEmpty ? tool.description : "\(tool.description)\n\nInput schema:\n\(tool.schema)",
                                        monospaced: true)
                        }
                    }
                }

                if !snapshot.context.isEmpty {
                    section("Loaded context (\(snapshot.context.count))") {
                        ForEach(snapshot.context) { part in
                            Collapsible(title: part.title, icon: "tray.full", tint: .orange,
                                        text: part.source.map { "\(URL(filePath: $0).tildePath)\n\n\(part.text)" } ?? part.text,
                                        monospaced: true)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summary: String {
        var parts = ["≈ \(snapshot.estimatedTokens.formatted()) tokens"]
        if snapshot.sections.count > 1 { parts.append("\(snapshot.sections.count) blocks") }
        parts.append("\(snapshot.tools.count) tools")
        if !snapshot.context.isEmpty { parts.append("\(snapshot.context.count) context parts") }
        return parts.joined(separator: " · ")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }
}
