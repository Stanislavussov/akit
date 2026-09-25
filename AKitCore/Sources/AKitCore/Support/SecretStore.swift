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

    /// Shell command that prints the secret; used inside harness configs.
    public static func lookupCommand(_ account: String) -> String {
        "/usr/bin/security find-generic-password -s '\(service)' -a '\(account)' -w"
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
    public func save(_ value: String, for account: String) throws {
        guard account.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            throw ConfigTextError("Keychain: \(account) is not a valid name.")
        }
        let hex = Data(value.utf8).map { String(format: "%02x", $0) }.joined()
        let commands = """
        delete-generic-password -a \(account) -s "\(Self.service)"
        add-generic-password -U -a \(account) -s "\(Self.service)" -l "\(Self.service): \(account)" -T /usr/bin/security -X \(hex)

        """
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = ["-i"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(commands.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard contains(account) else { throw ConfigTextError("Keychain: \(account) could not be saved.") }
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
