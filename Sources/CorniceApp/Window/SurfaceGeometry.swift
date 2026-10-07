import SwiftUI
import CorniceKit

/// The panel's current state. Peek gives feedback while waiting for the configured hover
/// delay.
enum SurfaceState: Equatable, Sendable {
    case collapsed
    case peek
    /// A transient announcement. A wireless device connecting, for instance.
    /// Sized like peek but a little taller, and driven by an event rather than
    /// by the pointer.
    case activity
    case expanded
    /// A system notification, at whatever size that notification needs.
    case hud(HUDKind)

    var isOpen: Bool { self == .expanded }

    /// Whether the state was entered by the app rather than by the pointer.
    /// Hover must not silently cancel these.
    var isTransient: Bool {
        switch self {
        case .activity, .hud: true
        case .collapsed, .peek, .expanded: false
        }
    }

    var hud: HUDKind? {
        if case .hud(let kind) = self { return kind }
        return nil
    }
}

/// Shared sizes for drawing and input. Most sizes are offsets from the measured notch so
/// display scaling doesn't move content into the cutout.
struct SurfaceGeometry: Equatable {

    /// The measured notch, in screen points.
    let notchSize: CGSize
    /// Corner radius of the hardware cut-out.
    let notchCornerRadius: CGFloat
    /// Full window width, which is fixed.
    let windowWidth: CGFloat

    // MARK: - Layout sizes

    /// How far peek grows on each side of the notch.
    static let wing: CGFloat = 108

    /// Leave enough width for a device name and icon on each side. The usable margin is
    /// wing minus flare minus padding.
    static let activityWing: CGFloat = 170
    /// How much taller peek is than the notch: 48 − 38.
    static let peekDrop: CGFloat = 10
    /// How much taller an activity pill is than the notch: 54 − 38.
    static let activityDrop: CGFloat = 16
    /// Overall width of the expanded panel, including the flared shoulders.
    static let expandedWidth: CGFloat = 604
    /// Height of the expanded panel below the notch band: 226 − 38.
    static let expandedDrop: CGFloat = 188

    /// The band across the top of any surface taller than the notch. Its middle
    /// is the hole, so content lives in the two margins or below the band.
    var bandHeight: CGFloat { notchSize.height }

    /// First content row below the notch band.
    static let contentTop: CGFloat = 58
    /// Padding inside the panel shoulders.
    static let contentPadding: CGFloat = 22

    init(notchSize: CGSize, notchCornerRadius: CGFloat, windowWidth: CGFloat) {
        self.notchSize = notchSize
        self.notchCornerRadius = notchCornerRadius
        self.windowWidth = windowWidth
    }

    /// Size of the surface in a given state.
    func size(for state: SurfaceState) -> CGSize {
        switch state {
        case .collapsed:
            CGSize(width: notchSize.width, height: notchSize.height)
        case .peek:
            CGSize(width: notchSize.width + Self.wing * 2, height: notchSize.height + Self.peekDrop)
        case .activity:
            CGSize(
                width: min(notchSize.width + Self.activityWing * 2, windowWidth),
                height: notchSize.height + Self.activityDrop
            )
        case .expanded:
            CGSize(
                width: min(Self.expandedWidth, windowWidth),
                height: notchSize.height + Self.expandedDrop
            )
        case .hud(let kind):
            CGSize(
                width: min(notchSize.width + kind.wing * 2, windowWidth),
                height: notchSize.height + kind.drop
            )
        }
    }

    /// Increase the bottom radius as the panel grows. The collapsed state uses the hardware
    /// notch's radius.
    func bottomRadius(for state: SurfaceState) -> CGFloat {
        switch state {
        case .collapsed: notchCornerRadius
        case .peek: notchCornerRadius + 6
        case .activity: notchCornerRadius + 10
        case .expanded: notchCornerRadius + 18
        case .hud(let kind): kind.bottomRadius
        }
    }

    /// The inward curve at each shoulder. No flare is needed at the resting notch width.
    func flareRadius(for state: SurfaceState) -> CGFloat {
        switch state {
        case .collapsed: 0
        case .peek: 14
        case .activity: 16
        case .expanded: 24
        case .hud(let kind): kind.flareRadius
        }
    }

    // MARK: - Content boxes

    /// Content width after removing the shoulder flare on both sides.
    func bodyWidth(for state: SurfaceState) -> CGFloat {
        max(0, size(for: state).width - flareRadius(for: state) * 2)
    }

    /// Usable margin on each side of the hole. Nothing drawn inside the notch's
    /// rectangle exists on real hardware, so this is all the room there is.
    func marginWidth(for state: SurfaceState, padding: CGFloat = SurfaceGeometry.contentPadding) -> CGFloat {
        max(0, (bodyWidth(for: state) - notchSize.width) / 2 - padding)
    }

    // MARK: - Placement

    /// Center the panel horizontally and pin it to the top. Coordinates here use SwiftUI's
    /// top-left origin.
    func rect(for state: SurfaceState) -> CGRect {
        let size = size(for: state)
        return CGRect(x: (windowWidth - size.width) / 2, y: 0, width: size.width, height: size.height)
    }

    /// Left edge of the hole, in window coordinates.
    var notchLeft: CGFloat { (windowWidth - notchSize.width) / 2 }

    /// The same rect in AppKit's bottom-left origin space, for hit testing.
    func appKitRect(for state: SurfaceState, windowHeight: CGFloat) -> CGRect {
        let rect = rect(for: state)
        return CGRect(x: rect.minX, y: windowHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Starting a hover requires the measured notch bounds. Peek keeps the same
    /// target so moving into its wings does not complete the opening gesture.
    func hoverRect(for state: SurfaceState, windowHeight: CGFloat) -> CGRect {
        let target: SurfaceState = state == .peek ? .collapsed : state
        let rect = appKitRect(for: target, windowHeight: windowHeight)
        // CGRect excludes its maximum edge. Extend only above the screen so
        // resting on the top edge still counts, without widening the target.
        return CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.height + 1
        )
    }

    /// Height for the tallest possible state plus its shadow. Computed across
    /// every state, because a HUD may be taller than the panel.
    var windowHeight: CGFloat {
        let tallest = HUDKind.allCases.map(\.drop).max() ?? 0
        return notchSize.height + max(Self.expandedDrop, tallest) + 60
    }

    /// The widest the surface can become, which is what the window has to hold.
    static var widestSurface: CGFloat {
        max(expandedWidth, (HUDKind.allCases.map(\.wing).max() ?? 0) * 2 + 209)
    }
}

/// Artwork positions relative to the panel. Draw it once and move its frame between states
/// so it doesn't fade between separate copies.
struct ArtworkPlacement: Equatable {
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var cornerRadius: CGFloat

    static func forState(_ state: SurfaceState, geometry: SurfaceGeometry) -> ArtworkPlacement {
        let left = geometry.rect(for: state).minX
        switch state {
        case .collapsed:
            // Outside the surface entirely: at rest the surface *is* the hole,
            // so the thumbnail sits in the menu bar to the left of it.
            return ArtworkPlacement(x: left - 30, y: 9, size: 20, cornerRadius: 4)
        case .peek, .activity, .hud:
            return ArtworkPlacement(x: left + 21.5, y: 7, size: 34, cornerRadius: 8)
        case .expanded:
            return ArtworkPlacement(x: left + 45.5, y: 58, size: 58, cornerRadius: 13)
        }
    }
}
