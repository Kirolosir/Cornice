import Foundation
import CoreGraphics

/// First measure the gap between the auxiliary menu-bar areas. If only the safe-area height
/// is available, estimate the width. Without a notch, use a centered menu-bar region. Plain
/// ScreenMetrics values make these cases testable.
public enum NotchGeometryResolver {

    /// Approximate width-to-height ratio, used only when exact bounds are unavailable.
    /// Scaling changes point sizes but keeps the ratio.
    static let fallbackAspectRatio: CGFloat = 5.5

    /// Placeholder notch size for displays without a notch, in points.
    static let syntheticSize = CGSize(width: 200, height: 32)

    /// Bottom-corner radius, as a fraction of notch height. The hardware
    /// cut-out's lower corners are close to a quarter of its height.
    static let cornerRadiusRatio: CGFloat = 0.26

    /// Resolve the panel's docking area.
    ///
    /// - Parameter metrics: A snapshot of the display.
    /// - Returns: Bounds in AppKit's bottom-left coordinate space.
    public static func resolve(_ metrics: ScreenMetrics) -> NotchProfile {
        if let measured = measuredProfile(metrics) { return measured }
        if let fallback = catalogProfile(metrics) { return fallback }
        return syntheticProfile(metrics)
    }

    // MARK: - Path 1: exact measurement

    /// Measure the gap between the menu-bar areas. Reject missing, overlapping or
    /// implausibly large bounds and try the fallback.
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

        // Prefer the safe-area inset for height because macOS uses it to place the menu
        // bar.
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

    /// Create a centered region on screens without a notch. Limit its height to the menu
    /// bar so it doesn't cover windows below it.
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

    /// Prefer a notched built-in display, then another notched display, then the built-in
    /// display, then the first available one. An empty list returns nil.
    public static func preferredScreen(from screens: [ScreenMetrics]) -> ScreenMetrics? {
        if let builtInNotched = screens.first(where: { $0.isBuiltIn && $0.safeAreaTop > 0 }) {
            return builtInNotched
        }
        if let notched = screens.first(where: { $0.safeAreaTop > 0 }) { return notched }
        if let builtIn = screens.first(where: \.isBuiltIn) { return builtIn }
        return screens.first
    }
}
