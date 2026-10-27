import Carbon
import os

/// A system-wide keyboard shortcut. Uses Carbon's RegisterEventHotKey,
/// which needs no Accessibility permission.
final class HotKey {
    private static let log = Logger(subsystem: "VoiceNotes", category: "hotkey")
    private var ref: EventHotKeyRef?
    private static var handler: (() -> Void)?

    /// Whether macOS accepted the shortcut (it fails if the combination is reserved).
    private(set) var isRegistered = false

    init(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        HotKey.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.log.notice("hotkey pressed")
            HotKey.handler?()
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x564E_4F54), id: 1) // "VNOT"
        let registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                                             GetApplicationEventTarget(), 0, &ref)
        isRegistered = installed == noErr && registered == noErr
        HotKey.log.notice("hotkey handler status \(installed), register status \(registered)")
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}
