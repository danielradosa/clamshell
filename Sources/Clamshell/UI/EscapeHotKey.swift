import Carbon
import AppKit

final class EscapeHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?

    private static var active: EscapeHotKey?

    var isArmed: Bool { hotKeyRef != nil }

    func arm(onPress: @escaping () -> Void) {
        guard hotKeyRef == nil else { return }
        self.onPress = onPress
        Self.active = self

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == EscapeHotKey.signature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { EscapeHotKey.active?.onPress?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        var id = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        _ = id
    }

    func disarm() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        onPress = nil
        if Self.active === self { Self.active = nil }
    }

    deinit { disarm() }

    private static let signature = OSType(0x434C4D53)
}
