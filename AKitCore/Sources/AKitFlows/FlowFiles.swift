import AKitFoundation
import AKitHarnesses
import Foundation

/// The flow files Pi reads (F11): the project's `.pi/flows/*.yaml` first, then `~/.pi/agent/flows/`.
/// A project flow hides a home flow of the same name.
public struct FlowFile: Sendable {
    public enum Scope: String, Codable, Sendable { case project, home }

    public var name: String
    public var url: URL
    public var scope: Scope
    /// The flow, or why it could not be read.
    public var result: Result<Flow, Flow.ReadError>

    public var flow: Flow? { try? result.get() }

    public static func folders(project: URL?, env: HarnessEnvironment) -> [(URL, Scope)] {
        var folders: [(URL, Scope)] = []
        if let project { folders.append((project.appending(path: ".pi/flows"), .project)) }
        folders.append((env.piAgentDirectory.appending(path: "flows"), .home))
        return folders
    }

    public static func list(project: URL?, env: HarnessEnvironment) -> [FlowFile] {
        var files: [FlowFile] = [], names = Set<String>()
        for (folder, scope) in folders(project: project, env: env) {
            let entries = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasSuffix(".yaml") || $0.hasSuffix(".yml") }.sorted()
            for entry in entries {
                let url = folder.appending(path: entry)
                let name = url.deletingPathExtension().lastPathComponent
                guard names.insert(name).inserted else { continue }
                let result: Result<Flow, Flow.ReadError>
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    result = .success(try Flow.decode(yaml: text))
                } catch let error as Flow.ReadError {
                    result = .failure(error)
                } catch {
                    result = .failure(Flow.ReadError(message: "can't read: \(error.localizedDescription)"))
                }
                files.append(FlowFile(name: name, url: url, scope: scope, result: result))
            }
        }
        return files
    }

    /// Names of the skills Pi finds for the project: folders with a `SKILL.md` and loose `.md`
    /// files in Pi's skill roots (Pi packages left out).
    public static func knownSkills(project: URL?, env: HarnessEnvironment) -> Set<String> {
        guard let pi = HarnessCatalog.adapter(for: .pi) else { return [] }
        var names = Set<String>()
        let fm = FileManager.default
        for root in pi.skillRoots(in: env, projects: project.map { [$0] } ?? []) {
            guard let enumerator = fm.enumerator(at: root.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                if url.lastPathComponent == "SKILL.md" {
                    names.insert(url.deletingLastPathComponent().lastPathComponent)
                } else if url.pathExtension == "md", url.deletingLastPathComponent().standardizedFileURL == root.url.standardizedFileURL {
                    if case .recursive(rootMarkdown: true) = root.layout { names.insert(url.deletingPathExtension().lastPathComponent) }
                }
            }
        }
        return names
    }

    /// `~/.akit/local/pi-capabilities.json` (written by `akit doctor` later, F20); nil when missing.
    public static func capabilities(env: HarnessEnvironment) -> PiCapabilities? {
        let url = env.homeDirectory.appending(path: ".akit/local/pi-capabilities.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PiCapabilities.self, from: data)
    }
}
