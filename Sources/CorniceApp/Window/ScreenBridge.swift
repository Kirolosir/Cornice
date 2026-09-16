import AppKit
import CorniceKit

/// Converts `NSScreen` into the plain-value `ScreenMetrics` the resolver works on.
///
/// This is the only place in the app that reads `NSScreen`. Keeping it to one
/// small function is what allows every interesting display configuration to be
/// covered by unit tests, since `NSScreen` cannot be constructed.
enum ScreenBridge {

    static func metrics(for screen: NSScreen) -> ScreenMetrics {
        ScreenMetrics(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            backingScaleFactor: screen.backingScaleFactor,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            isBuiltIn: isBuiltIn(screen),
            localizedName: screen.localizedName
        )
    }

    static func allMetrics() -> [ScreenMetrics] {
        NSScreen.screens.map(metrics(for:))
    }

    /// Finds the `NSScreen` matching a resolved profile.
    ///
    /// Matched by frame rather than by index: `NSScreen.screens` reorders when
    /// displays are attached or the arrangement changes, so an index captured a
    /// moment ago can refer to a different display by the time it is used.
    static func screen(matching frame: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame == frame } ?? NSScreen.main
    }

    /// Whether this is the laptop's own panel.
    ///
    /// `CGDisplayIsBuiltin` needs the display ID, which lives in the screen's
    /// device description under a key with no typed accessor.
    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }
}
