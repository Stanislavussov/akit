import AKitBrain
import AKitFoundation
import AKitKnowledge
import AppKit
import SwiftUI

/// Settings → Knowledge (K25): where each world's base lives on this Mac, kept in
/// `~/.akit/local/knowledge/bases.json`; the same as `akit kb path`. One row per world (the set
/// ones, the ones with a base, and this Mac's kind) with Choose…, Move Base…, Show in Finder and
/// Reset to Default. A refusal shows under its row.
struct KnowledgeSettingsSection: View {
    /// The brain folder chosen in Settings: a base is never inside it.
    let brainPath: String

    @State private var rows: [Row] = []
    @State private var problems: [String: String] = [:]
    @State private var notices: [String: String] = [:]
    @State private var working: String?

    struct Row: Equatable {
        let world: String
        let path: URL
        let configured: Bool
        let isBase: Bool
        let vault: URL?
    }

    private var env: HarnessEnvironment { .current }
    private var brain: URL { env.expand(brainPath) }

    static func rows(home: URL) -> [Row] {
        KnowledgeBase.worlds(home: home).map { world in
            let path = KnowledgeBase.root(world: world, home: home)
            return Row(world: world, path: path, configured: KnowledgeBase.isConfigured(world: world, home: home),
                       isBase: KnowledgeBase.isBase(path), vault: Obsidian.vault(containing: path))
        }
    }

    /// What a `--settings --tab knowledge` snapshot prints: the rows as text.
    static func manifest(home: URL = HarnessEnvironment.current.homeDirectory) -> String {
        rows(home: home).map { row in
            "knowledge folder: \(row.world) \(row.path.tildePath) (\(row.configured ? "set" : "default"), \(row.isBase ? "base" : "no base yet")"
                + (row.vault.map { ", Obsidian vault \($0.tildePath)" } ?? "") + ")"
        }.joined(separator: "\n")
    }

    var body: some View {
        Section {
            ForEach(rows, id: \.world) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "books.vertical")
                        Text(row.world).bold()
                        Text(row.path.tildePath).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if working == row.world { ProgressView().controlSize(.small) }
                    }
                    Text(status(row)).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Choose…") { choose(row) }
                            .help("Use another folder for this base, like one in your Obsidian vault. A new or empty folder or a vault becomes a base; the old base stays where it is.")
                        Button("Move Base…") { move(row) }
                            .disabled(!row.isBase)
                            .help("Commit the pending edits, then move the base with its git history to a new folder")
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.path]) }
                            .disabled(!FileManager.default.fileExists(atPath: row.path.path))
                        Spacer()
                        Button("Reset to Default") { reset(row) }
                            .disabled(!row.configured)
                            .help("Use ~/.akit/local/knowledge/\(row.world) again. Nothing is moved or deleted.")
                    }
                    .disabled(working != nil)
                    if let problem = problems[row.world] {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                    } else if let notice = notices[row.world] {
                        Label(notice, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Knowledge").id("knowledge")
        } footer: {
            Text("Where each world's knowledge base lives, on this Mac only (~/.akit/local/knowledge/bases.json; akit kb path does the same). Any local folder works, like one in your Obsidian vault, except inside the brain, a synced folder (iCloud Drive, Dropbox, Google Drive) or a git repo with a remote.")
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
    }

    private func status(_ row: Row) -> String {
        var parts = [row.configured ? "Set on this Mac" : "The default folder"]
        parts.append(row.isBase ? "a base" : "no base yet (Create Base… on the Knowledge screen makes one here)")
        if let vault = row.vault { parts.append("in the Obsidian vault \(vault.lastPathComponent)") }
        return parts.joined(separator: ", ")
    }

    private func refresh() { rows = Self.rows(home: env.homeDirectory) }

    private func choose(_ row: Row) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use for Base"
        panel.message = "A new or empty folder, an Obsidian vault (or a folder in one), or a knowledge base"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(row) {
            let change = try await KnowledgeBase.setFolder(world: row.world, to: url, env: env, brainRoot: brain)
            return (change.created ? "A new base is in \(change.base.root.tildePath)." : "The base is \(change.base.root.tildePath) now.")
                + (change.previous.map { " The old one stays in \($0.tildePath)." } ?? "")
        }
    }

    private func move(_ row: Row) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = row.path.lastPathComponent
        panel.prompt = "Move Here"
        panel.message = "The new folder of the \(row.world) base. Pending edits are committed first."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(row) {
            // The Knowledge screen's own pending saves first, then the move flushes the queue file.
            if let current = KnowledgeModel.current { await current.flush(current.base) }
            let base = try await KnowledgeBase.move(world: row.world, to: url, env: env, brainRoot: brain)
            return "Moved to \(base.root.tildePath)."
        }
    }

    private func reset(_ row: Row) {
        run(row) {
            let folder = try KnowledgeBase.resetFolder(world: row.world, home: env.homeDirectory)
            return "The default folder again. \(row.path.tildePath) stays as it is." + (KnowledgeBase.isBase(folder) ? "" : " No base here yet.")
        }
    }

    private func run(_ row: Row, _ work: @escaping @MainActor () async throws -> String) {
        working = row.world
        problems[row.world] = nil
        notices[row.world] = nil
        Task {
            do {
                notices[row.world] = try await work()
            } catch {
                problems[row.world] = error.localizedDescription
            }
            working = nil
            refresh()
            await KnowledgeModel.current?.load()
        }
    }
}
