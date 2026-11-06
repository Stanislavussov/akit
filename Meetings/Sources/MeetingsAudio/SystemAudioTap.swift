import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// The sound of the whole system (M2): a Core Audio process tap of every process's output
/// (macOS 14.2+), read through a private aggregate device. The tap takes the sound before the
/// output device, so it works with headphones. The first start asks for "System Audio Recording"
/// (Info.plist `NSAudioCaptureUsageDescription`); without it the buffers are silent.
///
/// Two queues: the IOProc runs alone on `ioQueue`; opening, closing and the device listener run on
/// `controlQueue`, so stopping the device never waits for the queue its own IO needs.
final class SystemAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listener: AudioObjectPropertyListenerBlock?
    private let ioQueue = DispatchQueue(label: "meetings.system-tap.io", qos: .userInitiated)
    private let controlQueue = DispatchQueue(label: "meetings.system-tap.control", qos: .userInitiated)
    private var handler: (@Sendable (AVAudioPCMBuffer, UInt64) -> Void)?
    private var problem: (@Sendable (String) -> Void)?

    /// `handler` gets each buffer and the host time of its first frame.
    func start(handler: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void, problem: @escaping @Sendable (String) -> Void) throws {
        self.handler = handler
        self.problem = problem
        try controlQueue.sync { try open() }
        // A new default output (headphones plugged in, AirPods) restarts the tap on it.
        var address = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.restart() }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block)
    }

    func stop() async {
        if let listener {
            var address = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
        }
        listener = nil
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            controlQueue.async {
                self.close()
                done.resume()
            }
        }
        handler = nil
    }

    deinit {
        if let listener {
            var address = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
        }
        close()
    }

    /// On `controlQueue`. A new device can take a moment to settle: a few tries, then a sentence
    /// for the screen. The writer fills the gap with silence.
    private func restart() {
        close()
        for delay in [0.0, 0.3, 0.7, 1.5] {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if (try? open()) != nil { return }
        }
        problem?("The system sound stopped after the output device changed. Stop and Record again to record the other people.")
    }

    private func open() throws {
        do {
            try openParts()
        } catch {
            close()
            throw error
        }
    }

    private func openParts() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Meetings"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create the system audio tap")
        tapID = tap

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = Self.address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &format), "read the tap's format")
        guard let avFormat = AVAudioFormat(streamDescription: &format) else { throw TapError("the tap's format is not usable") }

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meetings Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "create the aggregate device")
        aggregateID = device

        let handler = self.handler
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, ioQueue) { _, input, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: input, deallocator: nil) else { return }
            handler?(buffer, inputTime.pointee.mHostTime)
        }, "attach to the aggregate device")
        procID = proc
        try check(AudioDeviceStart(device, proc), "start the aggregate device")
    }

    private func close() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device), "find the output device")
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddress = Self.address(kAudioDevicePropertyDeviceUID)
        try check(AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &size, &uid), "read the output device's id")
        guard let value = uid?.takeRetainedValue() else { throw TapError("the output device has no id") }
        return value as String
    }
}

struct TapError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw TapError("Could not \(what) (error \(status)).") }
}
