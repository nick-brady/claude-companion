import Carbon
import Foundation

/// Global hotkey via Carbon RegisterEventHotKey. Works while other apps are focused and,
/// unlike a CGEventTap, needs no Accessibility permission. Reports press and release
/// so we can do hold-to-talk.
final class HotKey {
    private static var registry: [UInt32: HotKey] = [:]
    private static var handlerInstalled = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    private(set) var registered = false

    /// keyCode: e.g. kVK_Space (49). modifiers: Carbon masks (optionKey, cmdKey, controlKey, shiftKey).
    init(keyCode: UInt32, modifiers: UInt32) {
        HotKey.installHandlerIfNeeded()
        id = HotKey.nextID
        HotKey.nextID += 1
        let hkID = EventHotKeyID(signature: OSType(0x434C_4344), id: id) // 'CLCD'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        registered = (status == noErr)
        HotKey.registry[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.registry[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let kind = GetEventKind(event)
            DispatchQueue.main.async {
                guard let key = HotKey.registry[hk.id] else { return }
                if kind == UInt32(kEventHotKeyPressed) { key.onDown?() } else { key.onUp?() }
            }
            return noErr
        }, 2, &types, nil, nil)
    }
}
