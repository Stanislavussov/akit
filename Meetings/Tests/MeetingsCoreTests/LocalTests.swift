import Foundation
import Testing
@testable import MeetingsCore

/// Statuses a local run reported, in order.
final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LocalStatus] = []
    func add(_ status: LocalStatus) { lock.withLock { items.append(status) } }
    var all: [LocalStatus] { lock.withLock { items } }
    func saw(_ phase: LocalStatus.Phase) -> Bool { all.contains { $0.phase == phase } }
}

/// Points the live-children file at a temporary folder before any test spawns a child, so the
/// tests never write the user's `~/Library/Application Support/Meetings/children.txt`.
enum TestChildren {
    static let ready: Void = {
        ChildRun.liveFolder = FileManager.default.temporaryDirectory.appending(path: "meetings-children-\(UUID().uuidString)", directoryHint: .isDirectory)
    }()
}

/// The pid a run reports at its start.
final class PidBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    func set(_ value: pid_t) { lock.withLock { pid = value } }
    var value: pid_t? { lock.withLock { pid } }
}

/// A heat that a test can change while a run works.
final class Heat: @unchecked Sendable {
    private let lock = NSLock()
    private var state: ProcessInfo.ThermalState = .nominal
    var value: ProcessInfo.ThermalState {
        get { lock.withLock { state } }
        set { lock.withLock { state = newValue } }
    }
}

/// Fake `afconvert`, `whisper-cli` and `pi` scripts in a temporary folder, and a meeting with
/// two 60-second pieces whose tracks hold the words "mic" and "sys".
struct LocalFixture {
    let root = TempRoot()
    let bin: URL
    let meeting: Meeting

    /// `slowCall`: the whisper call (1, 2 …, counted in a file) that sleeps 20 s.
    init(whisperSleeps: Int = 0, slowCall: Int? = nil) throws {
        TestChildren.ready
        bin = root.url.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Self.script(bin.appending(path: "afconvert"), "cp \"$7\" \"$8\"")
        let counter = root.url.appending(path: "whisper-calls").path
        try Self.script(bin.appending(path: "whisper-cli"), """
        sleep \(whisperSleeps)
        n=$(( $(cat "\(counter)" 2>/dev/null || echo 0) + 1 )); echo $n > "\(counter)"
        [ "$n" = "\(slowCall ?? -1)" ] && sleep 20
        while [ $# -gt 0 ]; do case "$1" in -f) f="$2"; shift;; -of) o="$2"; shift;; esac; shift; done
        if [ "$(cat "$f")" = mic ]; then
          printf '{"transcription":[{"offsets":{"from":1000,"to":4000},"text":" Ahoj"},{"offsets":{"from":30000,"to":32000},"text":" Titulky vytvořil"}]}' > "$o.json"
        else
          printf '{"transcription":[{"offsets":{"from":11000,"to":14000},"text":" Dobrý den"},{"offsets":{"from":20000,"to":21000},"text":"[BLANK_AUDIO]"}]}' > "$o.json"
        fi
        """)
        try Self.script(bin.appending(path: "pi"), """
        printf '%s\\n' "$@" > "$ARGS_FILE"
        echo 'Here are the notes:'
        echo '{"title": "Plán týdne", "summary": "Krátce.", "decisions": ["Vydání v pátek"], "tasks": [{"owner": "Me", "text": "Rozpočet"}]}'
        """)
        // A sparse file as big as the real model, so the size check passes.
        let model = bin.appending(path: "model.bin")
        FileManager.default.createFile(atPath: model.path, contents: nil)
        let handle = try FileHandle(forWritingTo: model)
        try handle.truncate(atOffset: UInt64(LocalWhisper.modelBytes))
        try handle.close()

        let store = root.store
        meeting = try store.create()
        var saved = meeting
        saved.state = .waiting
        try store.save(saved)
        let audio = store.audioFolder(meeting.id)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        for i in 1...2 {
            let name = String(format: "%03d", i)
            try Data("mix".utf8).write(to: audio.appending(path: "piece-\(name).aac"))
            try Data("mic".utf8).write(to: audio.appending(path: "mic-\(name).aac"))
            try Data("sys".utf8).write(to: audio.appending(path: "sys-\(name).aac"))
            let info = PieceInfo(duration: 60, me: [TimeSpan(start: 0, end: 5)], others: [TimeSpan(start: 10, end: 15)])
            try JSONEncoder().encode(info).write(to: audio.appending(path: "piece-\(name).json"))
        }
    }

    static func script(_ url: URL, _ body: String) throws {
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    var tools: LocalWhisper.Tools {
        LocalWhisper.Tools(cli: bin.appending(path: "whisper-cli"), model: bin.appending(path: "model.bin"), converter: bin.appending(path: "afconvert"))
    }

    var argsFile: URL { root.url.appending(path: "pi-args") }

    var settings: MeetingsSettings {
        var settings = MeetingsSettings()
        settings.transcription = .local
        settings.summarizer = .pi
        settings.piModel = "oc-sdk-go/glm-5"
        return settings
    }

    func processor(_ local: LocalEnvironment, settings: MeetingsSettings? = nil) -> MeetingProcessor {
        MeetingProcessor(store: root.store, settings: settings ?? self.settings, client: nil, local: local, whisper: tools,
                         piEnvironment: ["PATH": bin.path, "ARGS_FILE": argsFile.path])
    }
}

@Suite struct LocalWhisperTests {
    @Test func readsWhisperJSONAndDropsNoise() throws {
        let json = #"{"transcription":[{"offsets":{"from":0,"to":3260},"text":" Dobrý den."},{"offsets":{"from":3560,"to":7000},"text":" [BLANK_AUDIO]"},{"offsets":{"from":8000,"to":9000},"text":" ♪ ♪"},{"offsets":{"from":9000,"to":9500},"text":" "}]}"#
        let lines = try LocalWhisper.parse(Data(json.utf8))
        #expect(lines == [LocalWhisper.Line(from: 0, to: 3.26, text: "Dobrý den.")])
        #expect(throws: MeetingsError.self) { try LocalWhisper.parse(Data("{}".utf8)) }
    }

    @Test func keepsOnlyLinesInSpeech() {
        let lines = [LocalWhisper.Line(from: 1, to: 4, text: "in"), LocalWhisper.Line(from: 30, to: 32, text: "made up"),
                     LocalWhisper.Line(from: 9.8, to: 10.2, text: "short, half in")]
        let spans = [TimeSpan(start: 0, end: 5), TimeSpan(start: 10, end: 11)]
        #expect(LocalWhisper.keep(lines, spans: spans).map(\.text) == ["in", "short, half in"])
        #expect(LocalWhisper.keep(lines, spans: nil).count == 3)
    }

    /// whisper starts a line in the silence before the speech; the span's start is the line's.
    @Test func lineStartsWithItsSpeech() {
        let lines = [LocalWhisper.Line(from: 0, to: 17, text: "after silence")]
        #expect(LocalWhisper.keep(lines, spans: [TimeSpan(start: 12, end: 17)]).first?.from == 12)
    }

    @Test func errorTailSkipsWarnings() {
        let text = "Warning: Extension package x: something\ncan bypass the loader.\nWarning: more\n401: key expired\n\n"
        #expect(LocalTranscriber.tail(Data(text.utf8)) == "401: key expired")
        #expect(LocalTranscriber.tail(Data()) == "no message")
    }

    @Test func mixSpeakerFollowsTheMicSpans() {
        let me = [TimeSpan(start: 0, end: 5)]
        #expect(LocalWhisper.speaker(.init(from: 1, to: 4, text: ""), me: me) == "Me")
        #expect(LocalWhisper.speaker(.init(from: 4, to: 10, text: ""), me: me) == "Others")
    }

    @Test func cpuModeTurnsTheGPUOff() {
        let file = URL(filePath: "/x")
        #expect(LocalWhisper.arguments(model: file, wav: file, out: file, language: "cs", gpu: false, threads: 5).contains("-ng"))
        let gpu = LocalWhisper.arguments(model: file, wav: file, out: file, language: "", gpu: true, threads: 4)
        #expect(!gpu.contains("-ng"))
        #expect(gpu.contains("auto"))
    }

    @Test func readsPiModels() {
        let text = """
        provider            model                         context  max-out  thinking  images
        google-antigravity  gemini-3.1-pro-preview        1.0M     65.5K    yes       yes
        oc-sdk-go           glm-5                         202.8K   32.8K    yes       no

        """
        #expect(PiSummarizer.parseModels(text) == ["google-antigravity/gemini-3.1-pro-preview", "oc-sdk-go/glm-5"])
    }

    @Test func pauseReasons() {
        let control = LocalControl()
        #expect(control.pause(.nominal) == nil)
        control.userPaused = true
        #expect(control.pause(.fair) == .user)
        control.recording = true
        #expect(control.pause(.nominal) == .recording)
        #expect(control.pause(.serious) == .hot)
    }

    @Test func settingsOfAnOlderFileStayCloud() throws {
        let settings = try JSONDecoder().decode(MeetingsSettings.self, from: Data(#"{"model": "x"}"#.utf8))
        #expect(settings.transcription == .cloud)
        #expect(settings.summarizer == .openRouter)
        #expect(settings.needsKey)
        var local = settings
        local.transcription = .local
        local.summarizer = .pi
        #expect(!local.needsKey)
    }
}

@Suite struct ChildRunTests {
    init() { TestChildren.ready }

    @Test func stopKillsTheProcess() async throws {
        let control = LocalControl()
        let local = LocalEnvironment(control: control, tick: .milliseconds(20))
        let started = Date()
        Task {
            try await Task.sleep(for: .milliseconds(200))
            control.stopped = true
        }
        await #expect(throws: MeetingsError.stopped) {
            _ = try await ChildRun.run(URL(filePath: "/bin/sleep"), ["30"], local: local, resume: LocalStatus(phase: .transcribing))
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func criticalHeatKillsTheProcess() async throws {
        let heat = Heat()
        let local = LocalEnvironment(thermal: { heat.value }, tick: .milliseconds(20))
        Task {
            try await Task.sleep(for: .milliseconds(200))
            heat.value = .critical
        }
        await #expect(throws: MeetingsError.tooHot) {
            _ = try await ChildRun.run(URL(filePath: "/bin/sleep"), ["30"], local: local, resume: LocalStatus(phase: .transcribing))
        }
    }

    /// A stopped process cannot end: a 0.2-second sleep paused for a second ends after the pause.
    @Test func pauseHoldsTheProcess() async throws {
        let control = LocalControl()
        control.userPaused = true
        let log = StatusLog()
        let local = LocalEnvironment(control: control, status: { log.add($0) }, tick: .milliseconds(20))
        Task {
            try await Task.sleep(for: .seconds(1))
            control.userPaused = false
        }
        let started = Date()
        let result = try await ChildRun.run(URL(filePath: "/bin/sleep"), ["0.2"], local: local, resume: LocalStatus(phase: .transcribing))
        #expect(result.status == 0)
        #expect(Date().timeIntervalSince(started) >= 0.9)
        #expect(log.saw(.paused(.user)))
        #expect(log.saw(.transcribing))
    }

    /// Stop ends the whole group: the shell and the sleep it started.
    @Test func stopKillsTheGroup() async throws {
        let control = LocalControl()
        let local = LocalEnvironment(control: control, tick: .milliseconds(20))
        let leader = PidBox()
        Task {
            try await Task.sleep(for: .milliseconds(300))
            control.stopped = true
        }
        await #expect(throws: MeetingsError.stopped) {
            _ = try await ChildRun.run(URL(filePath: "/bin/sh"), ["-c", "sleep 30 & sleep 30; wait"], local: local,
                                       resume: LocalStatus(phase: .transcribing)) { leader.set($0) }
        }
        let pid = try #require(leader.value)
        try await Task.sleep(for: .milliseconds(200))
        #expect(kill(-pid, 0) != 0)
    }

    /// The time limit counts work, not pauses.
    @Test func pauseDoesNotCountAgainstTheLimit() async throws {
        let control = LocalControl()
        control.userPaused = true
        let local = LocalEnvironment(control: control, tick: .milliseconds(20))
        Task {
            try await Task.sleep(for: .seconds(1))
            control.userPaused = false
        }
        let result = try await ChildRun.run(URL(filePath: "/bin/sleep"), ["0.2"], timeout: 0.6, local: local,
                                            resume: LocalStatus(phase: .transcribing))
        #expect(result.status == 0)
    }

    @Test func readsLargeOutput() async throws {
        let result = try await ChildRun.run(URL(filePath: "/bin/sh"), ["-c", "head -c 300000 /dev/zero | tr '\\0' a; echo oops >&2"],
                                            local: LocalEnvironment(tick: .milliseconds(10)), resume: LocalStatus(phase: .transcribing))
        #expect(result.output.count == 300_000)
        #expect(String(decoding: result.errors, as: UTF8.self) == "oops\n")
    }

    @Test func recordingInTheOtherAppPauses() async throws {
        let elsewhere = Heat()
        elsewhere.value = .fair  // .fair stands for "recording elsewhere"
        let log = StatusLog()
        let local = LocalEnvironment(status: { log.add($0) }, tick: .milliseconds(20), recordingElsewhere: { elsewhere.value == .fair })
        Task {
            try await Task.sleep(for: .milliseconds(500))
            elsewhere.value = .nominal
        }
        _ = try await ChildRun.run(URL(filePath: "/bin/sleep"), ["0.1"], local: local, resume: LocalStatus(phase: .transcribing))
        #expect(log.saw(.paused(.recording)))
    }

    /// A crashed app left a whisper running: the next launch ends it; a living app's file stays.
    @Test func launchEndsLeftovers() throws {
        let child = try ChildRun.spawn(URL(filePath: "/bin/sleep"), ["/bin/sleep", "30"], environment: nil, directory: nil)
        close(child.out); close(child.err)
        let folder = ChildRun.liveFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A pid no process has (the owner is gone), and this test process's own (alive).
        let dead = folder.appending(path: "children-99999.txt"), alive = folder.appending(path: "children-\(getppid()).txt")
        try Data("\(child.pid)\t/bin/sleep\n\(child.pid)\t/opt/other\n".utf8).write(to: dead)
        try Data("\(child.pid)\t/bin/sleep\n".utf8).write(to: alive)
        #expect(ChildRun.endLeftovers() == 1)
        var raw: Int32 = 0
        waitpid(child.pid, &raw, 0)
        #expect(raw & 0x7f == SIGKILL)
        #expect(!FileManager.default.fileExists(atPath: dead.path))
        #expect(FileManager.default.fileExists(atPath: alive.path))
        try? FileManager.default.removeItem(at: alive)
    }

    /// The other app's recording, seen without taking its lock.
    @Test func recordingSignalOfAnotherProcess() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "rec-\(UUID().uuidString)")
        #expect(!RecordingSignal.elsewhere(file))
        // Another process holds a record lock on the file (lockf takes a POSIX lock).
        let holder = try ChildRun.spawn(URL(filePath: "/usr/bin/python3"),
                                        ["python3", "-c", "import fcntl,time;f=open('\(file.path)','w');fcntl.lockf(f,fcntl.LOCK_EX);print('ok',flush=True);time.sleep(30)"],
                                        environment: nil, directory: nil)
        let reader = ChildRun.Reader(holder.out)
        close(holder.err)
        var seen = false
        for _ in 0..<100 where !seen {
            try await Task.sleep(for: .milliseconds(50))
            seen = RecordingSignal.elsewhere(file)
        }
        #expect(seen)
        kill(-holder.pid, SIGKILL)
        var raw: Int32 = 0
        waitpid(holder.pid, &raw, 0)
        _ = reader.finish(within: 1)
        #expect(!RecordingSignal.elsewhere(file))
    }

    @Test func readsTheOutput() async throws {
        let result = try await ChildRun.run(URL(filePath: "/bin/echo"), ["hello"], local: LocalEnvironment(tick: .milliseconds(10)),
                                            resume: LocalStatus(phase: .transcribing))
        #expect(String(decoding: result.output, as: UTF8.self) == "hello\n")
    }
}

@Suite struct LocalProcessorTests {
    @Test func whisperThenPiWriteTheMeeting() async throws {
        let fixture = try LocalFixture()
        let log = StatusLog()
        let meeting = try await fixture.processor(LocalEnvironment(status: { log.add($0) }, tick: .milliseconds(10))).run(fixture.meeting.id)
        #expect(meeting.state == .done)
        // The made-up line in the mic's silence and the blank are gone; piece 2 starts at 60 s.
        #expect(meeting.segments == [
            Segment(start: 1, speaker: "Me", text: "Ahoj"), Segment(start: 11, speaker: "Others", text: "Dobrý den"),
            Segment(start: 61, speaker: "Me", text: "Ahoj"), Segment(start: 71, speaker: "Others", text: "Dobrý den"),
        ])
        #expect(meeting.title == "Plán týdne")
        #expect(meeting.costUSD == 0)
        #expect(meeting.model == "whisper large-v3-turbo (local)")
        #expect(meeting.summaryModel == "pi: oc-sdk-go/glm-5")
        #expect(meeting.transcribedPieces == 2)
        let summary = fixture.root.store.summary(meeting.id)
        #expect(summary.contains("- [ ] Me: Rozpočet"))
        let args = try String(contentsOf: fixture.argsFile, encoding: .utf8)
        for flag in ["--no-tools", "--no-session", "--no-skills", "--no-context-files", "--model", "oc-sdk-go/glm-5"] { #expect(args.contains(flag)) }
        // Pi gets the transcript in a file, never in the arguments.
        #expect(!args.contains("Dobrý den"))
        #expect(log.saw(.transcribing))
        #expect(log.saw(.summarizing))
    }

    @Test func stopKeepsThePiecesDoneAndFails() async throws {
        let fixture = try LocalFixture(whisperSleeps: 20)
        let control = LocalControl()
        Task {
            try await Task.sleep(for: .milliseconds(300))
            control.stopped = true
        }
        await #expect(throws: MeetingsError.stopped) {
            try await fixture.processor(LocalEnvironment(control: control, tick: .milliseconds(20))).run(fixture.meeting.id)
        }
        let saved = try #require(fixture.root.store.load(fixture.meeting.id))
        #expect(saved.state == .failed)
        #expect(saved.failure == MeetingsError.stopped.errorDescription)
        #expect(saved.transcribedPieces == 0)
    }

    /// Quit during a piece: the meeting waits for the next start instead of failing.
    @Test func quitLeavesTheMeetingWaiting() async throws {
        let fixture = try LocalFixture(whisperSleeps: 20)
        let control = LocalControl()
        Task {
            try await Task.sleep(for: .milliseconds(300))
            control.quitting = true
            control.stopped = true
        }
        await #expect(throws: MeetingsError.stopped) {
            try await fixture.processor(LocalEnvironment(control: control, tick: .milliseconds(20))).run(fixture.meeting.id)
        }
        #expect(fixture.root.store.load(fixture.meeting.id)?.state == .waiting)
    }

    /// Stop during piece 2 keeps piece 1; Try Again goes on with piece 2 only, no line twice.
    @Test func tryAgainGoesOnAfterStop() async throws {
        // Calls 1–2 are piece 1 (mic, sys); call 3 is piece 2's mic: it hangs until Stop.
        let fixture = try LocalFixture(slowCall: 3)
        let control = LocalControl()
        let log = StatusLog()
        let first = fixture.processor(LocalEnvironment(control: control, status: { log.add($0) }, tick: .milliseconds(20)))
        let run = Task { try await first.run(fixture.meeting.id) }
        while !log.all.contains(where: { $0.phase == .transcribing && $0.piece == 2 }) { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        control.stopped = true
        await #expect(throws: MeetingsError.stopped) { try await run.value }
        let stopped = try #require(fixture.root.store.load(fixture.meeting.id))
        #expect(stopped.transcribedPieces == 1)
        #expect(stopped.segments.count == 2)
        let done = try await fixture.processor(LocalEnvironment(tick: .milliseconds(10))).run(fixture.meeting.id)
        #expect(done.state == .done)
        #expect(done.segments.map(\.start) == [1, 11, 61, 71])
    }

    @Test func waitsWhileARecordingRuns() async throws {
        let fixture = try LocalFixture()
        let control = LocalControl(recording: true)
        let log = StatusLog()
        let processor = fixture.processor(LocalEnvironment(control: control, status: { log.add($0) }, tick: .milliseconds(20)))
        let run = Task { try await processor.run(fixture.meeting.id) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(log.saw(.paused(.recording)))
        #expect(fixture.root.store.load(fixture.meeting.id)?.transcribedPieces == 0)
        control.recording = false
        let meeting = try await run.value
        #expect(meeting.state == .done)
    }

    @Test func oneLocalRunAtATime() async throws {
        let fixture = try LocalFixture()
        let held = try #require(MeetingLock.take(fixture.root.url.appending(path: ".local-run.lock")))
        let log = StatusLog()
        let processor = fixture.processor(LocalEnvironment(status: { log.add($0) }, tick: .milliseconds(20)))
        let run = Task { try await processor.run(fixture.meeting.id) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(log.saw(.queued))
        held.release()
        #expect(try await run.value.state == .done)
    }

    @Test func missingWhisperSaysWhatToClick() async throws {
        let fixture = try LocalFixture()
        var tools = fixture.tools
        tools.model = fixture.root.url.appending(path: "none.bin")
        let processor = MeetingProcessor(store: fixture.root.store, settings: fixture.settings, client: nil,
                                         local: LocalEnvironment(tick: .milliseconds(10)), whisper: tools)
        await #expect(throws: MeetingsError.local("the whisper model is not downloaded. Click Download Model in Meetings Settings.")) {
            try await processor.run(fixture.meeting.id)
        }
    }

    @Test func cloudTranscriptionWithoutKeyFails() async throws {
        let fixture = try LocalFixture()
        var settings = fixture.settings
        settings.transcription = .cloud
        await #expect(throws: MeetingsError.noKey) {
            try await fixture.processor(LocalEnvironment(tick: .milliseconds(10)), settings: settings).run(fixture.meeting.id)
        }
    }
}

@Suite struct ProcessingEstimateTests {
    @Test func timeLeftIsPiecesLeftPlusSummary() {
        #expect(ProcessingEstimate.remaining(done: 3, total: 12, perPiece: 70) == 9 * 70 + ProcessingEstimate.summarySeconds)
        #expect(ProcessingEstimate.remaining(done: 12, total: 12, perPiece: 70, summaryLeft: false) == 0)
    }

    @Test func measuredSpeedNeedsAPiece() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(ProcessingEstimate.measured(piecesDone: 0, since: start, now: start.addingTimeInterval(100)) == nil)
        #expect(ProcessingEstimate.measured(piecesDone: 2, since: start, now: start.addingTimeInterval(100)) == 50)
    }

    @Test func remembersAndMixesTheSpeed() throws {
        let defaults = try #require(UserDefaults(suiteName: "meetings-test-\(UUID().uuidString)"))
        #expect(ProcessingEstimate.perPiece(.localGPU, defaults: defaults) == 70)
        ProcessingEstimate.remember(40, for: .localGPU, defaults: defaults)
        #expect(ProcessingEstimate.perPiece(.localGPU, defaults: defaults) == 40)
        ProcessingEstimate.remember(60, for: .localGPU, defaults: defaults)
        #expect(ProcessingEstimate.perPiece(.localGPU, defaults: defaults) == 50)
        #expect(ProcessingEstimate.perPiece(.cloud, defaults: defaults) == 12)
    }

    @Test func wayFollowsTheSettings() {
        var settings = MeetingsSettings()
        #expect(ProcessingEstimate.Way(settings) == .cloud)
        settings.transcription = .local
        #expect(ProcessingEstimate.Way(settings) == .localGPU)
        settings.localGPU = false
        #expect(ProcessingEstimate.Way(settings) == .localCPU)
    }

    @Test func text() {
        #expect(ProcessingEstimate.text(20) == "≈ 1 min")
        #expect(ProcessingEstimate.text(390) == "≈ 7 min")
        #expect(ProcessingEstimate.text(4200) == "≈ 1 h 10 min")
    }
}
