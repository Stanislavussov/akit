import Foundation

/// This Mac's host name (`NB123.local`), read with `gethostname` and kept for the process.
/// `ProcessInfo.processInfo.hostName` asks `NSHost`, which resolves the name through DNS: on a
/// network that doesn't answer, its first call waits about 5 seconds, in every `akit` command.
public enum HostName {
    public static let current: String = {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()
}
