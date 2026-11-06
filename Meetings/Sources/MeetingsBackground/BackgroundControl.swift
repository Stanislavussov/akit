import AppKit
import Foundation

/// M28: the background recorder (`Meetings Recorder.app`, no window, no Dock or menu bar item)
/// and the apps that show meetings talk through distributed notifications: a host asks it to
/// record or stop, it says when something changed. The notifications carry only an action
/// word, never a meeting's text.
public enum BackgroundControl {
    public static let recorderID = "dev.ussov.meetings.recorder"
    static let control = Notification.Name("dev.ussov.meetings.control")
    static let changed = Notification.Name("dev.ussov.meetings.changed")

    /// `record`, `stop` or `toggle` for the background recorder.
    public static func send(_ action: String) {
        DistributedNotificationCenter.default().postNotificationName(control, object: action, userInfo: nil, deliverImmediately: true)
    }

    /// The recorder started or stopped a recording, or finished a transcription.
    public static func announceChange() {
        DistributedNotificationCenter.default().postNotificationName(changed, object: nil, userInfo: nil, deliverImmediately: true)
    }

    public static func onControl(_ handler: @escaping @Sendable (String) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: control, object: nil, queue: .main) { note in
            if let action = note.object as? String { handler(action) }
        }
    }

    public static func onChange(_ handler: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: changed, object: nil, queue: .main) { _ in handler() }
    }

    /// Whether the background recorder runs now (for a host: then Record goes to it).
    public static var recorderRuns: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: recorderID).contains { !$0.isTerminated && $0 != .current }
    }
}
