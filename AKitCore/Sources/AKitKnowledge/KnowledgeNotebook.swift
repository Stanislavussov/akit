import AKitFoundation
import Foundation

/// The notebook of a base (docs/design/notebook.md): short notes, plans and "what I did today",
/// one Markdown file per tab in `notebook/` beside `areas/` (NB1, NB2), images in
/// `notebook/assets/` (NB5). The tab order is AKit's own file, `notebook/.tabs.json`. Search, lint
/// and the agent card leave the notebook out (NB9).
///
/// Tab changes (New Tab…, Rename…, Delete…, a new order) are committed at once; edits are saved at
/// once and wait in the commit queue like note edits (U2). `akit notebook add` and `done` commit at
/// once too, so an open tab in AKit sees an outside change (Reload / Keep Mine).
public struct KnowledgeNotebook: Sendable {
    public typealias Failure = KnowledgeBase.Failure

    public static let folderName = "notebook"
    public static let assetsName = "assets"
    public static let orderName = ".tabs.json"
    /// The tab a notebook without tabs shows; its file is written by the first save, not on open.
    public static let firstTab = "Inbox"
    /// The largest image a paste or drop may add.
    public static let maxAssetBytes = 20 * 1024 * 1024
    public static let assetExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "pdf"]

    public let base: KnowledgeBase

    public init(base: KnowledgeBase) { self.base = base }

    public var folder: URL { base.root.appending(path: Self.folderName, directoryHint: .isDirectory) }
    public var assetsFolder: URL { folder.appending(path: Self.assetsName, directoryHint: .isDirectory) }
    var orderFile: URL { folder.appending(path: Self.orderName) }
    public var orderPath: String { "\(Self.folderName)/\(Self.orderName)" }

    /// A tab's file: `notebook/<tab>.md`.
    public func file(_ tab: String) -> URL { folder.appending(path: tab + ".md") }
    /// A tab's base-relative path.
    public func path(_ tab: String) -> String { "\(Self.folderName)/\(tab).md" }

    // MARK: - Tabs

    /// The tabs: the `.md` files in `notebook/` (not in subfolders, hidden ones left out), in the
    /// saved order, then the others by name. Empty when there are none: the screen then shows
    /// `firstTab`, whose file the first save writes.
    public func tabs() -> [String] {
        let names = FileWalk.children(of: folder)
            .filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasPrefix(".") && FileWalk.isRegularFile($0) }
            .map { KnowledgeBase.nfc($0.deletingPathExtension().lastPathComponent) }
        let present = Set(names)
        let saved = savedOrder().filter { present.contains($0) }
        let rest = names.filter { !saved.contains($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return saved + rest
    }

    private struct Order: Codable { var tabs: [String] }

    func savedOrder() -> [String] {
        guard let data = try? Data(contentsOf: orderFile), let order = try? JSONDecoder().decode(Order.self, from: data) else { return [] }
        var seen: Set<String> = []
        return order.tabs.map(KnowledgeBase.nfc).filter { seen.insert($0).inserted }
    }

    func writeOrder(_ tabs: [String]) throws(Failure) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try (encoder.encode(Order(tabs: tabs)) + Data("\n".utf8)).write(to: orderFile, options: .atomic)
        } catch {
            throw Failure(message: "Couldn't write \(orderPath): \(error.localizedDescription)")
        }
    }

    /// A tab name, trimmed; throws why it can't name a file. One tab is one file name, so no `/`,
    /// no leading `.`, nothing a file system or Obsidian refuses.
    public static func checkedName(_ name: String) throws(Failure) -> String {
        let name = KnowledgeBase.nfc(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !name.isEmpty else { throw Failure(message: "Give the tab a name.") }
        guard name.count <= 80 else { throw Failure(message: "A tab name has at most 80 characters.") }
        guard !name.hasPrefix("."), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !name.contains(where: { "/\\:*?\"<>|#^[]".contains($0) })
        else { throw Failure(message: "“\(name)” can't name a tab: leave out / \\ : * ? \" < > | # ^ [ ] and a leading dot.") }
        return name
    }

    /// The tab of this name, matched without regard to case (a Mac's disk ignores it).
    func existing(_ name: String) -> String? {
        let tabs = tabs()
        return tabs.first { $0 == name } ?? tabs.first { $0.lowercased() == name.lowercased() }
    }

    /// The tab `name` names, or why there is none.
    public func tab(_ name: String) throws(Failure) -> String {
        if let tab = existing(KnowledgeBase.nfc(name.trimmingCharacters(in: .whitespaces))) { return tab }
        let tabs = tabs()
        throw Failure(message: "No notebook tab “\(name)” in \(base.name). Tabs: \(tabs.isEmpty ? "none yet" : tabs.joined(separator: ", ")).")
    }

    /// New Tab…: an empty tab after the others, committed at once.
    @discardableResult
    public func add(tab name: String, env: HarnessEnvironment) async throws(Failure) -> String {
        let name = try Self.checkedName(name)
        if existing(name) != nil { throw Failure(message: "The notebook has a tab “\(name)” already.") }
        let order = tabs() + [name]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: file(name), options: .withoutOverwriting)
        } catch {
            throw Failure(message: "Couldn't write \(path(name)): \(error.localizedDescription)")
        }
        try writeOrder(order)
        try await commit([path(name), orderPath], "Add notebook tab \(name)", env)
        return name
    }

    /// Rename…: the tab's file gets the new name, in the same place of the order; one commit.
    /// Links to it from notes stay as they are (a notebook tab is no note).
    @discardableResult
    public func rename(tab: String, to new: String, env: HarnessEnvironment) async throws(Failure) -> String {
        let tab = try self.tab(tab)
        let new = try Self.checkedName(new)
        guard new != tab else { return tab }
        // A case-only rename is the same file on a Mac's disk.
        if let other = existing(new), other != tab { throw Failure(message: "The notebook has a tab “\(other)” already.") }
        let order = tabs().map { $0 == tab ? new : $0 }
        do { try FileManager.default.moveItem(at: file(tab), to: file(new)) } catch {
            throw Failure(message: "Couldn't rename \(path(tab)): \(error.localizedDescription)")
        }
        try writeOrder(order)
        try await commit([path(tab), path(new), orderPath], "Rename notebook tab \(tab) to \(new)", env)
        return new
    }

    /// Delete…: the tab's file goes to the Trash (its images stay in `assets/`); one commit.
    public func delete(tab: String, env: HarnessEnvironment, trash: (URL) throws -> URL? = Trash.move) async throws(Failure) {
        let tab = try self.tab(tab)
        let order = tabs().filter { $0 != tab }
        do { _ = try trash(file(tab)) } catch {
            throw Failure(message: "Couldn't move \(path(tab)) to the Trash: \(error.localizedDescription)")
        }
        try writeOrder(order)
        try await commit([path(tab), orderPath], "Delete notebook tab \(tab)", env)
    }

    /// A tab dragged to a new place: the whole order, committed at once. Names that are no tab are
    /// left out; tabs it misses keep their place after the others.
    public func reorder(_ names: [String], env: HarnessEnvironment) async throws(Failure) {
        let tabs = tabs()
        let wanted = names.map(KnowledgeBase.nfc).filter { tabs.contains($0) }
        let order = wanted + tabs.filter { !wanted.contains($0) }
        guard order != tabs || savedOrder() != order else { return }
        try writeOrder(order)
        try await commit([orderPath], "Reorder notebook tabs", env)
    }

    private func commit(_ paths: [String], _ message: String, _ env: HarnessEnvironment) async throws(Failure) {
        do { try await KnowledgeGit(base: base.root, env: env).commit(paths: paths, message: message) } catch {
            throw Failure(message: "Saved, but not committed: \(error.message)")
        }
    }

    // MARK: - Text

    /// A tab's text; "" for the first tab before its first save.
    public func text(_ tab: String) throws(Failure) -> String {
        let file = file(tab)
        guard FileWalk.isRegularFile(file) else {
            if tab == Self.firstTab, tabs().isEmpty { return "" }
            throw Failure(message: "No notebook tab “\(tab)” in \(base.name).")
        }
        do { return String(decoding: try Data(contentsOf: file), as: UTF8.self) } catch {
            throw Failure(message: "Couldn't read \(path(tab)): \(error.localizedDescription)")
        }
    }

    /// An edit from the editor, written as it is (NB4) when the file on disk is still the one AKit
    /// read or last wrote (`expectedHash`; nil: the file must not exist yet, the first tab's first
    /// save). Returns the base-relative path for the commit queue and the outcome.
    public func save(_ tab: String, bytes: Data, expectedHash: String?) throws(Failure) -> (path: String, outcome: KnowledgeWrite.Outcome) {
        let path = path(tab)
        let file = file(tab)
        // A file made outside (Obsidian) may have a name New Tab… refuses; it is still one file in notebook/.
        let existing = !tab.isEmpty && !tab.contains("/") && !tab.hasPrefix(".") && FileWalk.isRegularFile(file)
        guard existing || (try? Self.checkedName(tab)) == tab, KnowledgeGit.isInside(path) else {
            throw Failure(message: "“\(tab)” is no notebook tab.")
        }
        do {
            guard let expectedHash else {
                if let disk = KnowledgeWrite.hash(of: file) { return (path, .conflict(diskHash: disk)) }
                // Only the first tab of an empty notebook is made by a save; a deleted or renamed tab stays gone.
                guard tab == Self.firstTab, tabs().isEmpty else { return (path, .conflict(diskHash: nil)) }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try bytes.write(to: file, options: .withoutOverwriting)
                return (path, .saved(hash: KnowledgeWrite.hash(bytes)))
            }
            guard FileWalk.isRegularFile(file) else { return (path, .conflict(diskHash: nil)) }
            return (path, try KnowledgeWrite.saveChecked(bytes, to: file, expectedHash: expectedHash))
        } catch {
            throw Failure(message: "Couldn't save \(path): \(error.localizedDescription)")
        }
    }

    /// A pasted or dropped image (NB5): `notebook/assets/<date>-<short hash>.<ext>`, the same bytes
    /// twice being one file. Returns the link the Markdown gets (`assets/…`, relative to the tab)
    /// and the base-relative path for the commit queue.
    public func saveAsset(_ data: Data, ext: String, date: String) throws(Failure) -> (link: String, path: String) {
        let ext = ext.lowercased() == "jpeg" ? "jpg" : ext.lowercased()
        guard Self.assetExtensions.contains(ext) else { throw Failure(message: "AKit keeps images only (png, jpg, gif, webp, heic, svg, pdf), not .\(ext).") }
        guard !data.isEmpty, data.count <= Self.maxAssetBytes else {
            throw Failure(message: "An image may have at most \(Self.maxAssetBytes / 1024 / 1024) MB.")
        }
        let name = "\(date)-\(KnowledgeWrite.hash(data).prefix(8)).\(ext)"
        let file = assetsFolder.appending(path: name)
        do {
            if !FileWalk.isRegularFile(file) {
                try FileManager.default.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            }
        } catch {
            throw Failure(message: "Couldn't save the image: \(error.localizedDescription)")
        }
        return ("\(Self.assetsName)/\(name)", "\(Self.folderName)/\(Self.assetsName)/\(name)")
    }

    /// The file a tab's relative image link (`assets/…`) names, or nil when it leaves `notebook/`.
    /// Only images and PDFs, and never through a symbolic link that leads out of the notebook.
    public func asset(_ link: String) -> URL? {
        let parts = link.split(separator: "/", omittingEmptySubsequences: false)
        guard !link.hasPrefix("/"), !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let file = parts.reduce(folder) { $0.appending(path: String($1)) }.standardizedFileURL
        let ext = file.pathExtension.lowercased()
        guard file.path.hasPrefix(folder.standardizedFileURL.path + "/"), FileWalk.isRegularFile(file),
              Self.assetExtensions.contains(ext == "jpeg" ? "jpg" : ext),
              file.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
        else { return nil }
        return file
    }

    // MARK: - Drawings (NB10)

    public static let drawingsName = "drawings"
    /// A drawing's picture, the image its tab shows: `drawings/<name>.excalidraw.svg`.
    public static let pictureSuffix = ".excalidraw.svg"

    /// The drawing an image link of a tab shows (`drawings/<name>.excalidraw.svg` → `<name>`), or nil.
    public static func drawing(ofLink link: String) -> String? {
        let link = (link.removingPercentEncoding ?? link).split(separator: "?").first.map(String.init) ?? link
        guard link.hasPrefix(drawingsName + "/"), link.hasSuffix(pictureSuffix) else { return nil }
        let name = String(link.dropFirst(drawingsName.count + 1).dropLast(pictureSuffix.count))
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), name != ".." else { return nil }
        return name
    }

    public var drawingsFolder: URL { folder.appending(path: Self.drawingsName, directoryHint: .isDirectory) }
    /// The Excalidraw scene: `notebook/drawings/<name>.excalidraw`.
    public func drawingFile(_ name: String) -> URL { drawingsFolder.appending(path: name + ".excalidraw") }
    public func pictureFile(_ name: String) -> URL { drawingsFolder.appending(path: name + Self.pictureSuffix) }
    public static func pictureLink(_ name: String) -> String { "\(drawingsName)/\(name)\(pictureSuffix)" }
    func drawingPath(_ name: String) -> String { "\(Self.folderName)/\(Self.drawingsName)/\(name).excalidraw" }
    func picturePath(_ name: String) -> String { "\(Self.folderName)/\(Self.pictureLink(name))" }

    /// A name for a new drawing: `<date>-<6 hex>`, not taken yet.
    public func newDrawingName(date: String) -> String {
        while true {
            let name = "\(date)-\(String(format: "%06x", Int.random(in: 0..<0x1000000)))"
            if !FileManager.default.fileExists(atPath: drawingFile(name).path) { return name }
        }
    }

    /// A drawing's scene as on disk ("" for a new one) and its hash (nil: new).
    public func drawing(_ name: String) -> (text: String, hash: String?) {
        guard let data = try? Data(contentsOf: drawingFile(name)) else { return ("", nil) }
        return (String(decoding: data, as: UTF8.self), KnowledgeWrite.hash(data))
    }

    /// Done in the drawing editor: the scene (Excalidraw's own bytes) and its picture, the scene
    /// written only when it is still the one AKit read (`expectedHash`; nil: a new drawing). Returns
    /// the picture's link for the tab, the base-relative paths for the commit queue, and the outcome.
    public func saveDrawing(_ name: String, scene: Data, svg: Data, expectedHash: String?) throws(Failure)
        -> (link: String, paths: [String], outcome: KnowledgeWrite.Outcome) {
        guard Self.drawing(ofLink: Self.pictureLink(name)) == name else { throw Failure(message: "“\(name)” can't name a drawing.") }
        guard svg.starts(with: Data("<svg".utf8)) else { throw Failure(message: "The drawing's picture is not SVG; nothing was saved.") }
        guard (try? JSONSerialization.jsonObject(with: scene)) is [String: Any] else {
            throw Failure(message: "The drawing's scene is not Excalidraw's JSON; nothing was saved.")
        }
        let file = drawingFile(name)
        let outcome: KnowledgeWrite.Outcome
        do {
            try FileManager.default.createDirectory(at: drawingsFolder, withIntermediateDirectories: true)
            if let expectedHash {
                outcome = try KnowledgeWrite.saveChecked(scene, to: file, expectedHash: expectedHash)
            } else if let disk = KnowledgeWrite.hash(of: file) {
                outcome = .conflict(diskHash: disk)
            } else {
                try scene.write(to: file, options: .withoutOverwriting)
                outcome = .saved(hash: KnowledgeWrite.hash(scene))
            }
            if case .saved = outcome { try svg.write(to: pictureFile(name), options: .atomic) }
        } catch {
            throw Failure(message: "Couldn't save the drawing \(name): \(error.localizedDescription)")
        }
        return (Self.pictureLink(name), [drawingPath(name), picturePath(name)], outcome)
    }

    // MARK: - Agents (NB8)

    /// `akit notebook add`: a line (`- [ ] TEXT` with `task`) at the top of the tab, or under
    /// today's heading (`today`, made when missing). The first tab is made when the notebook has
    /// none; any other missing tab is refused. One commit.
    @discardableResult
    public func append(_ line: String, to name: String, task: Bool, today: String?, env: HarnessEnvironment) async throws(Failure) -> String {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.contains("\n") else { throw Failure(message: "Give one line of text.") }
        let tab: String
        if tabs().isEmpty, KnowledgeBase.nfc(name.trimmingCharacters(in: .whitespaces)).lowercased() == Self.firstTab.lowercased() {
            tab = Self.firstTab
        } else {
            tab = try self.tab(name)
        }
        let old = try text(tab)
        let new = Self.adding(task ? "- [ ] \(line)" : line, to: old, under: today)
        try write(tab, old: old, new: new)
        try await commit([path(tab)], "Notebook: add to \(tab)", env)
        return tab
    }

    /// `akit notebook done`: ticks the first open task (`- [ ]`) whose text contains `match`, case
    /// ignored. Returns the ticked line; one commit.
    @discardableResult
    public func tick(_ match: String, in name: String, env: HarnessEnvironment) async throws(Failure) -> String {
        let tab = try self.tab(name)
        let old = try text(tab)
        guard let (new, line) = Self.ticking(match, in: old) else {
            throw Failure(message: "No open task in \(tab) has “\(match)”.")
        }
        try write(tab, old: old, new: new)
        try await commit([path(tab)], "Notebook: done in \(tab)", env)
        return line
    }

    private func write(_ tab: String, old: String, new: String) throws(Failure) {
        let expected = FileWalk.isRegularFile(file(tab)) ? KnowledgeWrite.hash(Data(old.utf8)) : nil
        if case .conflict = try save(tab, bytes: Data(new.utf8), expectedHash: expected).outcome {
            throw Failure(message: "\(path(tab)) changed while AKit wrote it; nothing was written. Try again.")
        }
    }

    // MARK: - Text edits (pure)

    /// The heading of a day: `## 2026-10-25`.
    public static func dayHeading(_ date: String) -> String { "## \(date)" }

    /// Where new text goes at the top: after frontmatter and a first `# Title` line.
    static func topIndex(_ lines: [Substring]) -> Int {
        var index = 0
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { index = end + 1 }
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
        if index < lines.count, lines[index].hasPrefix("# ") { index += 1 }
        return index
    }

    /// Today (NB7): the text with `## <date>` at the top (after frontmatter and a `# Title`), and the
    /// heading's line number (0-based). An existing heading of that day stays where it is.
    public static func addingToday(_ text: String, date: String) -> (text: String, line: Int) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let heading = dayHeading(date)
        if let line = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading }) { return (text, line) }
        if text.isEmpty { return (heading + "\n", 0) }
        let at = topIndex(lines)
        func blank(_ index: Int) -> Bool { lines[index].trimmingCharacters(in: .whitespaces).isEmpty }
        // One blank line around the heading: the ones there are kept, the missing ones added.
        let before = at > 0 && !blank(at - 1), after = at < lines.count && !blank(at)
        lines.insert(contentsOf: (before ? [""] : []) + [Substring(heading)] + (after ? [""] : []), at: at)
        return (lines.joined(separator: "\n"), at + (before ? 1 : 0))
    }

    /// `line` at the top, or as the first line under today's heading (`under`: the date). A list
    /// item joins the list that follows; other text gets a blank line after it.
    public static func adding(_ line: String, to text: String, under date: String?) -> String {
        var source = text
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var at: Int
        if let date {
            let today = addingToday(source, date: date)
            source = today.text
            lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            at = today.line + 1
        } else {
            at = topIndex(lines)
        }
        if source.isEmpty { return line + "\n" }
        // Under a heading: after its blank line.
        if at > 0, lines[at - 1].hasPrefix("#") {
            if at < lines.count, lines[at].trimmingCharacters(in: .whitespaces).isEmpty { at += 1 } else { lines.insert("", at: at); at += 1 }
        } else if at > 0, !lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.insert("", at: at)
            at += 1
        }
        let isItem = isListItem(line)
        let next = at < lines.count ? lines[at] : nil
        var insert: [Substring] = [Substring(line)]
        if let next, !next.trimmingCharacters(in: .whitespaces).isEmpty, !(isItem && isListItem(next)) { insert.append("") }
        lines.insert(contentsOf: insert, at: at)
        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    static func isListItem<S: StringProtocol>(_ line: S) -> Bool {
        let trimmed = line.drop { $0 == " " }
        return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
    }

    /// The first open task (`- [ ] …`, any bullet, any indent) containing `match` (case ignored),
    /// ticked: the new text and the ticked line. nil when none matches.
    public static func ticking(_ match: String, in text: String) -> (text: String, line: String)? {
        let match = match.trimmingCharacters(in: .whitespaces).lowercased()
        guard !match.isEmpty else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let rest = line.dropFirst(indent.count)
            guard rest.count > 6, "-*+".contains(rest.first!), rest.dropFirst().hasPrefix(" [ ] "),
                  rest.dropFirst(6).lowercased().contains(match) else { continue }
            let ticked = indent + String(rest.first!) + " [x] " + rest.dropFirst(6)
            lines[index] = ticked
            return (lines.joined(separator: "\n"), ticked.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// The open tasks of a text (`- [ ] …`), for `akit notebook show --open`.
    public static func openTasks(in text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 6 && "-*+".contains($0.first!) && $0.dropFirst().hasPrefix(" [ ] ") }
            .map { String($0.dropFirst(6)) }
    }
}
