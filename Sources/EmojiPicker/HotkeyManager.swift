import Carbon.HIToolbox
import Foundation
import PickerCore

struct HotkeyError: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus
    var description: String { "\(operation) failed with OSStatus \(status)" }
}

/// Registers one global hotkey via Carbon. Re-registering replaces the previous one.
@MainActor
final class HotkeyManager {
    private static let signature: OSType = 0x454D_4A50 // 'EMJP'
    /// Receives the `mach_absolute_time()` captured first thing inside the Carbon handler.
    private let onPress: @MainActor (UInt64) -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// The shortcut currently registered (nil when none is).
    private(set) var current: Shortcut?
    /// While true, presses are ignored (the Settings recorder is listening for a new combo).
    var isPaused = false

    init(onPress: @escaping @MainActor (UInt64) -> Void) {
        self.onPress = onPress
    }

    /// Replaces the registered shortcut. Atomic from the caller's view: if `s` can't be
    /// registered, the previous shortcut is restored before the error is thrown.
    func register(_ s: Shortcut) throws {
        try installHandlerIfNeeded()
        let previous = current
        unregister()
        do {
            try registerNow(s)
        } catch {
            if let previous { try? registerNow(previous) }
            throw error
        }
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        current = nil
    }

    private func registerNow(_ s: Shortcut) throws {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { throw HotkeyError(operation: "RegisterEventHotKey", status: status) }
        hotKeyRef = ref
        current = s
    }

    private func installHandlerIfNeeded() throws {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                let pressTime = mach_absolute_time()
                guard let userData else { return OSStatus(eventNotHandledErr) }
                // Application event target is dispatched on the main thread.
                MainActor.assumeIsolated {
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                    if !manager.isPaused { manager.onPress(pressTime) }
                }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &ref)
        guard status == noErr else { throw HotkeyError(operation: "InstallEventHandler", status: status) }
        handlerRef = ref
    }
}
