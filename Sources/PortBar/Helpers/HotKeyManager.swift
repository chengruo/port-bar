import Foundation
import Carbon
import AppKit

public final class HotKeyManager {
    public static let shared = HotKeyManager()

    public static var onHotKey: (() -> Void)?

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var isRegistered = false

    private init() {}

    /// Registers a global hotkey (default: Option + P)
    public func registerDefaultHotKey() {
        guard !isRegistered else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { (_, event, _) -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            if status == noErr && hotKeyID.signature == 0x50524252 { // 'PRBR'
                DispatchQueue.main.async {
                    HotKeyManager.onHotKey?()
                }
            }
            return noErr
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            print("[HotKeyManager] 安装事件监听失败: \(installStatus)")
            return
        }

        let hotKeyID = EventHotKeyID(signature: 0x50524252, id: 1)
        // Option + P: kVK_ANSI_P (35), optionKey (0x0800)
        let regStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_P),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if regStatus == noErr {
            isRegistered = true
            print("[HotKeyManager] 全局快捷键 Option + P 注册成功！")
        } else {
            print("[HotKeyManager] 注册快捷键失败: \(regStatus)")
        }
    }

    public func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
        isRegistered = false
    }

    deinit {
        unregister()
    }
}
