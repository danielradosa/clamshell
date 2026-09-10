import Carbon
import AppKit

/// Registers Escape as a system-wide hot key, for as long as the overlay is up.
///
/// A global `NSEvent` monitor is the obvious way to do this and the wrong one:
/// key events are only delivered to it once the user grants Accessibility
/// access, which is a heavy ask for a cosmetic toggle. Carbon's
/// `RegisterEventHotKey` needs no such grant — verified on macOS 27 with
/// `AXIsProcessTrusted()` returning false and registration still returning
/// `noErr`.
///
/// The catch is that a registered bare Escape is swallowed everywhere for as
/// long as it stays registered, so this is deliberately scoped: it is armed only
/// while the fold is actually on screen, which is a second or two while the lid
/// is moving, and torn down the moment the effect clears.
final class EscapeHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?

    /// Carbon calls back through a C function pointer that cannot capture
    /// context, so the live instance is reached through a file-scope reference.
    /// Only one hot key is ever registered at a time, so a single slot is enough.
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

    /// Four-character code identifying our hot key, so the handler ignores
    /// anything another component registered.
    private static let signature = OSType(0x434C4D53)   // 'CLMS'
}
