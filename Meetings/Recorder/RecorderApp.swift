import AppKit
import MeetingsAudio
import MeetingsBackground
import MeetingsCore
import MeetingsUI

/// Meetings Recorder (docs/design/meetings.md, M31): records with ⌥⌘R from any app, with no
/// window or Dock icon (LSUIElement). M41: a cat in the menu bar opens Record or Stop, the time
/// and the folder; Settings → Background turns it off for a shared screen (M4). It starts at
/// login as AKit's login item, records into the folder the settings name (read again when they
/// change) with the same key, transcribes after Stop, and tells the open apps when something
/// changed. Record and Stop in AKit come to it as notifications.
@main
@MainActor
final class RecorderDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    private var statusItem: NSStatusItem?
    /// The menu's elapsed-time line, updated each second while the menu is open.
    private var elapsedItem: NSMenuItem?
    private var menuTimer: Timer?
    private var settingsWatch: DispatchSourceFileSystemObject?

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
        showCat(model.settings.menuBarCat)
        watchSettings()
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
        if !was, action != "stop" {
            // A new recording goes where the settings say now.
            model.reloadSettings()
            sound("Tink")
        }
        await model.perform(action)
        if was, !model.isRecording { sound("Pop") }
        if let problem = model.problem {
            MeetingsLog.error(.ui, "background: \(action): \(problem)")
            alarm()
        }
        BackgroundControl.announceChange()
    }

    // MARK: Menu bar cat (M41)

    private func showCat(_ shown: Bool) {
        if shown, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = MenuBarCat.image
            item.button?.toolTip = "Meetings Recorder"
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if !shown, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.reloadSettings()
        menu.removeAllItems()
        // The shortcut is in the title, not a key equivalent: ⌥⌘R is already the global hotkey.
        let toggle = NSMenuItem(title: model.isRecording ? "Stop Recording (⌥⌘R)" : "Record (⌥⌘R)",
                                action: #selector(toggleRecording), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !model.starting
        menu.addItem(toggle)
        elapsedItem = nil
        if model.isRecording {
            let item = NSMenuItem(title: elapsedTitle(), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            elapsedItem = item
        }
        if !model.processing.isEmpty {
            let count = model.processing.count
            let item = NSMenuItem(title: "Transcribing \(count) meeting\(count == 1 ? "" : "s")…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if let problem = model.problem {
            let item = NSMenuItem(title: String(problem.prefix(80)), action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = problem
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let folder = NSMenuItem(title: "Saves to \((model.root.path as NSString).abbreviatingWithTildeInPath)",
                                action: #selector(showFolder), keyEquivalent: "")
        folder.target = self
        folder.toolTip = "The folder set in AKit → Meetings → Settings. Opens it in the Finder."
        menu.addItem(folder)
        let open = NSMenuItem(title: "Open Meetings in AKit", action: #selector(openMeetings), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
    }

    func menuWillOpen(_ menu: NSMenu) {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.elapsedItem?.title = self?.elapsedTitle() ?? "" }
        }
        // The menu tracks in its own run loop mode.
        RunLoop.main.add(timer, forMode: .common)
        menuTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTimer?.invalidate()
        menuTimer = nil
    }

    private func elapsedTitle() -> String {
        let seconds = Int(Date().timeIntervalSince(model.recordingStarted ?? Date()))
        let time = seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        return "Recording \(time)"
    }

    @objc private func toggleRecording() {
        Task { await perform("toggle") }
    }

    @objc private func showFolder() {
        try? FileManager.default.createDirectory(at: model.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(model.root)
    }

    @objc private func openMeetings() {
        if let url = URL(string: "akit://meetings") { NSWorkspace.shared.open(url) }
    }

    /// AKit's Settings save the file with an atomic write, which changes its folder: the folder
    /// is watched, then the settings are read again (the folder, the sounds, the cat itself).
    private func watchSettings() {
        let folder = model.settingsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.reloadSettings()
                self.showCat(self.model.settings.menuBarCat)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        settingsWatch = source
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
