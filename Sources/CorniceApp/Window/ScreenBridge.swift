import AppKit
import CorniceKit

/// Convert NSScreen to plain ScreenMetrics values. Tests can create those values without
/// needing real displays.
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

    /// Match by frame because attaching a display can reorder NSScreen.screens.
    static func screen(matching frame: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame == frame } ?? NSScreen.main
    }

    /// Get the display ID from the device description to check whether this is the built-in
    /// screen.
    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }
}
