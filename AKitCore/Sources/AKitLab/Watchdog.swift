import Darwin
import Foundation

/// Kills test processes that grow too large. Checks every second: every process in the
/// groups of the run's current children, and every `swiftpm-testing-helper` or `xctest`
/// working inside the run's folder (the helper can outlive `swift test`). Uses the memory
/// footprint, which counts compressed memory, unlike the resident size `ps` shows.
final class Watchdog: @unchecked Sendable {
    let folder: String
    let limit: UInt64
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var running = false

    init(folder: URL, limit: UInt64 = 2 << 30, log: @escaping @Sendable (String) -> Void) {
        self.folder = folder.standardizedFileURL.resolvingSymlinksInPath().path
        self.limit = limit
        self.log = log
    }

    func start() {
        lock.withLock { running = true }
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                check()
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    func stop() { lock.withLock { running = false } }

    /// Runs `work` with the watchdog on.
    func watching<T>(_ work: () async throws -> T) async rethrows -> T {
        start()
        defer { stop() }
        return try await work()
    }

    func check() {
        let groups = Cancellation.trackedGroups
        for pid in Self.allProcesses() where pid != getpid() {
            let inGroup = groups.contains(getpgid(pid))
            guard inGroup || isTestHelper(pid) else { continue }
            guard let footprint = Self.footprint(of: pid), footprint > limit else { continue }
            kill(pid, SIGKILL)
            log("Watchdog: killed \(Self.name(of: pid) ?? "process") \(pid) at \(footprint >> 20) MB (limit \(limit >> 20) MB).")
        }
    }

    /// Test helpers whose working folder is inside the run's folder.
    func isTestHelper(_ pid: pid_t) -> Bool {
        guard let name = Self.name(of: pid), name == "swiftpm-testing-helper" || name == "xctest",
              let cwd = Self.workingFolder(of: pid) else { return false }
        return cwd == folder || cwd.hasPrefix(folder + "/")
    }

    /// Kills leftover test helpers working in the folder (after each test).
    func killHelpers() {
        for pid in Self.allProcesses() where isTestHelper(pid) { kill(pid, SIGKILL) }
    }

    static func allProcesses() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(0, found)))).filter { $0 > 0 }
    }

    static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? info.ri_phys_footprint : nil
    }

    static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(filePath: path).lastPathComponent
    }

    static func workingFolder(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
