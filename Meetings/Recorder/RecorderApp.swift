import AppKit
import MeetingsAudio
import MeetingsBackground
import MeetingsCore
import MeetingsUI

/// Meetings Recorder (docs/design/meetings.md, M31): records with ⌥⌘R from any app, with no
/// window, Dock icon or menu bar item (LSUIElement; M4: nothing to see on a shared screen). It
/// starts at login as AKit's login item, records into the same folder with the same settings and
/// key, transcribes after Stop, and tells the open apps when something changed. Record and Stop
/// in AKit come to it as notifications.
@main
@MainActor
final class RecorderDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = RecorderDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    let model = MeetingsModel()
    private var hotKey: GlobalHotKey?
    private var observer: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One recorder: a second copy (another AKit build's login item) quits.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: BackgroundControl.recorderID).filter { $0 != .current }
        if !others.isEmpty {
            MeetingsLog.info(.ui, "background: another Meetings Recorder runs; this one quits")
            NSApp.terminate(nil)
            return
        }
        model.isBackgroundHost = true
        model.didRefresh = { BackgroundControl.announceChange() }
        model.didReportProblem = { [weak self] _ in self?.alarm() }
        hotKey = GlobalHotKey { [weak self] in Task { await self?.perform("toggle") } }
        MeetingsLog.info(.ui, hotKey == nil ? "background: ⌥⌘R is taken by another app" : "background: ⌥⌘R ready")
        observer = BackgroundControl.onControl { [weak self] action in Task { @MainActor in await self?.perform(action) } }
        Task { await model.load() }
        // M32: macOS asks each app once. The question comes now, when Background is turned on,
        // not at the first ⌥⌘R in a meeting; the answer stays for later starts and updates.
        Task { _ = await Recorder.microphoneAllowed() }
    }

    private func alarm() {
        NSSound(named: "Basso")?.play()
    }

    func perform(_ action: String) async {
        let was = model.isRecording
        model.problem = nil
        // The start sound plays before the microphone opens, the stop sound after it closes.
        if !was, action != "stop" { sound("Tink") }
        await model.perform(action)
        if was, !model.isRecording { sound("Pop") }
        if let problem = model.problem {
            MeetingsLog.error(.ui, "background: \(action): \(problem)")
            alarm()
        }
        BackgroundControl.announceChange()
    }

    private func sound(_ name: String) {
        guard model.settings.backgroundSounds else { return }
        NSSound(named: name)?.play()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A local whisper or Pi run ends and its meeting waits for the next start.
        model.prepareToQuit()
        guard model.isRecording else { return .terminateNow }
        Task { @MainActor in
            await model.stop()
            BackgroundControl.announceChange()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
