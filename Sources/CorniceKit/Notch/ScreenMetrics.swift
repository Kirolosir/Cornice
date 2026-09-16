import Foundation
import CoreGraphics

/// A plain-data snapshot of everything `NotchGeometryResolver` needs from a
/// display.
///
/// This exists so notch resolution is a pure function of values rather than a
/// method on `NSScreen`. `NSScreen` cannot be constructed in a unit test — you
/// get whatever displays the test machine happens to have — so all the
/// interesting logic (which is to say, all the ways a display can be weird)
/// would otherwise be untestable. The app layer builds one of these from a real
/// `NSScreen`; tests build them by hand.
public struct ScreenMetrics: Equatable, Sendable {
    /// Full display bounds in points, in AppKit's bottom-left origin space.
    public var frame: CGRect
    /// The area not covered by the menu bar or the Dock, in points.
    public var visibleFrame: CGRect
    /// Points-to-backing-pixels factor. 2.0 on every Retina Mac to date.
    public var backingScaleFactor: CGFloat
    /// `NSScreen.safeAreaInsets.top`. On a notched built-in display this is the
    /// notch height; it is 0 on every external display and on non-notched Macs.
    public var safeAreaTop: CGFloat
    /// `NSScreen.auxiliaryTopLeftArea` — the usable menu-bar strip left of the
    /// notch. `nil` when the display has no notch.
    public var auxiliaryTopLeftArea: CGRect?
    /// `NSScreen.auxiliaryTopRightArea` — the usable strip right of the notch.
    public var auxiliaryTopRightArea: CGRect?
    /// Whether this is the machine's built-in panel rather than an external display.
    public var isBuiltIn: Bool
    /// `NSScreen.localizedName`, for diagnostics only.
    public var localizedName: String

    public init(
        frame: CGRect,
        visibleFrame: CGRect,
        backingScaleFactor: CGFloat,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?,
        isBuiltIn: Bool,
        localizedName: String
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.backingScaleFactor = backingScaleFactor
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
        self.isBuiltIn = isBuiltIn
        self.localizedName = localizedName
    }

    /// Height of the menu bar as currently laid out, in points.
    public var menuBarHeight: CGFloat { frame.maxY - visibleFrame.maxY }
}

/// How a `NotchProfile` was arrived at. Surfaced in the diagnostics panel so a
/// user reporting a placement bug can tell us which path ran.
public enum NotchSource: String, Equatable, Sendable, Codable {
    /// Derived from `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`. Exact.
    case measured
    /// The display reports a top safe-area inset but not the auxiliary areas,
    /// so the width came from the hardware catalog, scaled to this display's
    /// current point resolution.
    case catalogFallback
    /// No notch. The surface is centred in the menu bar instead.
    case syntheticCenter
}

/// The resolved position and shape of the surface's docking area on one display.
public struct NotchProfile: Equatable, Sendable {
    /// The notch cut-out (or, when synthetic, the region we behave as though
    /// were a notch) in points, bottom-left origin, in the screen's coordinate space.
    public var rect: CGRect
    /// Bottom-corner radius that visually matches the hardware cut-out.
    public var cornerRadius: CGFloat
    /// How `rect` was determined.
    public var source: NotchSource
    /// The display this profile describes.
    public var screenFrame: CGRect
    /// Whether the display physically has a notch.
    public var hasPhysicalNotch: Bool
    /// Notch width as a fraction of display width. Scaling-invariant, so it is
    /// the only cross-machine-comparable size figure we have.
    public var widthFraction: CGFloat

    public init(
        rect: CGRect,
        cornerRadius: CGFloat,
        source: NotchSource,
        screenFrame: CGRect,
        hasPhysicalNotch: Bool,
        widthFraction: CGFloat
    ) {
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.source = source
        self.screenFrame = screenFrame
        self.hasPhysicalNotch = hasPhysicalNotch
        self.widthFraction = widthFraction
    }

    /// A one-line summary for the diagnostics panel and for logs.
    public var debugSummary: String {
        String(
            format: "%@ %.0f×%.0f pt (r%.0f) at x=%.0f, %.1f%% of %.0f pt display",
            source.rawValue, rect.width, rect.height, cornerRadius,
            rect.minX, widthFraction * 100, screenFrame.width
        )
    }
}
