import Foundation
import Security

/// Where AKit keeps secret values (MCP tokens). The app uses the login Keychain;
/// tests use `MemorySecretStore`.
public protocol SecretStore: Sendable {
    func contains(_ account: String) -> Bool
    func save(_ value: String, for account: String) throws
}

/// Generic passwords in the login Keychain, service `AKit MCP`, account = variable name.
/// `/usr/bin/security` creates and is trusted on each item, so a harness can read it with
/// `security find-generic-password -s "AKit MCP" -a NAME -w` without a Keychain prompt.
public struct KeychainSecretStore: SecretStore {
    public static let service = "AKit MCP"

    public init() {}

    /// Account and env variable names AKit accepts: they end up in shell code
    /// (lookup commands, the sh wrapper, ~/.akit/env.sh).
    public static func isVariableName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    /// Only `[A-Za-z0-9_]`: whatever a caller passes, nothing else reaches shell code.
    static func shellSafe(_ name: String) -> String {
        String(name.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }.map(Character.init))
    }

    /// Shell command that prints the secret; used inside harness configs.
    public static func lookupCommand(_ account: String) -> String {
        "/usr/bin/security find-generic-password -s '\(service)' -a '\(shellSafe(account))' -w"
    }

    /// The account in `lookupCommand(_:)` output, nil for any other command or an unsafe name
    /// (a shared repo file may try to smuggle shell code into it).
    public static func lookupAccount(inCommand command: String) -> String? {
        let prefix = "/usr/bin/security find-generic-password -s '\(service)' -a '"
        guard command.hasPrefix(prefix), command.hasSuffix("' -w") else { return nil }
        let account = String(command.dropFirst(prefix.count).dropLast(4))
        return isVariableName(account) ? account : nil
    }

    /// `sh -c` script that exports each env key from its Keychain account, then runs the server
    /// (`"$0" "$@"` = the command and arguments after the script).
    public static func wrapperScript(_ exports: [(key: String, account: String)]) -> String {
        (exports.map { "\(shellSafe($0.key))=\"$(\(lookupCommand($0.account)))\" && export \(shellSafe($0.key))" }
            + ["exec \"$0\" \"$@\""])
            .joined(separator: " && ")
    }

    /// (env key, account) pairs of `wrapperScript(_:)`, nil when it's another script.
    public static func wrapperAccounts(_ script: String) -> [(key: String, account: String)]? {
        let parts = script.components(separatedBy: " && ")
        guard parts.last == "exec \"$0\" \"$@\"", parts.count >= 3, (parts.count - 1) % 2 == 0 else { return nil }
        var result: [(key: String, account: String)] = []
        for index in stride(from: 0, to: parts.count - 1, by: 2) {
            let assignment = parts[index]
            guard let eq = assignment.firstIndex(of: "="), parts[index + 1] == "export \(assignment[..<eq])" else { return nil }
            let key = String(assignment[..<eq])
            guard isVariableName(key) else { return nil }
            let rest = assignment[assignment.index(after: eq)...]
            guard rest.hasPrefix("\"$("), rest.hasSuffix(")\""),
                  let account = lookupAccount(inCommand: String(rest.dropFirst(3).dropLast(2))) else { return nil }
            result.append((key, account))
        }
        return result
    }

    /// (header, account) pairs of AKit's Claude `headersHelper`.
    public static func helperHeaders(_ helper: String) -> [(String, String)] {
        let headers = helper.matches(of: /"([^"]+)":"%s"/).map { String($0.output.1) }
        let accounts = helper.matches(of: /-a '([^']+)' -w/).map { String($0.output.1) }
        guard headers.count == accounts.count, helper.hasPrefix("printf '{"),
              headers.allSatisfy(isHeaderName), accounts.allSatisfy(isVariableName) else { return [] }
        let pairs = Array(zip(headers, accounts))
        // Only AKit's own helper, exactly as AKit writes it.
        return (try? helperCommand(pairs)) == helper ? pairs : []
    }

    /// HTTP header names AKit writes into a helper: RFC 7230 token characters without
    /// `%` (printf format) — no quotes or backslashes either.
    public static func isHeaderName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9!#$&+.^_`|~-]+$", options: .regularExpression) != nil
    }

    /// Claude `headersHelper` printing `{"Header":"<secret>"}` for each (header, account).
    /// The format sits in single quotes, so header names are literal text there.
    public static func helperCommand(_ pairs: [(String, String)]) throws -> String {
        guard pairs.allSatisfy({ isHeaderName($0.0) && isVariableName($0.1) }) else {
            throw ConfigTextError("Header names may only use letters, digits and - _ . characters.")
        }
        let format = "{" + pairs.map { "\"\($0.0)\":\"%s\"" }.joined(separator: ",") + "}"
        let values = pairs.map { "\"$(\(lookupCommand($0.1)))\"" }.joined(separator: " ")
        return "printf '\(format)' \(values)"
    }

    public func contains(_ account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: account]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Written by `/usr/bin/security` itself, not SecItemAdd: an item AKit creates lands in
    /// AKit's own partition, and `security` then shows a password prompt every time a
    /// harness starts the server. The command goes through stdin (`security -i`) with the
    /// value as hex (`-X`), so the secret never appears in a process argument list.
    /// The old item is deleted first so it gets this access list even if an older AKit
    /// made it; the result is read back through `security` to prove value and silent access.
    public func save(_ value: String, for account: String) throws {
        guard Self.isVariableName(account) else {
            throw ConfigTextError("Keychain: \(account) is not a valid name (letters, digits, _).")
        }
        guard !value.isEmpty else { throw ConfigTextError("Keychain: the value is empty.") }
        // `security -w` prints anything else as hex, so harnesses would get the wrong text.
        guard value.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else {
            throw ConfigTextError("Keychain: the value may only contain printable ASCII characters (no line breaks, tabs or letters like ä).")
        }
        let hex = Data(value.utf8).map { String(format: "%02x", $0) }.joined()
        let add = "add-generic-password -U -a \(account) -s \"\(Self.service)\" -l \"\(Self.service): \(account)\" -T /usr/bin/security -X \(hex)"
        // `security -i` reads a line into a ~4 KB buffer and would cut a longer value silently.
        guard add.utf8.count < 4000 else {
            throw ConfigTextError("Keychain: the value is too long for AKit (more than about 1.9 KB).")
        }
        _ = try Self.security(["-i"], input: "delete-generic-password -a \(account) -s \"\(Self.service)\"\n\(add)\n")
        let stored = try Self.security(["find-generic-password", "-s", Self.service, "-a", account, "-w"], input: nil)
        guard stored.trimmingCharacters(in: .newlines) == value else {
            throw ConfigTextError("Keychain: \(account) was not saved correctly, and an older value under that name may be gone. Save it again.")
        }
    }

    /// Runs /usr/bin/security with optional stdin; returns stdout. Gives up after 20 s
    /// (a locked Keychain can wait for a password forever).
    private static func security(_ arguments: [String], input: String?) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = arguments
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        guard finished.wait(timeout: .now() + 20) == .success else {
            process.terminate()
            throw ConfigTextError("Keychain didn't answer. Is it locked?")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}

/// In-memory store for tests.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func contains(_ account: String) -> Bool { lock.withLock { values[account] != nil } }
    public func save(_ value: String, for account: String) throws { lock.withLock { values[account] = value } }
    public func value(_ account: String) -> String? { lock.withLock { values[account] } }
}
