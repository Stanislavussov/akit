import Foundation
import Security

/// The OpenRouter key in the login Keychain (M9). It is read only to send a request; it is never
/// shown, logged or written to a file. Tests use their own service name.
///
/// The item is written and read by `/usr/bin/security`, not SecItemAdd (as AKit's SecretStore
/// does for MCP tokens): an item an app creates lands in that app's partition, and an ad-hoc
/// signed app that was rebuilt or updated is a new app to the Keychain, so macOS asked for the
/// login password on every read. `security` is trusted on the item, so AKit, `Meetings.app` and
/// each new build read it without a prompt. The value goes as hex through stdin (`security -i`),
/// never in a process argument.
public struct KeyStore: Sendable {
    public let service: String
    let account = "openrouter-api-key"

    public init(service: String = "Meetings OpenRouter") {
        self.service = service
    }

    /// Whether a key is there, from the item's attributes only (no secret read, no prompt).
    public var hasKey: Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    public func read() -> String? {
        guard hasKey, let text = try? Self.security(["find-generic-password", "-s", service, "-a", account, "-w"], input: nil) else { return nil }
        let key = text.trimmingCharacters(in: .newlines)
        return key.isEmpty ? nil : key
    }

    /// Replaces the key; an empty key removes it. Read back through `security` to prove the value
    /// and the silent access.
    public func save(_ key: String) throws {
        let trimmed = Self.clean(key)
        MeetingsLog.info(.key, "save: pasted \(key.count) chars, \(trimmed.count) after cleaning. \(Self.shape(trimmed))")
        guard !trimmed.isEmpty else { return delete() }
        guard trimmed.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw KeyError("The key may only hold printable ASCII characters.")
        }
        let hex = Data(trimmed.utf8).map { String(format: "%02x", $0) }.joined()
        let add = "add-generic-password -U -a \(account) -s \"\(service)\" -l \"\(service)\" -T /usr/bin/security -X \(hex)"
        _ = try Self.security(["-i"], input: "delete-generic-password -a \(account) -s \"\(service)\"\n\(add)\n")
        let back = read()
        guard back == trimmed else {
            MeetingsLog.error(.key, "save: the Keychain gives back \(back?.count ?? 0) chars, not the \(trimmed.count) saved")
            throw KeyError("The key was not saved correctly in the Keychain. Save it again.")
        }
        MeetingsLog.info(.key, "save: stored and read back, \(trimmed.count) chars")
    }

    public func delete() {
        _ = try? Self.security(["-i"], input: "delete-generic-password -a \(account) -s \"\(service)\"\n")
    }

    /// What the saved key looks like, never the key: its length and whether it has the form of an
    /// OpenRouter key (`sk-or-v1-` and 64 hex digits). For the Settings line under the field.
    public static func shape(_ key: String) -> String {
        let hex = key.dropFirst(9).allSatisfy(\.isHexDigit)
        if key.hasPrefix("sk-or-v1-"), key.count == 73, hex { return "The saved key has the form of an OpenRouter key (73 characters)." }
        if key.hasPrefix("sk-or-v1-") { return "The saved key starts with sk-or-v1- but has \(key.count) characters, not 73: it may be cut or masked (…). Copy the whole key when you create it." }
        if key.hasPrefix("sk-") { return "The saved key (\(key.count) characters) is not an OpenRouter key: it starts with sk- but not sk-or-v1- (an OpenAI or Anthropic key?)." }
        return "The saved key (\(key.count) characters) does not start with sk-or-v1-, so it is not an OpenRouter API key."
    }

    /// A pasted key without spaces, quotes or a `Bearer ` in front.
    public static func clean(_ key: String) -> String {
        var text = key.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        if text.lowercased().hasPrefix("bearer ") { text = String(text.dropFirst(7)) }
        return text.filter { !$0.isWhitespace }
    }

    /// Runs /usr/bin/security with optional stdin; returns stdout. Gives up after 20 s (a locked
    /// Keychain can wait for a password forever).
    static func security(_ arguments: [String], input: String?) throws -> String {
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
            throw KeyError("The Keychain did not answer. Is it locked?")
        }
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

public struct KeyError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
