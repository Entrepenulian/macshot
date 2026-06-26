import AppKit
import Carbon.HIToolbox

/// System-wide ⌘P / ⌘S hotkeys for the recording controls. Uses Carbon
/// `RegisterEventHotKey`, so the shortcuts fire no matter which app is focused
/// and are *consumed* — they override whatever the focused app binds them to
/// (e.g. ⌘S "Save"). Registered only while recording, then released so normal
/// shortcuts work again. No Accessibility permission required.
final class GlobalHotKeys {
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var onPause: (() -> Void)?
    private var onStop: (() -> Void)?

    private let pauseID: UInt32 = 1
    private let stopID: UInt32 = 2

    func register(onPause: @escaping () -> Void, onStop: @escaping () -> Void) {
        unregister()
        self.onPause = onPause
        self.onStop = onStop

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let me = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
            me.fire(id: hkID.id)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        registerKey(keyCode: UInt32(kVK_ANSI_P), id: pauseID)
        registerKey(keyCode: UInt32(kVK_ANSI_S), id: stopID)
    }

    func unregister() {
        for r in refs { if let r { UnregisterEventHotKey(r) } }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        onPause = nil; onStop = nil
    }

    private func registerKey(keyCode: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4D435350), id: id)   // 'MCSP'
        RegisterEventHotKey(keyCode, UInt32(cmdKey), hkID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    private func fire(id: UInt32) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if id == self.pauseID { self.onPause?() }
            else if id == self.stopID { self.onStop?() }
        }
    }
}
