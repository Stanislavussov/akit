import AppKit
import ServiceManagement

/// M31: the background recorder as a login item of the host app (AKit embeds it in
/// `Contents/Library/LoginItems`). In a host without it (`Meetings.app`) it is not available.
///
/// M42: macOS's login item service doesn't find the ad-hoc signed recorder on every Mac (its
/// status stays "not found", 2026-11-25), so then a launch agent in `~/Library/LaunchAgents`
/// starts it at login instead, and the host starts it now and at its own launch.
public enum BackgroundRecorder {
    static var service: SMAppService { .loginItem(identifier: BackgroundControl.recorderID) }

    public enum State: Equatable, Sendable {
        case unavailable, off, on, needsApproval
    }

    /// The recorder inside the host app.
    static var recorderURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Library/LoginItems/Meetings Recorder.app")
    }

    /// M42: the launch agent that starts the recorder at login when the login item service can't.
    static var agentFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(agentLabel).plist")
    }

    static let agentLabel = "dev.ussov.akit.meetings-recorder"

    /// Asks macOS (about a tenth of a second): read it off the main thread.
    public static var state: State {
        guard recorderURL.path.withCString({ access($0, F_OK) == 0 }) else { return .unavailable }
        switch service.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return FileManager.default.fileExists(atPath: agentFile.path) ? .on : .off
        }
    }

    /// On: registered to start at login (the login item, else the launch agent) and started now.
    /// Off: both removed and the recorder quit (a running recording is stopped and kept by the
    /// recorder first).
    public static func set(_ on: Bool) throws {
        if on {
            try? service.register()
            if service.status != .enabled && service.status != .requiresApproval {
                try writeAgent()
            }
            launch()
        } else {
            try? service.unregister()
            try? FileManager.default.removeItem(at: agentFile)
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: BackgroundControl.recorderID) { app.terminate() }
        }
    }

    /// At the host's launch: when Background is on, a recorder that isn't running (it quit, or
    /// the launch agent pointed at a moved app) is started, and the launch agent follows the
    /// host's place.
    public static func startIfOn() {
        guard state == .on else { return }
        if FileManager.default.fileExists(atPath: agentFile.path) { try? writeAgent() }
        if !BackgroundControl.recorderRuns { launch() }
    }

    /// Starts the recorder without bringing it forward; a running one stays as it is.
    static func launch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: recorderURL, configuration: configuration)
    }

    /// `open -g` of the recorder inside the host, at login. Written again when the host moved.
    static func writeAgent() throws {
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/open", "-g", recorderURL.path],
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        if (try? Data(contentsOf: agentFile)) == data { return }
        try FileManager.default.createDirectory(at: agentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: agentFile, options: .atomic)
    }

    public static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
