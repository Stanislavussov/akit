import AKitKnowledge
import SwiftUI

/// The Lint tab of the Knowledge screen (4.1): every finding of `akit kb lint`, errors first.
/// Open shows the note or map; Create Note… writes the note a broken link points to.
struct LintPanel: View {
    @Environment(KnowledgeModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                let counts = KnowledgeLint.counts(model.lintFindings)
                Text("\(counts.error) error\(counts.error == 1 ? "" : "s"), \(counts.warning) warning\(counts.warning == 1 ? "" : "s"), \(counts.hint) hint\(counts.hint == 1 ? "" : "s")")
                    .font(.headline)
                Spacer()
                Button("Check Again", systemImage: "arrow.clockwise") { model.lint(rescan: true) }
                    .help("Read the notes and maps again, and look for the projects in your projects folder again")
            }
            .controlSize(.small)
            .padding(8)
            Divider()
            if model.lintFindings.isEmpty {
                ContentUnavailableView("No findings", systemImage: "checkmark.seal",
                                       description: Text("Every link points to one note or map, every block has its note, and every repo, file and ~/ path is on this Mac."))
            } else {
                List {
                    ForEach(KnowledgeLint.Severity.allCases, id: \.self) { severity in
                        let findings = model.lintFindings.filter { $0.severity == severity }
                        if !findings.isEmpty {
                            Section(Self.title(severity)) {
                                ForEach(findings, id: \.self) { LintRow(finding: $0) }
                            }
                        }
                    }
                }
            }
        }
    }

    static func title(_ severity: KnowledgeLint.Severity) -> String {
        switch severity {
        case .error: "Errors"
        case .warning: "Warnings"
        case .hint: "Hints"
        }
    }
}

private struct LintRow: View {
    @Environment(KnowledgeModel.self) private var model
    let finding: KnowledgeLint.Finding

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            LintIcon(severity: finding.severity)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.message).textSelection(.enabled)
                Text([finding.rule.rawValue, finding.file, finding.element].compactMap(\.self).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let fix = finding.fix {
                    Text(fix).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Open") { Task { await model.open(finding: finding) } }
                .help(finding.map.map { "Open the map \($0)" } ?? "Open the note \(finding.note ?? "")")
            if KnowledgeLint.newNote(for: finding) != nil {
                Button("Create Note…") { model.createNote(for: finding) }
                    .help("Write the note this link points to, so the link works")
            }
        }
        .controlSize(.small)
        .padding(.vertical, 2)
    }
}

/// The severity's icon: a red error, an orange warning, a grey hint.
struct LintIcon: View {
    let severity: KnowledgeLint.Severity

    var body: some View {
        switch severity {
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help("Error")
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Warning")
        case .hint: Image(systemName: "lightbulb").foregroundStyle(.secondary).help("Hint")
        }
    }
}
