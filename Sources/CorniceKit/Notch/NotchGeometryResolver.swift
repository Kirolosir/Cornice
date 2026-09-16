import Foundation
import CoreGraphics

/// Works out where the surface should sit on a given display.
///
/// Three paths, tried in order:
///
/// 1. **Measured.** `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` report
///    the usable menu-bar strips either side of the notch. The gap between them
///    *is* the notch, exactly, in the display's current point space. This is
///    available on every notched Mac running macOS 12 or later, so it is the
///    path that runs in practice.
///
/// 2. **Catalog fallback.** Some configurations report a top safe-area inset
///    without the auxiliary areas — notably when a notched panel is mirrored,
///    and on some pre-release OS builds. The inset still gives us an exact
///    notch *height*, so we derive the width from it using a measured aspect
///    ratio rather than inventing a per-model point size.
///
/// 3. **Synthetic centre.** No notch at all: external displays, Intel laptops,
///    desktop Macs. We reserve a notch-shaped region in the middle of the menu
///    bar so the rest of the app is identical on every machine.
///
/// The type is an enum-namespace of static pure functions on purpose: given the
/// same `ScreenMetrics`, it must always produce the same `NotchProfile`, which
/// is what makes the awkward display configurations testable.
public enum NotchGeometryResolver {

    /// Width-to-height ratio of the hardware cut-out, used only by the catalog
    /// fallback path.
    ///
    /// Measured on a MacBook Air (Mac15,12) running a scaled 1710×1112 point
    /// mode: the resolver reported a 209×38 pt notch, giving 5.5. The ratio is
    /// used instead of absolute sizes because it is invariant under display
    /// scaling, which absolute point sizes are not. It is an approximation for
    /// models other than the one measured, which is acceptable because this
    /// path only runs when the exact measurement is unavailable.
    static let fallbackAspectRatio: CGFloat = 5.5

    /// Size of the synthetic region used on displays with no notch, in points.
    /// Chosen to match the visual weight of a real notch at default scaling
    /// rather than to imitate any particular machine.
    static let syntheticSize = CGSize(width: 200, height: 32)

    /// Bottom-corner radius, as a fraction of notch height. The hardware
    /// cut-out's lower corners are close to a quarter of its height.
    static let cornerRadiusRatio: CGFloat = 0.26

    /// Resolves the docking region for a display.
    ///
    /// - Parameter metrics: a snapshot of the display.
    /// - Returns: a profile whose `rect` is in the display's own coordinate
    ///   space, using AppKit's bottom-left origin.
    public static func resolve(_ metrics: ScreenMetrics) -> NotchProfile {
        if let measured = measuredProfile(metrics) { return measured }
        if let fallback = catalogProfile(metrics) { return fallback }
        return syntheticProfile(metrics)
    }

    // MARK: - Path 1: exact measurement

    /// Derives the notch from the gap between the two auxiliary menu-bar areas.
    ///
    /// Returns `nil` when either area is missing, when they are not separated
    /// (no notch), or when the gap is implausible — a display could in principle
    /// report a degenerate or full-width gap, and placing a window across the
    /// whole menu bar would be considerably worse than falling through.
    static func measuredProfile(_ metrics: ScreenMetrics) -> NotchProfile? {
        guard let left = metrics.auxiliaryTopLeftArea,
              let right = metrics.auxiliaryTopRightArea
        else { return nil }

        let gapStart = left.maxX
        let gapEnd = right.minX
        let width = gapEnd - gapStart
        // A notch narrower than a menu-bar item, or wider than a third of the
        // display, is not a notch. Fall through rather than trust it.
        guard width > 40, width < metrics.frame.width / 3 else { return nil }

        // Prefer the safe-area inset for height: it is the value the window
        // server actually uses to lay out the menu bar. The auxiliary areas
        // agree with it in every configuration observed, but the inset is the
        // more direct statement of intent.
        let height = metrics.safeAreaTop > 0 ? metrics.safeAreaTop : left.height
        guard height > 0 else { return nil }

        let rect = CGRect(
            x: metrics.frame.minX + gapStart,
            y: metrics.frame.maxY - height,
            width: width,
            height: height
        )
        return NotchProfile(
            rect: rect,
            cornerRadius: (height * cornerRadiusRatio).rounded(),
            source: .measured,
            screenFrame: metrics.frame,
            hasPhysicalNotch: true,
            widthFraction: metrics.frame.width > 0 ? width / metrics.frame.width : 0
        )
    }

    // MARK: - Path 2: height is known, width is not

    /// Uses the reported safe-area inset as an exact height and derives a width
    /// from `fallbackAspectRatio`.
    static func catalogProfile(_ metrics: ScreenMetrics) -> NotchProfile? {
        let height = metrics.safeAreaTop
        guard height > 0 else { return nil }

        let width = min((height * fallbackAspectRatio).rounded(), metrics.frame.width / 3)
        let rect = CGRect(
            x: metrics.frame.midX - width / 2,
            y: metrics.frame.maxY - height,
            width: width,
            height: height
        )
        return NotchProfile(
            rect: rect,
            cornerRadius: (height * cornerRadiusRatio).rounded(),
            source: .catalogFallback,
            screenFrame: metrics.frame,
            hasPhysicalNotch: true,
            widthFraction: metrics.frame.width > 0 ? width / metrics.frame.width : 0
        )
    }

    // MARK: - Path 3: no notch

    /// Reserves a notch-shaped region centred in the menu bar.
    ///
    /// The height is clamped to the actual menu bar so the collapsed surface
    /// never overhangs it on a display whose menu bar is shorter than our
    /// nominal size — otherwise the surface would cover the top of whatever
    /// window is below it.
    static func syntheticProfile(_ metrics: ScreenMetrics) -> NotchProfile {
        let menuBar = metrics.menuBarHeight
        let height = menuBar > 0 ? min(syntheticSize.height, menuBar) : syntheticSize.height
        let width = min(syntheticSize.width, max(metrics.frame.width / 4, 120))
        let rect = CGRect(
            x: metrics.frame.midX - width / 2,
            y: metrics.frame.maxY - height,
            width: width,
            height: height
        )
        return NotchProfile(
            rect: rect,
            cornerRadius: (height * cornerRadiusRatio).rounded(),
            source: .syntheticCenter,
            screenFrame: metrics.frame,
            hasPhysicalNotch: false,
            widthFraction: metrics.frame.width > 0 ? width / metrics.frame.width : 0
        )
    }

    // MARK: - Display selection

    /// Picks which display the surface should live on.
    ///
    /// Preference order: a built-in display with a real notch, then any display
    /// with a notch, then the built-in display, then the first display given.
    /// Returns `nil` only when handed an empty list, which happens briefly
    /// during display reconfiguration and when the lid is closed on a clamshell
    /// setup with no external display yet attached.
    public static func preferredScreen(from screens: [ScreenMetrics]) -> ScreenMetrics? {
        if let builtInNotched = screens.first(where: { $0.isBuiltIn && $0.safeAreaTop > 0 }) {
            return builtInNotched
        }
        if let notched = screens.first(where: { $0.safeAreaTop > 0 }) { return notched }
        if let builtIn = screens.first(where: \.isBuiltIn) { return builtIn }
        return screens.first
    }
}
