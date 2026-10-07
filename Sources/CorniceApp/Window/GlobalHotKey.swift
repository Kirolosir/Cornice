import AppKit
import Carbon.HIToolbox
import CorniceKit

/// Register Option-Command-D with Carbon. This gives us one global shortcut without
/// monitoring the user's keystrokes or asking for Accessibility access.
@MainActor
final class GlobalHotKey {

    /// ⌥⌘D. "developer". Chosen because it is unclaimed by macOS and by the
    /// editors this app launches.
    static let defaultKeyCode = UInt32(kVK_ANSI_D)
    static let defaultModifiers = UInt32(optionKey | cmdKey)

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: () -> Void

    /// The C callback looks up the live instance here. The app only registers one shortcut.
    private static var current: GlobalHotKey?

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    /// Registers the shortcut. Returns false if another app already owns it.
    @discardableResult
    func register(
        keyCode: UInt32 = GlobalHotKey.defaultKeyCode,
        modifiers: UInt32 = GlobalHotKey.defaultModifiers
    ) -> Bool {
        unregister()
        Self.current = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var identifier = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
                )
                guard identifier.signature == GlobalHotKey.signature else { return noErr }
                // Carbon delivers on the main thread, but the compiler cannot
                // know that from a C callback.
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.current?.handler() } }
                return noErr
            },
            1, &eventType, nil, &eventHandler
        )
        guard installStatus == noErr else {
            Log.app.error("could not install hot key handler: \(installStatus)")
            return false
        }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard status == noErr else {
            // Most often `eventHotKeyExistsErr`: another app claimed it first.
            Log.app.notice("hot key unavailable (status \(status)); another app may have claimed it")
            return false
        }
        Log.app.notice("registered global hot key")
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        if Self.current === self { Self.current = nil }
    }

    /// Four-character code identifying this app's hot keys.
    private static let signature: OSType = {
        let characters = "CRNC".utf8.prefix(4)
        return characters.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
    }()

    // Release the Carbon handles in tearDown. Their non-Sendable types can't be used from a
    // nonisolated deinit.
}
