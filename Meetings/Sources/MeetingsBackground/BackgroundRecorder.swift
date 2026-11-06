import AppKit
import ServiceManagement

/// M31: the background recorder as a login item of the host app (AKit embeds it in
/// `Contents/Library/LoginItems`). In a host without it (`Meetings.app`) it is not available.
public enum BackgroundRecorder {
    static var service: SMAppService { .loginItem(identifier: BackgroundControl.recorderID) }

    public enum State: Equatable, Sendable {
        case unavailable, off, on, needsApproval
    }

    public static var state: State {
        guard Bundle.main.bundleURL.appending(path: "Contents/Library/LoginItems/Meetings Recorder.app").path
            .withCString({ access($0, F_OK) == 0 }) else { return .unavailable }
        switch service.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notFound: return .unavailable
        default: return .off
        }
    }

    /// On: registered to start at login and started now. Off: unregistered and quit (a running
    /// recording is stopped and kept by the recorder first).
    public static func set(_ on: Bool) throws {
        if on {
            try service.register()
        } else {
            try service.unregister()
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: BackgroundControl.recorderID) { app.terminate() }
        }
    }

    public static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
