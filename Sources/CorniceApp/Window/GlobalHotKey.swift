import AppKit
import Carbon.HIToolbox
import CorniceKit

/// A system-wide keyboard shortcut.
///
/// Uses Carbon's `RegisterEventHotKey` rather than
/// `NSEvent.addGlobalMonitorForEvents`. The monitor approach requires
/// Accessibility permission — the same permission that lets an app read every
/// keystroke you type — which is a wildly disproportionate thing to ask for in
/// order to open a panel. `RegisterEventHotKey` asks for nothing, because it
/// registers one specific combination with the window server instead of
/// observing all input.
///
/// The Carbon API is old, but it is not deprecated and it remains the only way
/// to get a global hot key without the Accessibility prompt.
@MainActor
final class GlobalHotKey {

    /// ⌥⌘D — "developer". Chosen because it is unclaimed by macOS and by the
    /// editors this app launches.
    static let defaultKeyCode = UInt32(kVK_ANSI_D)
    static let defaultModifiers = UInt32(optionKey | cmdKey)

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: () -> Void

    /// Carbon hands the callback a C function pointer with no context, so the
    /// live instance is reached through a file-scope reference. There is one
    /// hot key in this app, so a registry would be ceremony.
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

    // No `deinit` cleanup: the Carbon handles are non-Sendable and cannot be
    // touched from a nonisolated deinit under strict concurrency. The hot key
    // lives for the lifetime of the app and is released explicitly by
    // `NotchWindowController.tearDown()` on termination, which is a more
    // predictable place for it than object deallocation anyway.
}
