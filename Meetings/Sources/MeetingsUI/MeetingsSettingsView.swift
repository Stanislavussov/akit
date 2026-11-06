import AppKit
import MeetingsCore
import SwiftUI

/// Settings: the OpenRouter key (M9), the models from OpenRouter's list with the price of one
/// hour (M10), the summary's language (M14), the monthly limit (M11), the folder, echo
/// cancellation.
struct MeetingsSettingsView: View {
    @Bindable var model: MeetingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var limit = 10.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meetings Settings").font(.title3.bold())
            Form {
                Section("OpenRouter") {
                    if model.hasKey {
                        LabeledContent("Key") {
                            HStack {
                                Text("Saved in the Keychain").foregroundStyle(.secondary)
                                Button("Remove") { model.removeKey() }
                            }
                        }
                    }
                    HStack {
                        SecureField(text: $key, prompt: Text("sk-or-…")) {
                            HStack(spacing: 2) {
                                Text(model.hasKey ? "New key" : "Key")
                                if !model.hasKey { Text("*").foregroundStyle(.red) }
                            }
                        }
                        Button("Save Key") {
                            model.saveKey(key)
                            key = ""
                        }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let problem = model.keyProblem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                    } else if let notice = model.notice, notice.contains("key") {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Kept in the login Keychain, never shown or written to a file. Create one at openrouter.ai/keys (it starts with sk-or-v1-).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Models") {
                    Picker("Transcription", selection: Binding(get: { model.settings.model }, set: { value in model.update { $0.model = value } })) {
                        ForEach(rows(model.audioModels, keeping: model.settings.model)) { row in
                            Text(label(row)).tag(row.id)
                        }
                    }
                    Picker("Summary", selection: Binding(get: { model.settings.summaryModel ?? "" }, set: { value in model.update { $0.summaryModel = value.isEmpty ? nil : value } })) {
                        Text("Same as transcription").tag("")
                        ForEach(rows(model.textModels, keeping: model.settings.summaryModel)) { row in
                            Text(label(row)).tag(row.id)
                        }
                    }
                    HStack {
                        if model.loadingModels {
                            ProgressView().controlSize(.small)
                            Text("Loading OpenRouter's models…")
                        } else if let problem = model.modelsProblem {
                            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        } else {
                            Text("\(model.audioModels.count) models take audio. ★ recommended: cheap and good at Czech. The price is an estimate for one hour; each meeting shows what OpenRouter charged.")
                        }
                        Spacer()
                        Button("Reload") { Task { await model.loadModels() } }.disabled(model.loadingModels)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Section("Vocabulary") {
                    VocabularyEditor(model: model)
                }
                Section("Language") {
                    Picker("Summary and tasks", selection: Binding(get: { model.settings.language }, set: { value in model.update { $0.language = value } })) {
                        ForEach(languages, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Spoken language", text: Binding(get: { model.settings.spokenHint }, set: { value in model.update { $0.spokenHint = value } }),
                              prompt: Text("Czech, sometimes Russian or English"))
                    Text("The transcript stays in the language spoken; this hint helps the model.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Summary") {
                    Picker("Template of a new meeting", selection: Binding(get: { model.settings.template(nil).id }, set: { value in model.update { $0.defaultTemplate = value } })) {
                        ForEach(model.settings.templates) { Text($0.name).tag($0.id) }
                    }
                    Text("A template says which sections the summary lists besides Summary, Decisions and Tasks. Each meeting's header can change it.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.settings.customTemplates) { template in
                        OwnTemplateRow(model: model, template: template)
                    }
                    Button("Add Template") {
                        model.update { settings in
                            settings.customTemplates.append(MeetingTemplate(id: MeetingTemplate.newID(), name: "My template",
                                                                            sections: "Heading: what goes in it"))
                        }
                    }
                    .help("Your own kind of meeting: a name and one section per line")
                }
                Section("Transcript") {
                    Picker("Text", selection: Binding(get: { model.settings.cleanTranscript }, set: { value in model.update { $0.cleanTranscript = value } })) {
                        Text("Clean: no filler words or repeats").tag(true)
                        Text("Word for word").tag(false)
                    }
                    Text("Clean leaves out eh, ehm, stutters and words said twice; every word that carries meaning stays. Same call, same cost. Takes effect at the next transcription.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Tracks") {
                    Picker("Send to the model", selection: Binding(get: { model.settings.tracks }, set: { value in model.update { $0.tracks = value } })) {
                        ForEach(MeetingsSettings.TrackMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("The microphone (you and the room) and the system sound (the call) are recorded apart. Auto sends a 30-minute part as two tracks when the room and the call talk at the same time for more than \(Int(MeetingProcessor.overlapForTwoTracks)) s, so overlapping voices are not lost; that part costs twice.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Recording") {
                    Toggle("Echo cancellation", isOn: Binding(get: { model.settings.echoCancellation }, set: { value in model.update { $0.echoCancellation = value } }))
                    Text("Keeps the sound from the speakers out of the microphone, so the other people are not recorded twice. Takes effect at the next Record.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Folder") {
                        HStack {
                            Text(model.root.path.replacingOccurrences(of: userHome.path, with: "~")).textSelection(.enabled)
                            Button("Choose…") { chooseFolder() }.disabled(model.isRecording)
                        }
                    }
                    Text("Audio goes to the Trash \(MeetingStore.audioDays) days after a recording; summaries, transcripts and tabs stay.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Log") {
                    HStack {
                        Text(MeetingsLog.file.path.replacingOccurrences(of: userHome.path, with: "~")).textSelection(.enabled)
                        Spacer()
                        Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([MeetingsLog.file]) }
                        Button("Copy Log") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(MeetingsLog.tail(), forType: .string)
                        }
                    }
                    Text("What recording and OpenRouter did: times, sizes, answer codes. Never the key, audio or what was said.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Cost") {
                    HStack {
                        TextField("Monthly limit, $", value: $limit, format: .number.precision(.fractionLength(0...2)))
                            .onSubmit { model.update { $0.monthlyLimitUSD = max(0, limit) } }
                        Text(String(format: "This month: $%.2f", model.monthCost)).foregroundStyle(.secondary)
                    }
                    Text("At the limit, new transcriptions wait; recording goes on.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") {
                    model.update { $0.monthlyLimitUSD = max(0, limit) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 720)
        .onAppear { limit = model.settings.monthlyLimitUSD }
        .task {
            if model.hasKey { await model.checkKey() }
            if model.audioModels.isEmpty { await model.loadModels() }
        }
    }

    private var languages: [String] {
        MeetingsSettings.languages.contains(model.settings.language) ? MeetingsSettings.languages : MeetingsSettings.languages + [model.settings.language]
    }

    /// The rows, with the chosen model kept even when the list is not loaded or lacks it.
    private func rows(_ rows: [ModelCatalog.Row], keeping id: String?) -> [ModelCatalog.Row] {
        guard let id, !id.isEmpty, !rows.contains(where: { $0.id == id }) else { return rows }
        return [ModelCatalog.Row(id: id, name: id, hourCost: nil, recommended: ModelCatalog.isRecommended(id))] + rows
    }

    private func label(_ row: ModelCatalog.Row) -> String {
        (row.recommended ? "★ " : "") + row.id + " — " + ModelCatalog.priceText(row.hourCost)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.root
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { model.update { $0.rootPath = url.path } }
    }
}

/// One own template (M22): its name, its sections (one per line, `Heading: what goes in it`), Remove.
struct OwnTemplateRow: View {
    let model: MeetingsModel
    let template: MeetingTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: binding(\.name))
                Button("Remove", role: .destructive) {
                    model.update { settings in
                        settings.customTemplates.removeAll { $0.id == template.id }
                        if settings.defaultTemplate == template.id { settings.defaultTemplate = MeetingTemplate.generalID }
                    }
                }
            }
            TextEditor(text: binding(\.sections))
                .font(.callout.monospaced())
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            Text("One section per line: Heading: what goes in it.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func binding(_ field: WritableKeyPath<MeetingTemplate, String>) -> Binding<String> {
        Binding(get: { model.settings.customTemplates.first { $0.id == template.id }?[keyPath: field] ?? "" },
                set: { value in
                    model.update { settings in
                        if let i = settings.customTemplates.firstIndex(where: { $0.id == template.id }) { settings.customTemplates[i][keyPath: field] = value }
                    }
                })
    }
}

/// M27: the project's words, one per line; Import… reads a text, Markdown or CSV file.
struct VocabularyEditor: View {
    let model: MeetingsModel
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                .onChange(of: text) { _, new in
                    let terms = MeetingsSettings.vocabulary(from: new)
                    if terms != model.settings.vocabulary { model.update { $0.vocabulary = terms } }
                }
            HStack {
                let count = model.settings.vocabulary.count
                Text("\(count) term\(count == 1 ? "" : "s")" + (count > MeetingsSettings.vocabularyLimit ? ", the first \(MeetingsSettings.vocabularyLimit) are sent" : ""))
                Spacer()
                Button("Import…", action: importFile)
                    .help("Add the words of a .txt, .md or .csv file: one per line or separated by commas")
                Button("Clear") { text = "" }.disabled(text.isEmpty)
            }
            .font(.caption)
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
            Text("Names, services, products and terms of your project, one per line; \"Kafka — message broker\" adds a hint. They go with every transcription and summary, so the model writes them right instead of a word that sounds close. Takes effect at the next transcription; Transcribe Again uses them for an older meeting.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { text = model.settings.vocabulary.joined(separator: "\n") }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .init(filenameExtension: "md") ?? .plainText, .init(filenameExtension: "tsv") ?? .plainText]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let added = MeetingsSettings.vocabulary(from: try String(contentsOf: url, encoding: .utf8))
            let merged = MeetingsSettings.vocabulary(from: (model.settings.vocabulary + added).joined(separator: "\n"))
            text = merged.joined(separator: "\n")
            problem = nil
        } catch {
            problem = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
