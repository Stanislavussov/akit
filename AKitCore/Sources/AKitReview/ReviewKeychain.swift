import AKitFoundation
import Foundation
import Security

/// Review's tokens (GitLab, Azure DevOps) in the login Keychain, service `AKit Review`, written
/// and read in-process with the Security framework. Unlike MCP secrets (`KeychainSecretStore`),
/// no `/usr/bin/security` is trusted on them: another program on this Mac (a shell an agent
/// runs, a gather command) gets a Keychain prompt instead of the token. The app and the `akit`
/// command are two programs: the one that didn't save a token asks once.
public struct ReviewKeychain: SecretStore {
    public static let service = "AKit Review"

    public init() {}

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: account]
    }

    public func contains(_ account: String) -> Bool {
        var request = query(account)
        // Asks no question and reads no value: only whether the item is there.
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = SecItemCopyMatching(request as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    public func save(_ value: String, for account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConfigTextError("Keychain: the token is empty.") }
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrLabel as String] = "\(Self.service): \(account)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ConfigTextError("Keychain: the token was not saved (\(status)).") }
    }

    public func value(_ account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ConfigTextError("Keychain: AKit couldn't read the token (\(status)); allow AKit in the Keychain prompt.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ConfigTextError("Keychain: not removed (\(status)).") }
    }
}
