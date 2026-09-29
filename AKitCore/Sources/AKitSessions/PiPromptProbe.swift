import AKitFoundation
import Foundation

/// Pi keeps no copy of its system prompt, so AKit asks Pi itself: it runs
/// `pi --no-session --offline -p` in the project with a tiny temporary extension that
/// saves the final prompt when the agent starts and exits. No session is saved and
/// no model request is made (more hooks exit before any provider request).
/// Everything is written to a temporary folder that is removed afterwards.
enum PiPromptProbe {
    enum ProbeError: LocalizedError {
        case couldNotStart(URL)
        case missingFolder(URL)
        case noPrompt(output: String)

        var errorDescription: String? {
            switch self {
            case .couldNotStart(let url):
                "Couldn't start \(url.path)."
            case .missingFolder(let url):
                "The folder \(url.path) doesn't exist anymore."
            case .noPrompt(let output):
                "Pi exited without reporting its system prompt."
                    + (output.isEmpty ? "" : "\n\n" + output)
            }
        }
    }

    /// Pi fires handlers extension by extension, and `-e` extensions load first, so the
    /// probe can't be the last `before_agent_start` handler. It only notes the loaded
    /// context there; the final prompt, after every extension changed it, is read on
    /// `agent_start`, which comes before any provider request. Every path ends in
    /// `process.exit`, so an error in the probe can't let Pi go on to the model.
    static let extensionSource = """
    // AKit system prompt probe. Saves the final system prompt and exits before any model request.
    import { writeFileSync } from "node:fs";

    export default function (pi: any) {
      let options: any = {};
      pi.on("before_agent_start", (event: any) => {
        options = event.systemPromptOptions ?? {};
      });
      pi.on("agent_start", (_event: any, ctx: any) => {
        let code = 4;
        try {
          const active = new Set(pi.getActiveTools());
          const tools = pi.getAllTools()
            .filter((tool: any) => active.has(tool.name))
            .map((tool: any) => ({ name: tool.name, description: tool.description ?? "", parameters: tool.parameters ?? null }));
          writeFileSync(process.env.AKIT_PROMPT_OUT!, JSON.stringify({
            systemPrompt: ctx.getSystemPrompt(),
            tools,
            contextFiles: (options.contextFiles ?? []).map((file: any) => file.path),
            skills: (options.skills ?? []).map((skill: any) => skill.name),
          }));
          code = 0;
        } finally {
          process.exit(code);
        }
      });
      // Safety nets: never let the probe reach the model.
      pi.on("turn_start", () => process.exit(3));
      pi.on("before_provider_request", () => process.exit(3));
    }
    """

    static func capture(executable: URL, project: URL, env: HarnessEnvironment,
                        timeout: TimeInterval = 60) async throws -> PromptSnapshot {
        let fm = FileManager.default
        guard FileWalk.isDirectory(project) else { throw ProbeError.missingFolder(project) }
        let folder = fm.temporaryDirectory.appending(path: "akit-pi-probe-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let script = folder.appending(path: "akit-probe.ts")
        let output = folder.appending(path: "prompt.json")
        try Data(extensionSource.utf8).write(to: script)

        var childEnv = env.variables
        childEnv["PATH"] = env.pathForChildProcesses
        childEnv["NO_COLOR"] = "1"
        childEnv["AKIT_PROMPT_OUT"] = output.path
        let arguments = ["--no-session", "--offline", "-p", "-e", script.path, "AKit system prompt probe"]
        guard let result = await ProcessRunner.run(executable, arguments: arguments, directory: project,
                                                   environment: childEnv, timeout: timeout) else {
            throw ProbeError.couldNotStart(executable)
        }
        guard let data = try? Data(contentsOf: output), let snapshot = snapshot(from: data, project: project) else {
            throw ProbeError.noPrompt(output: lastLines(PiSessions.stripANSI(result.output)))
        }
        return snapshot
    }

    static func snapshot(from data: Data, project: URL, at date: Date = .now) -> PromptSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? JSONLines.Object,
              let prompt = json["systemPrompt"] as? String else { return nil }
        var context: [PromptContextPart] = []
        if let files = json["contextFiles"] as? [String], !files.isEmpty {
            context.append(PromptContextPart(id: 0, title: "Context files (\(files.count))",
                                             text: files.joined(separator: "\n") + "\n\nTheir text is part of the system prompt."))
        }
        if let skills = json["skills"] as? [String], !skills.isEmpty {
            context.append(PromptContextPart(id: 1, title: "Skills (\(skills.count))", text: skills.joined(separator: "\n")))
        }
        return PromptSnapshot(harness: .pi, source: .captured(project: project, at: date), sections: [SecretFilter.masked(prompt)],
                              tools: PromptTool.list(json["tools"]), context: context)
    }

    private static func lastLines(_ text: String, count: Int = 15) -> String {
        text.split(whereSeparator: \.isNewline).suffix(count).joined(separator: "\n")
    }
}
