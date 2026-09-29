import CryptoKit
import Foundation

public enum Checksum {
    /// Lowercase hex SHA-256.
    public static func sha256(_ data: some DataProtocol) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
