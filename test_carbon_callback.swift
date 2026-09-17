import Carbon
import AppKit

final class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    var handler: (() -> Void)?

    func start() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        InstallApplicationEventHandler({ (nextHandler, theEvent, userData) -> OSStatus in
            HotKeyManager.shared.handler?()
            return noErr
        }, 1, &eventType, nil, nil)
        
        var hotKeyID = EventHotKeyID(signature: 0x50524252, id: 1)
        // Option + P: kVK_ANSI_P is 0x23 (35), optionKey is 0x0800
        let res = RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        print("Registered hotkey Option+P:", res == noErr)
    }
}

let m = HotKeyManager.shared
m.handler = { print("HotKey Triggered!") }
m.start()
