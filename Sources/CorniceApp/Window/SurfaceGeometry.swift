import SwiftUI
import CorniceKit

/// How open the surface is.
///
/// `peek` exists for perceived latency: responding instantly with a small growth
/// and committing to the full panel a moment later feels faster than a dwell
/// timer, even at the same total duration.
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

/// The surface's rectangle, radii, and content boxes for every state.
///
/// The single source of truth for drawing, hit testing and layout. Computing
/// those separately let the interactive region drift out of step with the
/// visible one mid-animation.
///
/// Sizes are expressed as offsets from the *measured* notch rather than as
/// absolutes, because a notch's size in points changes with display scaling.
struct SurfaceGeometry: Equatable {

    /// The measured notch, in screen points.
    let notchSize: CGSize
    /// Corner radius of the hardware cut-out.
    let notchCornerRadius: CGFloat
    /// Full window width, which is fixed.
    let windowWidth: CGFloat

    // MARK: - The measured table
    //
    // Resting  209 × 38  · bottom 10 · flare 0
    // Peek     425 × 48  · bottom 16 · flare 14
    // Activity 425 × 54  · bottom 20 · flare 16
    // Expanded 604 × 226 · bottom 28 · flare 24

    /// How far peek and activity grow on each side: 425 − 209, halved.
    static let wing: CGFloat = 108

    /// The activity band is wider than peek because its content has to live
    /// entirely in the two margins. At peek's width the margin is 70 pt, and a
    /// device name plus a glyph does not fit in 70 pt, so the name ran under the
    /// notch where nothing can be seen. Margin width is `wing - flare - padding`,
    /// so this gives 132 pt a side.
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

    /// First clear row below the band, for tall surfaces. 58 in the handoff.
    static let contentTop: CGFloat = 58
    /// Horizontal padding from the *body*'s edge, inside the flare. 22 in the handoff.
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

    /// Bottom-corner radius for a state.
    ///
    /// Grows with the surface so the silhouette stays proportionate; a notch
    /// radius on a 604-point panel would look like a rectangle, and a panel
    /// radius on the collapsed notch would not match the hardware.
    func bottomRadius(for state: SurfaceState) -> CGFloat {
        switch state {
        case .collapsed: notchCornerRadius
        case .peek: notchCornerRadius + 6
        case .activity: notchCornerRadius + 10
        case .expanded: notchCornerRadius + 18
        case .hud(let kind): kind.bottomRadius
        }
    }

    /// The concave cove where the surface is wider than the notch.
    ///
    /// Zero when collapsed, at notch width there is nothing to grow out of,
    /// and a cove would put a visible notch in the hardware notch.
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

    /// The full width minus a cove on each side.
    ///
    /// The cove is a corner treatment, but the vertical sides sit `flare` inboard
    /// for their whole height, so this is the rectangle content must fit.
    func bodyWidth(for state: SurfaceState) -> CGFloat {
        max(0, size(for: state).width - flareRadius(for: state) * 2)
    }

    /// Usable margin on each side of the hole. Nothing drawn inside the notch's
    /// rectangle exists on real hardware, so this is all the room there is.
    func marginWidth(for state: SurfaceState, padding: CGFloat = SurfaceGeometry.contentPadding) -> CGFloat {
        max(0, (bodyWidth(for: state) - notchSize.width) / 2 - padding)
    }

    // MARK: - Placement

    /// The surface's rect inside the window, in SwiftUI's top-left origin space.
    ///
    /// Always anchored to the top edge and horizontally centred, because the
    /// surface is physically attached to the notch.
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

/// Where the album artwork sits, in window coordinates, for each state.
///
/// The artwork exists in every state, so it is drawn once and *moved* rather
/// than drawn three times and cross-faded: SwiftUI interpolates its frame
/// because it is the same view throughout. Offsets are relative to the surface's
/// own left edge, so they survive a differently-sized notch.
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
