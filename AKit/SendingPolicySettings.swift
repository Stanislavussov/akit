import AKitFoundation
import AKitLab
import SwiftUI

/// Settings → Sending policy: where session data and code may go, the accounts behind
/// them, what is masked before sending, and the monthly limit
/// (`docs/design/error-analysis.md`, "Sending policy"). Edits `lab`; the owner saves it.
struct SendingPolicySections: View {
    @Environment(AppModel.self) private var model
    @Binding var lab: LabSettings
    /// Snapshots: `--settings --add` opens Add Destination.
    @State private var editor: PolicyEntryEditor? = DebugSnapshot.options?.add == true ? .newDestination : nil
    @State private var checks: [AccountCheck] = []
    @State private var checking = false
    @State private var hostsText = ""
    @State private var extraText = ""
    @State private var limitText = ""
    @State private var monthCost: Double?

    var body: some View {
        Section {
            Label(model.machine.isWork
                  ? "Work Mac: session data goes only to the allowed list."
                  : "Personal Mac: session data goes to the same origin (the account that recorded it), plus the allowed list.",
                  systemImage: model.machine.isWork ? "building.2" : "house")
            ForEach(lab.allowedDestinations, id: \.self) { destination in
                HStack {
                    Text(destination.label).textSelection(.enabled)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { lab.allowedDestinations.removeAll { $0 == destination } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            if lab.allowedDestinations.isEmpty {
                Text("No destinations allowed yet.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Add Destination…") { editor = .newDestination }
                Spacer()
                Button(checking ? "Checking…" : "Check Accounts", action: checkAccounts)
                    .disabled(checking)
                    .help("Ask Claude Code (claude auth status) and Pi (pi auth check) which account a review would use now")
            }
            ForEach(checks) { check in AccountCheckRow(check: check, allowed: lab.allowedDestinations) { add($0) } }
        } header: {
            HStack {
                Text("Sending policy")
                Spacer()
                GuideButton(guide: .errorAnalysis, section: "settings", title: "How It Works")
                    .buttonStyle(.link)
                    .font(.callout)
            }
        } footer: {
            Text("Fill the list in by your company's policy for session data, not only for code. An entry is harness · provider · account · plan or organization; every review checks the account first.")
                .foregroundStyle(.secondary)
        }
        .sheet(item: $editor) { request in
            PolicyEntrySheet(request: request) { save($0, for: request) }
        }
        Section {
            ForEach(lab.piAccounts, id: \.self) { account in
                HStack {
                    Text("\(account.provider) · \(account.account) · \(account.org)").textSelection(.enabled)
                    Spacer()
                    Button("Edit", systemImage: "pencil") {
                        editor = PolicyEntryEditor(kind: .piAccount(index: lab.piAccounts.firstIndex(of: account)), entry: SendDestination(
                            harness: .pi, provider: account.provider, account: account.account, org: account.org))
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    Button("Remove", systemImage: "minus.circle") { lab.piAccounts.removeAll { $0 == account } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            Button("Add Pi Account…") {
                editor = PolicyEntryEditor(kind: .piAccount(index: nil), entry: SendDestination(harness: .pi, provider: "", account: "", org: ""))
            }
        } header: {
            Text("Pi accounts")
        } footer: {
            Text("Pi can't tell which account a provider is signed in with, so enter it here. Without an entry, reviews through that Pi provider are refused. AKit never reads Pi's keys.")
                .foregroundStyle(.secondary)
        }
        Section {
            Toggle("Mask e-mail addresses", isOn: $lab.scrub.maskEmails)
            PatternField(title: "Internal host patterns", prompt: "[a-z0-9.-]+\\.corp\\.example\\.com", text: $hostsText)
            PatternField(title: "Other patterns", prompt: "ACME-[0-9]{6}", text: $extraText)
            ForEach(Scrubber.invalidPatterns(lab.scrub), id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
        } header: {
            Text("Masked before sending").id("scrub")
        } footer: {
            Text("One regular expression per line; host patterns ignore case. Known secret formats (the gitleaks rules) are always masked. Scrub version \(Scrubber.version).")
                .foregroundStyle(.secondary)
        }
        Section {
            TextField("Monthly limit (US dollars)", text: $limitText, prompt: Text("No limit"))
            if limitProblem {
                Label("Enter an amount such as 20 or 12.50, or leave it empty for no limit.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            LabeledContent("Recorded this month", value: monthCost.map(UsageText.dollars) ?? "…")
        } header: {
            Text("Cost")
        } footer: {
            Text("Shared by every model call AKit makes. Only costs the harnesses recorded count; Lab → Sends lists the calls.")
                .foregroundStyle(.secondary)
        }
        .onAppear {
            fillTexts()
            // Snapshots: `--settings --capture` checks the accounts right away.
            if DebugSnapshot.options?.capture == true { checkAccounts() }
        }
        .onChange(of: hostsText) { lab.scrub.hosts = Self.lines(hostsText) }
        .onChange(of: extraText) { lab.scrub.extra = Self.lines(extraText) }
        .onChange(of: limitText) { if let limit = parsedLimit { lab.monthlyLimit = limit } }
        .task {
            let env = HarnessEnvironment.current
            monthCost = await Task.detached { SendLog.monthCost(SendLog.records(env: env)) }.value
        }
    }

    /// nil when the text isn't an amount; `.some(nil)` when it is empty (no limit).
    private var parsedLimit: Double?? {
        let text = limitText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        if text.isEmpty { return .some(nil) }
        guard let value = Double(text), value >= 0 else { return nil }
        return .some(value)
    }

    private var limitProblem: Bool { parsedLimit == nil }

    private func fillTexts() {
        hostsText = lab.scrub.hosts.joined(separator: "\n")
        extraText = lab.scrub.extra.joined(separator: "\n")
        limitText = lab.monthlyLimit.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? ""
    }

    /// Non-empty lines, trimmed.
    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func add(_ destination: SendDestination) {
        lab.save(destination, for: .destination)
    }

    private func save(_ entry: SendDestination, for request: PolicyEntryEditor) {
        lab.save(entry, for: request.kind)
    }

    /// The account each installed review harness would use now. Settings are saved on
    /// change, so the check reads the same Pi accounts as this form.
    private func checkAccounts() {
        checking = true
        Task {
            var results: [AccountCheck] = []
            for harness in model.labHarnesses {
                let agent = model.defaultAgent(harness)
                do {
                    let gate = try await SendGate.open(agent: agent, env: .current)
                    let origin: SendOrigin = harness == .pi ? .piSession(providers: [gate.destination.provider]) : .claudeSession
                    let decision = gate.decide(origin)
                    let onList = lab.allowedDestinations.contains { $0.matches(gate.destination) }
                    let text = !decision.allowed ? "not allowed. \(decision.reason)" : onList ? "allowed (on the list)." : "allowed (same origin)."
                    results.append(AccountCheck(harness: harness, destination: gate.destination, text: text))
                } catch {
                    results.append(AccountCheck(harness: harness, destination: nil, text: error.localizedDescription))
                }
            }
            if results.isEmpty {
                results.append(AccountCheck(harness: .claudeCode, destination: nil, text: "Neither Claude Code nor Pi is installed."))
            }
            checks = results
            checking = false
        }
    }
}

/// One harness's account, as checked now.
struct AccountCheck: Identifiable {
    let harness: LabHarness
    let destination: SendDestination?
    /// Whether that harness's own sessions may go there, or why the check failed.
    let text: String
    var id: LabHarness { harness }
}

private struct AccountCheckRow: View {
    let check: AccountCheck
    let allowed: [SendDestination]
    let add: (SendDestination) -> Void

    var body: some View {
        if let destination = check.destination {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Label(destination.label, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                    Spacer()
                    if !allowed.contains(where: { $0.matches(destination) }) {
                        Button("Add to List") { add(destination) }
                            .controlSize(.small)
                            .help("Allow session data from any origin to go to this account")
                    }
                }
                Text("\(check.harness.title) sessions: \(check.text)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Label("\(check.harness.title): \(check.text)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A list of regexes, one per line.
private struct PatternField: View {
    let title: String
    let prompt: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 52)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(prompt)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

/// An allowed destination or a Pi account being added or edited.
struct PolicyEntryEditor: Identifiable {
    enum Kind {
        case destination
        /// nil = a new account.
        case piAccount(index: Int?)
    }

    let id = UUID()
    let kind: Kind
    let entry: SendDestination

    static var newDestination: PolicyEntryEditor {
        PolicyEntryEditor(kind: .destination, entry: SendDestination(harness: .claudeCode, provider: "anthropic", account: "", org: ""))
    }

    var isPiAccount: Bool {
        if case .piAccount = kind { return true }
        return false
    }
}

extension LabSettings {
    /// An allowed destination (once), or a Pi account (one per provider; `index` edits that one).
    mutating func save(_ entry: SendDestination, for kind: PolicyEntryEditor.Kind) {
        switch kind {
        case .destination:
            guard !allowedDestinations.contains(where: { $0.matches(entry) }) else { return }
            allowedDestinations.append(entry)
        case .piAccount(let index):
            let account = PiAccount(provider: entry.provider, account: entry.account, org: entry.org)
            if let index, piAccounts.indices.contains(index) {
                piAccounts[index] = account
            } else if let same = piAccounts.firstIndex(where: { $0.provider.caseInsensitiveCompare(account.provider) == .orderedSame }) {
                piAccounts[same] = account
            } else {
                piAccounts.append(account)
            }
        }
    }
}

/// Harness (destinations only), provider, account and plan/org; all required.
struct PolicyEntrySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PolicyEntryEditor
    let onSave: (SendDestination) -> Void
    @State private var harness: LabHarness = .claudeCode
    @State private var provider = ""
    @State private var account = ""
    @State private var org = ""
    @State private var piProviders: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            Text(request.isPiAccount
                 ? "The account Pi uses for this provider, and the plan or organization behind it (for GitHub Copilot: the org that grants it)."
                 : "Session data may go here from any origin. Enter what claude auth status shows for Claude Code, or the Pi account you entered.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                if !request.isPiAccount {
                    Picker("Harness", selection: $harness) {
                        ForEach(LabHarness.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                HStack {
                    TextField("Provider", text: $provider, prompt: Text(harness == .pi ? "github-copilot" : "anthropic"))
                    Menu("Providers") {
                        ForEach(providers, id: \.self) { name in Button(name) { provider = name } }
                    }
                    .fixedSize()
                    .disabled(providers.isEmpty)
                }
                TextField("Account", text: $account, prompt: Text("you@example.com"))
                TextField("Plan or org", text: $org, prompt: Text(harness == .pi ? "acme" : "Acme Inc."))
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(height: request.isPiAccount ? 150 : 190)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    onSave(SendDestination(harness: harness, provider: trimmed(provider), account: trimmed(account), org: trimmed(org)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled([provider, account, org].contains { trimmed($0).isEmpty })
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            harness = request.entry.harness
            provider = request.entry.provider
            account = request.entry.account
            org = request.entry.org
        }
        .task {
            guard model.labHarnesses.contains(.pi) else { return }
            let models = await model.labModels(for: .pi)
            // Pi lists models as provider/model.
            piProviders = Array(Set(models.compactMap { name in name.firstIndex(of: "/").map { String(name[..<$0]) } })).sorted()
        }
    }

    private var title: String {
        switch request.kind {
        case .destination: "Add Destination"
        case .piAccount(let index): index == nil ? "Add Pi Account" : "Edit Pi Account"
        }
    }

    private var isNew: Bool {
        if case .piAccount(let index) = request.kind { return index == nil }
        return true
    }

    private var providers: [String] { harness == .pi ? piProviders : ["anthropic", "bedrock", "vertex"] }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }
}
