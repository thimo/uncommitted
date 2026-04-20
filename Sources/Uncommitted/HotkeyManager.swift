import Carbon
import UncommittedCore

/// Registers a single system-wide hotkey via Carbon's `RegisterEventHotKey`.
/// Carbon is legacy but still the standard approach for menu-bar apps: it
/// intercepts the key before any app sees it (unlike `addGlobalMonitor`
/// which only observes) and doesn't require accessibility permissions
/// (unlike CGEvent taps).
final class HotkeyManager {
    private var handlerRef: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?

    /// Called on the main thread when the registered hotkey fires.
    var onTrigger: (() -> Void)?

    /// Four-character signature identifying our hotkey registration.
    /// "UNCM" → 0x554E434D.
    private static let signature: OSType = 0x554E_434D

    func register(_ shortcut: GlobalShortcut) {
        unregister()

        // 1. Install the Carbon event handler (one-time; handles all
        //    hotkey-pressed events for this app).
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, inEvent, userData) -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                mgr.onTrigger?()
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )
        guard handlerStatus == noErr else {
            handlerRef = nil
            return
        }

        // 2. Register the specific key combo.
        let hotkeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let modifiers = carbonModifiers(for: shortcut)
        let hotkeyStatus = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        if hotkeyStatus != noErr {
            hotkeyRef = nil
        }
    }

    func unregister() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        if let ref = handlerRef {
            RemoveEventHandler(ref)
            handlerRef = nil
        }
    }

    deinit {
        unregister()
    }

    private func carbonModifiers(for shortcut: GlobalShortcut) -> UInt32 {
        var mods: UInt32 = 0
        if shortcut.command { mods |= UInt32(cmdKey) }
        if shortcut.shift   { mods |= UInt32(shiftKey) }
        if shortcut.option  { mods |= UInt32(optionKey) }
        if shortcut.control { mods |= UInt32(controlKey) }
        return mods
    }
}
