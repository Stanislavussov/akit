import Carbon.HIToolbox
import Foundation

/// M31: a hotkey that works in every app (Carbon's RegisterEventHotKey: no Accessibility
/// permission). One per process; ⌥⌘R by default.
@MainActor public final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void
    nonisolated(unsafe) private static var current: GlobalHotKey?

    /// Nil when the key is taken by another app or Carbon refuses it.
    public init?(keyCode: UInt32 = UInt32(kVK_ANSI_R), modifiers: UInt32 = UInt32(cmdKey | optionKey), action: @escaping @MainActor () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalHotKey.current?.action() }
            return noErr
        }, 1, &spec, nil, &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4D54_4E47), id: 1) // "MTNG"
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
        GlobalHotKey.current = self
    }

    public func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        if GlobalHotKey.current === self { GlobalHotKey.current = nil }
    }
}
