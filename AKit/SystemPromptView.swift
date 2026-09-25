import AKitCore
import AppKit
import SwiftUI

/// System Prompt screen: what a harness sends before the first message, per project.
/// Claude Code: the prompt saved in the newest session of the project.
/// Pi: caught on request by starting Pi without a model request (see PiPromptProbe).
struct SystemPromptView: View {
    @Environment(AppModel.self) private var model
    @State private var harness: HarnessID?
    @State private var project: URL?

    var body: some View {
        Group {
            if let harness, let project {
                switch model.promptAccess(harness) {
                case .recorded: RecordedPromptView(harness: harness, project: project)
                case .captured: CapturedPromptView(harness: harness, project: project)
                case .unavailable: unavailable
                }
            } else if harnesses.isEmpty {
                unavailable
            } else {
                ContentUnavailableView("Choose a project", systemImage: "folder")
            }
        }
        .navigationTitle("System Prompt")
        .toolbar {
            ToolbarItem {
                Picker("Harness", selection: $harness) {
                    ForEach(harnesses, id: \.self) { Text($0.displayName).tag(HarnessID?.some($0)) }
                }
                .pickerStyle(.segmented)
                .help("Harness whose prompt is shown")
            }
            ToolbarItem {
                Picker("Project", selection: $project) {
                    ForEach(projects, id: \.self) { url in
                        Text(url.lastPathComponent.isEmpty ? url.tildePath : url.lastPathComponent)
                            .tag(URL?.some(url))
                    }
                }
                .frame(minWidth: 160)
                .help(project?.tildePath ?? "Folder the harness is started in")
            }
        }
        // Harnesses arrive with the first scan, possibly after the screen appeared.
        .onChange(of: model.installations, initial: true) {
            if harness.map(harnesses.contains) != true { harness = defaultHarness }
        }
        .onChange(of: harness, initial: true) { project = projects.first }
    }

    private var unavailable: some View {
        ContentUnavailableView("No harness shows its system prompt", systemImage: "doc.plaintext",
                               description: Text("Supported: Claude Code (saved in sessions) and Pi."))
    }

    private var defaultHarness: HarnessID? {
        let wanted = DebugSnapshot.options?.harness.flatMap { raw in harnesses.first { $0.rawValue == raw } }
        return wanted ?? harnesses.first
    }

    /// Installed harnesses whose prompt AKit can show.
    private var harnesses: [HarnessID] {
        model.installations.map(\.id).filter { model.promptAccess($0) != .unavailable }
    }

    /// Folders the harness was used in, most recent first. Pi can also be asked in the home folder.
    private var projects: [URL] {
        guard let harness else { return [] }
        var seen = Set<String>()
        var result = model.sessions.filter { $0.harness == harness }.compactMap(\.project)
        if model.promptAccess(harness) == .captured {
            result.append(FileManager.default.homeDirectoryForCurrentUser)
        }
        result = result.filter { seen.insert($0.standardizedFileURL.path).inserted }
        return result
    }
}

/// Claude Code: the prompt from the newest session in the project that has one.
private struct RecordedPromptView: View {
    @Environment(AppModel.self) private var model
    let harness: HarnessID
    let project: URL
    @State private var loaded: (prompt: PromptSnapshot, session: SessionSummary)?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        Group {
            if let loaded {
                PromptSnapshotView(snapshot: loaded.prompt) {
                    Text("Saved by \(harness.displayName) in the session “\(loaded.session.title)”, \(loaded.session.modified.formatted(date: .abbreviated, time: .shortened)). It is reused until the conversation is compacted.")
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Couldn't read the sessions", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ContentUnavailableView("No saved system prompt", systemImage: "doc.plaintext",
                                       description: Text("None of the sessions in \(project.tildePath) has one. Claude Code saves it in sessions since version 2.1.265; start a session there to see it."))
            }
        }
        .task(id: "\(harness)|\(project.path)|\(model.lastScan?.timeIntervalSince1970 ?? 0)") {
            isLoading = true
            error = nil
            do {
                let result = try await model.latestRecordedPrompt(harness: harness, project: project)
                guard !Task.isCancelled else { return }
                loaded = result
            } catch {
                loaded = nil
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

/// Pi: caught on request.
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
