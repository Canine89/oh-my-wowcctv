import Carbon
import AppKit

/// 접근성 권한 없이 동작하는 시스템 전역 단축키 (Carbon RegisterEventHotKey).
/// 전체화면 게임이 포커스를 가지고 있어도 잡힌다.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandlerInstalled = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32

    static let signature: OSType = 0x43435456 // "CCTV"

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        var hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else { return nil }
        ref = newRef
        Self.handlers[id] = action
        _ = hotKeyID
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers.removeValue(forKey: id)
    }

    private static func installHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if hotKeyID.signature == HotKey.signature, let action = HotKey.handlers[hotKeyID.id] {
                DispatchQueue.main.async { action() }
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)
    static let keyR = UInt32(kVK_ANSI_R)
}
