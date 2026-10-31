import AKitFoundation
import Foundation

/// The order of the spaces (K31): `<base>/.spaces.json`, a list of space names, committed in the
/// base so it follows the base to another Mac. Listed spaces come first, in the file's order; the
/// others after them by name. Names that are no space are ignored, and dropped at the next
/// write. A hidden file: the watcher, lint, the index and Obsidian pass it by.
extension KnowledgeBase {
    public static let spaceOrderName = ".spaces.json"

    var spaceOrderFile: URL { root.appending(path: Self.spaceOrderName) }

    private struct SpaceOrder: Codable { var spaces: [String] }

    /// The names in `.spaces.json`, NFC, each once; empty without the file or when it can't be read.
    func savedSpaceOrder() -> [String] {
        guard let data = try? Data(contentsOf: spaceOrderFile), let order = try? JSONDecoder().decode(SpaceOrder.self, from: data) else { return [] }
        var seen = Set<String>()
        return order.spaces.map(Self.nfc).filter { seen.insert($0).inserted }
    }

    /// `names` in the saved order: the listed ones first, the rest by name.
    static func ordered(_ names: [String], saved: [String]) -> [String] {
        let present = Set(names)
        let listed = saved.filter(present.contains)
        return listed + names.filter { !listed.contains($0) }.sorted()
    }

    func writeSpaceOrder(_ names: [String]) throws(Failure) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try (encoder.encode(SpaceOrder(spaces: names)) + Data("\n".utf8)).write(to: spaceOrderFile, options: .atomic)
        } catch {
            throw Failure(message: "Couldn't write \(Self.spaceOrderName): \(error.localizedDescription)")
        }
    }

    /// A new order: written and committed at once, under the base's git lock (the file is written
    /// inside it, so two writers never mix). Names that are no space are left out; spaces it misses
    /// keep their place after the others.
    public func reorder(spaces names: [String], env: HarnessEnvironment) async throws(Failure) {
        let spaces = areas().map(\.name)
        var seen = Set<String>()
        let wanted = names.map(Self.nfc).filter { spaces.contains($0) && seen.insert($0).inserted }
        let order = wanted + spaces.filter { !wanted.contains($0) }
        guard order != savedSpaceOrder() else { return }
        let lockFile = root.appending(path: Self.queueLockName)
        let lock: FileLock?
        do { lock = try FileLock.acquire(lockFile, timeout: 2) } catch {
            throw Failure(message: "Can't open the lock \(lockFile.path): \(error.localizedDescription)")
        }
        guard let lock else {
            throw Failure(message: "Another AKit is writing to the knowledge base (\(lockFile.lastPathComponent) is held); try again in a moment.")
        }
        defer { lock.release() }
        try writeSpaceOrder(order)
        do { try await KnowledgeGit(base: root, env: env).commit(paths: [Self.spaceOrderName], message: "Reorder spaces", alreadyLocked: lock) } catch {
            throw Failure(message: "\(Self.spaceOrderName) was written, but not committed: \(error.message)")
        }
    }

    /// A space dropped onto another (drag in the list): dragged down, it goes after that space;
    /// dragged up, before it. So the last place can be reached too.
    public func move(space name: String, onto target: String, env: HarnessEnvironment) async throws(Failure) {
        var spaces = areas().map(\.name)
        let (name, target) = (Self.nfc(name), Self.nfc(target))
        guard name != target, let from = spaces.firstIndex(of: name), let to = spaces.firstIndex(of: target) else { return }
        spaces.remove(at: from)
        let index = spaces.firstIndex(of: target)! + (from < to ? 1 : 0)
        spaces.insert(name, at: index)
        try await reorder(spaces: spaces, env: env)
    }

    /// Move Up (`by: -1`) / Move Down (`by: 1`): one place in the order, committed at once. Nothing
    /// happens at the top or bottom.
    public func move(space name: String, by offset: Int, env: HarnessEnvironment) async throws(Failure) {
        var spaces = areas().map(\.name)
        guard let index = spaces.firstIndex(of: Self.nfc(name)) else {
            throw Failure(message: "No space “\(name)” in \(root.path).")
        }
        let target = index + offset
        guard spaces.indices.contains(target) else { return }
        spaces.swapAt(index, target)
        try await reorder(spaces: spaces, env: env)
    }
}
