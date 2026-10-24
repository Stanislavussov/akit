import AKitFoundation
import AKitReview
import SwiftUI

/// Base or Head of a local review: a ref typed by hand, or found with Find… by a word of a
/// branch, a tag, a commit message or a commit id.
struct ReviewPointField: View {
    let title: String
    @Binding var text: String
    let prompt: String
    /// The workspace to search; nil while there is none.
    let workspace: URL?
    let env: HarnessEnvironment
    @State private var finding = false

    var body: some View {
        HStack {
            TextField(title, text: $text, prompt: Text(prompt))
            Button("Find…") { finding = true }
                .disabled(workspace == nil)
                .help("Find a branch, tag or commit by its name, message, author or id")
                // `--tab find-base` / `find-head` (snapshots): opens Find… once the workspace is there.
                .task(id: workspace) {
                    if workspace != nil, DebugSnapshot.options?.tab == "find-" + title.lowercased() { finding = true }
                }
                .sheet(isPresented: $finding) {
                    if let workspace {
                        ReviewPointSearch(title: title, workspace: workspace, env: env) { point in
                            if let point { text = point.name }
                            finding = false
                        }
                    }
                }
        }
    }
}

/// The search of Find…: every word must be in the name, the message, the author or start the id.
struct ReviewPointSearch: View {
    let title: String
    let workspace: URL
    let env: HarnessEnvironment
    /// The chosen point; nil = Cancel.
    let pick: (ReviewLocalPoint?) -> Void
    @State private var query = ""
    @State private var filter: ReviewLocalPoint.Filter = DebugSnapshot.options?.select.flatMap(ReviewLocalPoint.Filter.init(rawValue:)) ?? .all
    @State private var points: [ReviewLocalPoint] = []
    @State private var problem: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Find the \(title.lowercased())").font(.headline)
            TextField("Search", text: $query, prompt: Text("a word of a branch, tag, commit message or id"))
                .textFieldStyle(.roundedBorder)
            Picker("Show", selection: $filter) {
                ForEach(ReviewLocalPoint.Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if loaded && points.isEmpty {
                Text("No branch, tag or commit matches.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(points) { point in
                    Button { pick(point) } label: { row(point) }
                        .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
            HStack {
                Text(filter == .all ? "Branches and tags first, the most recent first; then the commits of all branches. Click one to use it."
                     : "The most recent first. Click one to use it.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { pick(nil) }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 560, height: 420)
        .task(id: "\(filter.rawValue)|\(query)") { await search() }
    }

    private func row(_ point: ReviewLocalPoint) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon(point.kind)).foregroundStyle(.secondary).frame(width: 16)
                .help(point.kind.rawValue)
            VStack(alignment: .leading, spacing: 2) {
                // A commit by its message (its id goes into the field); a ref by its name.
                if point.kind == .commit {
                    Text(point.subject).lineLimit(1)
                    Text("\(point.name) · \(point.date) · \(point.author)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(point.name).font(.body.monospaced()).lineLimit(1)
                    Text("\(point.sha.prefix(10)) · \(point.date) · \(point.author): \(point.subject)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func icon(_ kind: ReviewLocalPoint.Kind) -> String {
        switch kind {
        case .branch: "arrow.triangle.branch"
        case .remote: "cloud"
        case .tag: "tag"
        case .commit: "smallcircle.filled.circle"
        }
    }

    /// Searches again after a short pause while typing.
    private func search() async {
        if loaded { try? await Task.sleep(for: .milliseconds(250)) }
        guard !Task.isCancelled else { return }
        do {
            let found = try await ReviewLocal.points(path: workspace, query: query, filter: filter, env: env)
            guard !Task.isCancelled else { return }
            points = found
            problem = nil
        } catch {
            guard !Task.isCancelled else { return }
            points = []
            problem = error.localizedDescription
        }
        loaded = true
    }
}
