import Foundation

/// The environment of the user's login shell. An app started from the Dock lacks what
/// `~/.zshrc` sets (the `PATH` to `pi`, provider keys), so Pi runs with the shell's.
public enum LoginEnvironment {
    static let marker = "__MEETINGS_LOGIN_ENV__"

    /// Runs `$SHELL -l -i -c` once and reads `env -0` after a marker; the app's own environment
    /// when that fails.
    public static func variables(timeout: TimeInterval = 20) async -> [String: String] {
        let own = ProcessInfo.processInfo.environment
        let shell = own["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let local = LocalEnvironment(tick: .milliseconds(100))
        let script = "printf '\\n%s\\n' \(marker); /usr/bin/env -0"
        guard let result = try? await ChildRun.run(URL(filePath: shell), ["-l", "-i", "-c", script], background: false, pausable: false,
                                                    timeout: timeout, local: local, resume: LocalStatus(phase: .summarizing)),
              let values = parse(String(decoding: result.output, as: UTF8.self)) else { return own }
        return values
    }

    static func parse(_ output: String) -> [String: String]? {
        guard let range = output.range(of: marker + "\n", options: .backwards) else { return nil }
        var values: [String: String] = [:]
        for entry in output[range.upperBound...].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else { continue }
            values[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return values.isEmpty ? nil : values
    }

    /// A program on the environment's `PATH`.
    public static func find(_ name: String, in variables: [String: String]) -> URL? {
        for folder in (variables["PATH"] ?? "").split(separator: ":") {
            let file = URL(filePath: String(folder)).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: file.path) { return file }
        }
        return nil
    }
}

/// M28: Pi writes the summary, decisions and tasks from the transcript, with the same prompt
/// and the same JSON answer as the OpenRouter call. Pi runs with nothing loaded but its model:
/// no tools, skills, context files or saved session.
public struct PiSummarizer: Sendable {
    let settings: MeetingsSettings
    let local: LocalEnvironment
    /// The login shell's environment; nil reads it.
    let environment: [String: String]?

    public init(settings: MeetingsSettings, local: LocalEnvironment, environment: [String: String]? = nil) {
        self.settings = settings
        self.local = local
        self.environment = environment
    }

    static let system = "You write short, faithful meeting notes. Answer with one JSON object only, no other text."

    static func arguments(model: String?, input: URL) -> [String] {
        var arguments = ["-p", "Write the meeting notes for the attached transcript.", "--mode", "text", "--no-session", "--offline",
                         "--no-tools", "--no-skills", "--no-context-files", "--no-prompt-templates", "--system-prompt", system]
        if let model, !model.isEmpty { arguments += ["--model", model] }
        return arguments + ["@\(input.path)"]
    }

    public func summarize(_ meeting: Meeting) async throws -> Transcriber.Summary {
        let variables = if let environment { environment } else { await LoginEnvironment.variables() }
        guard let pi = LoginEnvironment.find("pi", in: variables) else {
            throw MeetingsError.pi("pi is not on your login shell's PATH. Install Pi, or choose OpenRouter for the summary in Settings.")
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "meetings-pi-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "transcript.md")
        let prompt = Transcriber.summaryPrompt(language: settings.language, transcript: Transcriber.plainTranscript(meeting),
                                              template: settings.template(meeting.template), vocabulary: settings.vocabulary)
        try Data(prompt.utf8).write(to: input)
        let started = Date()
        // Pi waits on the network, not the CPU: it is not paused, only stopped.
        let result = try await ChildRun.run(pi, Self.arguments(model: settings.piModel, input: input), environment: variables, directory: folder,
                                            background: true, pausable: false, timeout: 900,
                                            local: local, resume: LocalStatus(phase: .summarizing))
        let text = String(decoding: result.output, as: UTF8.self)
        MeetingsLog.info(.pi, "summary: exit \(result.status), \(text.count) chars in \(Int(Date().timeIntervalSince(started))) s, model \(settings.piModel ?? "Pi's default")")
        guard result.status == 0 else {
            throw MeetingsError.pi("\(LocalTranscriber.tail(result.errors)) (exit \(result.status), model \(settings.piModel ?? "Pi's default")). Check that model in a terminal with pi, or choose another one in Meetings Settings → Pi.")
        }
        return try Transcriber.parseSummary(text)
    }

    /// `pi --list-models`: a table `provider  model  context …` → `provider/model`.
    public static func models(environment: [String: String]? = nil) async -> [String] {
        let variables = if let environment { environment } else { await LoginEnvironment.variables() }
        guard let pi = LoginEnvironment.find("pi", in: variables),
              let result = try? await ChildRun.run(pi, ["--list-models"], environment: variables, background: false, pausable: false, timeout: 60,
                                                   local: LocalEnvironment(tick: .milliseconds(100)), resume: LocalStatus(phase: .summarizing))
        else { return [] }
        return parseModels(String(decoding: result.output, as: UTF8.self))
    }

    static func parseModels(_ text: String) -> [String] {
        text.split(separator: "\n").dropFirst().compactMap { line in
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 2 else { return nil }
            return "\(columns[0])/\(columns[1])"
        }
    }
}
