import AKitFoundation
import Foundation

/// The brain's flows (flows.md F3): `brain/flows/<name>.yaml`, written by the Flows screen and
/// committed; a layer lists the ones Apply renders (`flows:` in layer.yaml).
public enum BrainFlows {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func folder(of root: URL) -> URL { root.appending(path: ProjectBundle.flowsFolder) }

    /// Flow names in the brain, sorted.
    public static func names(in root: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder(of: root).path)) ?? []
        return entries.filter { $0.hasSuffix(".yaml") }.map { String($0.dropLast(5)) }.filter(ProjectBundle.isFlowName).sorted()
    }

    public static func url(of name: String, in root: URL) -> URL { folder(of: root).appending(path: "\(name).yaml") }

    /// Writes the flow's text and commits it.
    public static func save(_ name: String, text: String, in brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        guard ProjectBundle.isFlowName(name) else { throw Failure(message: "A flow name may use only letters, digits, _ and -.") }
        if let problem = await BrainGit.commitProblem(brain: brain.root, env: env) { throw Failure(message: problem) }
        let url = url(of: name, in: brain.root)
        let isNew = !FileManager.default.fileExists(atPath: url.path)
        do {
            try FileManager.default.createDirectory(at: folder(of: brain.root), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw Failure(message: "Couldn't write flows/\(name).yaml: \(error.localizedDescription)")
        }
        do {
            try await BrainRemove.commit(["\(ProjectBundle.flowsFolder)/\(name).yaml"], "\(isNew ? "Add" : "Update") flow \(name)", in: brain.root, env: env)
        } catch {
            throw Failure(message: error.message)
        }
    }

    /// The layers that list the flow.
    public static func layers(including name: String, in brain: Brain) -> [String] {
        brain.layers.filter { $0.flows.contains(name) }.map(\.name)
    }

    /// layer.yaml's text with the flow in or out of its `flows:` list; every other line stays.
    public static func manifest(_ text: String, flow: String, included: Bool) -> String {
        var lines = text.components(separatedBy: "\n")
        var names: [String] = []
        var at: Int?
        if let start = lines.firstIndex(where: { $0.hasPrefix("flows:") }) {
            at = start
            let inline = lines[start].dropFirst("flows:".count).trimmingCharacters(in: .whitespaces)
            if inline.hasPrefix("[") {
                names = inline.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                lines.remove(at: start)
            } else {
                var end = start + 1
                while end < lines.count, lines[end].hasPrefix(" ") || lines[end].hasPrefix("-") {
                    let item = lines[end].trimmingCharacters(in: .whitespaces)
                    if item.hasPrefix("-") { names.append(item.dropFirst().trimmingCharacters(in: .whitespaces)) }
                    end += 1
                }
                lines.removeSubrange(start..<end)
            }
        }
        names.removeAll { $0 == flow }
        if included { names.append(flow) }
        let block = names.isEmpty ? [] : ["flows:"] + names.map { "  - \($0)" }
        if let at {
            lines.insert(contentsOf: block, at: at)
        } else if !block.isEmpty {
            if lines.last == "" { lines.removeLast() }
            lines += block + [""]
        }
        return lines.joined(separator: "\n")
    }

    /// Puts the flow in or out of a layer and commits.
    public static func setIncluded(_ included: Bool, flow: String, inLayer name: String, in brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        guard let layer = brain.layers.first(where: { $0.name == name }) else { throw Failure(message: "No layer named \(name).") }
        if let problem = await BrainGit.commitProblem(brain: brain.root, env: env) { throw Failure(message: problem) }
        guard let text = try? String(contentsOf: layer.manifest, encoding: .utf8) else { throw Failure(message: "Can't read layers/\(name)/layer.yaml.") }
        let new = manifest(text, flow: flow, included: included)
        guard new != text else { return }
        do {
            _ = try LayerManifest.parse(new, folder: layer.folder)
            try Data(new.utf8).write(to: layer.manifest, options: .atomic)
            try await BrainRemove.commit(["layers/\(name)/layer.yaml"], "\(included ? "Add" : "Remove") flow \(flow) \(included ? "to" : "from") layer \(name)", in: brain.root, env: env)
        } catch let error as BrainRemove.Failure {
            throw Failure(message: error.message)
        } catch {
            throw Failure(message: "Couldn't write layers/\(name)/layer.yaml: \(error)")
        }
    }
}
