import AKitBrain
import AKitFoundation
import Foundation

/// Merging the layers' keys into a project's JSON file (`.mcp.json`, `.claude/settings.json`).
/// The file stays the project's: AKit adds the leaves the layers bring, updates or removes
/// only leaves it wrote itself that still hold its value, and never touches the others.
enum JSONMerge {
    struct Result {
        /// nil: nothing to show (no file, and the layers bring nothing to write).
        var kind: ProjectSetup.Change.Kind?
        /// Masked texts for the preview: `env` and `headers` values read `••••`.
        var oldText: String?
        var newText: String?
        /// The bytes Apply writes (create or update).
        var write: Data?
        /// What the lock keeps for the file after Apply; nil when nothing of AKit's is left.
        var record: ProjectRecords.Lock.MergedJSON?
        var warnings: [String] = []
        var blocker: String?
    }

    /// `layers`: the layers' merged object (empty when no layer brings the file any more).
    /// `legacy`: the lock entry of an older AKit that wrote the file whole.
    static func plan(path: String, url: URL, layers: JSONValue, layerNames: [String],
                     previous: ProjectRecords.Lock.MergedJSON?, legacy: ProjectRecords.Lock.Entry? = nil) -> Result {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return Result(blocker: "\(path) is a link; AKit merges keys only into a plain file.")
        }
        var current: Data?
        if fm.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { return Result(blocker: "\(path) can't be read.") }
            current = data
        }
        var existing = JSONValue.object([:])
        if let current {
            do {
                existing = try JSONValue.parse(current)
            } catch {
                return Result(blocker: "\(path) is not valid JSON (\(error.message)). AKit won't overwrite it; fix the file first.")
            }
            guard case .object = existing else {
                return Result(blocker: "\(path) is not a JSON object. AKit won't overwrite it; fix the file first.")
            }
        }

        var previous = previous
        if previous == nil, let legacy, let current {
            // An older AKit wrote the whole file. Untouched since: every key and object is AKit's.
            // Edited: only the keys that still hold the layers' value.
            let untouched = legacy.sha256 == Checksum.sha256(current)
            let theirs = existing.leaves.filter { leaf in untouched || layers.value(at: leaf.path) == leaf.value }
            previous = .init(keys: Dictionary(theirs.map { (JSONValue.pointer($0.path), hash($0.value)) }, uniquingKeysWith: { first, _ in first }),
                             created: untouched, layers: layerNames,
                             containers: untouched ? existing.objectPaths.map(JSONValue.pointer) : [])
        }

        // The project deleted the file AKit merged into: its choice, like a deleted skeleton file.
        // Not created again; the layers' keys are only offered (unticked).
        if current == nil, previous != nil {
            guard layers != .object([:]) else { return Result() }
            var result = Result(kind: .own, newText: layers.masked.pretty, write: Data(layers.pretty.utf8),
                                record: .init(keys: Dictionary(layers.leaves.map { (JSONValue.pointer($0.path), hash($0.value)) }, uniquingKeysWith: { first, _ in first }),
                                              created: true, layers: layerNames, containers: layers.objectPaths.map(JSONValue.pointer)))
            result.warnings.append("\(path): the project deleted it, so AKit doesn't create it again. Tick it in the preview (or akit apply --include \(path)) to take the layers' keys.")
            return result
        }

        var merged = existing
        var containers = Set(previous?.containers ?? [])
        var keys: [String: String] = [:]
        var warnings: [String] = []
        let brought = layers.leaves
        let broughtPointers = Set(brought.map { JSONValue.pointer($0.path) })
        // Leaves AKit wrote that the layers no longer bring: removed while the project left them
        // alone. One the project changed is its own now. Objects AKit created for them go when
        // they become empty; objects the project had stay.
        for (pointer, hash) in previous?.keys ?? [:] where !broughtPointers.contains(pointer) {
            let keyPath = JSONValue.path(pointer: pointer)
            guard let value = merged.value(at: keyPath), Self.hash(value) == hash else { continue }
            merged.remove(at: keyPath)
            for length in stride(from: keyPath.count - 1, to: 0, by: -1) {
                let parent = Array(keyPath.prefix(length))
                let parentPointer = JSONValue.pointer(parent)
                guard containers.contains(parentPointer), merged.value(at: parent) == .object([:]) else { continue }
                merged.remove(at: parent)
                containers.remove(parentPointer)
            }
        }
        for leaf in brought {
            let pointer = JSONValue.pointer(leaf.path)
            let present = merged.value(at: leaf.path)
            if present == leaf.value {
                // Already there: AKit's only if AKit wrote this very value earlier (one the
                // project set itself stays the project's, even when the layers now agree).
                if previous?.keys[pointer] == hash(leaf.value) { keys[pointer] = hash(leaf.value) }
            } else if present == nil, previous?.keys[pointer] != nil {
                // AKit wrote it and the project deleted it: the project's choice.
                warnings.append("\(path): the project removed \(JSONValue.display(leaf.path)); AKit leaves it out.")
            } else if present == nil, !blocked(merged, leaf.path) {
                for length in 1..<leaf.path.count where merged.value(at: Array(leaf.path.prefix(length))) == nil {
                    containers.insert(JSONValue.pointer(Array(leaf.path.prefix(length))))
                }
                merged.set(leaf.value, at: leaf.path)
                keys[pointer] = hash(leaf.value)
            } else if let present, let written = previous?.keys[pointer], hash(present) == written {
                // AKit's earlier value, untouched since: the layers' new value replaces it.
                merged.set(leaf.value, at: leaf.path)
                keys[pointer] = hash(leaf.value)
            } else {
                warnings.append("\(path): the project sets \(JSONValue.display(leaf.path)) itself; AKit leaves it.")
            }
        }
        containers = containers.filter { pointer in
            if case .object? = merged.value(at: JSONValue.path(pointer: pointer)) { return true }
            return false
        }

        let created = current == nil || previous?.created == true
        let record = keys.isEmpty ? nil : ProjectRecords.Lock.MergedJSON(keys: keys, created: created, layers: layerNames,
                                                                        containers: containers.sorted())
        let oldText = current.map { _ in existing.masked.pretty }
        var result = Result(oldText: oldText, record: record, warnings: warnings)
        if current == nil {
            guard merged != .object([:]) else { return result }
            result.kind = .create
        } else if merged == .object([:]) && keys.isEmpty && previous?.created == true {
            // Nothing of AKit's left in a file AKit created: it goes, like other files AKit wrote.
            result.kind = .remove
            return result
        } else if merged == existing {
            result.kind = .same
        } else {
            result.kind = .update
            if let current, existing.pretty != String(decoding: current, as: UTF8.self) {
                result.warnings.append("\(path) is rewritten with sorted keys and a 2-space indent; the preview shows only the keys that change.")
            }
        }
        result.newText = merged.masked.pretty
        if result.kind != .same { result.write = Data(merged.pretty.utf8) }
        return result
    }

    /// A non-object value sits on the way to the key path, so setting it would replace it.
    private static func blocked(_ tree: JSONValue, _ path: [String]) -> Bool {
        for length in 1..<max(path.count, 1) {
            guard let value = tree.value(at: Array(path.prefix(length))) else { return false }
            if case .object = value { continue }
            return true
        }
        return false
    }

    static func hash(_ value: JSONValue) -> String { Checksum.sha256(Data(value.compact.utf8)) }
}
