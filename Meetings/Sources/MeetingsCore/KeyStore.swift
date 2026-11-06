import Foundation
import Security

/// The OpenRouter key in the login Keychain (M9). It is read only to send a request; it is never
/// shown, logged or written to a file. Tests use their own service name.
public struct KeyStore: Sendable {
    public let service: String
    let account = "openrouter-api-key"

    public init(service: String = "Meetings OpenRouter") {
        self.service = service
    }

    var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    public var hasKey: Bool { read() != nil }

    public func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(query as CFDictionary)
        guard !trimmed.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(trimmed.utf8)
        q[kSecAttrLabel as String] = "Meetings: OpenRouter API key"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
