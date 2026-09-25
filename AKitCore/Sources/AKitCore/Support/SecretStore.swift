import Foundation
import Security

/// Where AKit keeps secret values (MCP tokens). The app uses the login Keychain;
/// tests use `MemorySecretStore`.
public protocol SecretStore: Sendable {
    func contains(_ account: String) -> Bool
    func save(_ value: String, for account: String) throws
}

/// Generic passwords in the login Keychain, service `AKit MCP`, account = variable name.
/// `/usr/bin/security` is trusted on each item, so a harness can read it with
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

    public func save(_ value: String, for account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary) // replace, so the access list is always ours
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "\(Self.service): \(account)"
        if let access = (LegacyAccess.self as any AccessMaker.Type).make("\(Self.service): \(account)") {
            item[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw ConfigTextError("Keychain: \(message)")
        }
    }
}

/// Called through this protocol so the deprecated API below doesn't warn at every build.
private protocol AccessMaker { static func make(_ label: String) -> SecAccess? }

/// Access list: AKit itself and `/usr/bin/security`. The file-based login Keychain
/// only offers the deprecated SecAccess API for this.
private enum LegacyAccess: AccessMaker {
    @available(macOS, deprecated: 10.10)
    static func make(_ label: String) -> SecAccess? {
        var apps: [SecTrustedApplication] = []
        var me: SecTrustedApplication?
        var tool: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me { apps.append(me) }
        if SecTrustedApplicationCreateFromPath("/usr/bin/security", &tool) == errSecSuccess, let tool { apps.append(tool) }
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, apps as CFArray, &access) == errSecSuccess else { return nil }
        return access
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
