import SwiftUI
import CorniceKit

/// How open the surface is.
///
/// Three states rather than two, copying the behaviour of Apple's own Dynamic
/// Island. `peek` exists for one reason: perceived latency. If hovering does
/// nothing until a dwell timer fires, the surface feels broken no matter how
/// short the timer is. Responding *instantly* with a small growth, then
/// committing to the full panel a moment later, makes the same total duration
/// feel immediate.
enum SurfaceState: Equatable, Sendable {
    case collapsed
    case peek
    /// A transient announcement — a wireless device connecting, for instance.
    /// Sized like peek, but driven by an event rather than by the pointer.
    case activity
    case expanded

    var isOpen: Bool { self == .expanded }

    /// Whether the state was entered by the app rather than by the pointer.
    /// Hover must not silently cancel these.
    var isTransient: Bool { self == .activity }
}

/// Computes the surface's rectangle for each state.
///
/// Deliberately the single source of truth for both drawing and hit testing.
/// When those two were computed separately, the interactive region drifted out
/// of step with what was on screen during animation — the classic "the button
/// is not where it looks like it is" bug.
struct SurfaceGeometry: Equatable {

    /// The measured notch, in screen points.
    let notchSize: CGSize
    /// Corner radius of the hardware cut-out.
    let notchCornerRadius: CGFloat
    /// Height of the expanded content area, below the notch strip.
    let contentHeight: CGFloat
    /// Full window width, which is fixed.
    let windowWidth: CGFloat

    /// How far the peek state grows on each side.
    ///
    /// Sized so a typical track title and artist fit without being cut to
    /// "Do I Wa…", which is worse than showing nothing.
    static let peekWing: CGFloat = 108
    /// How much taller the peek state is than the notch.
    static let peekDrop: CGFloat = 10
    /// Overall width of the expanded panel, including the flared shoulders.
    ///
    /// The flare is a *corner* treatment, but geometrically it insets the
    /// shape's sides for their whole height, so the usable body is
    /// `expandedWidth - 2 × flareRadius`. This figure is therefore the outer
    /// width; `contentWidth(for:)` is what the layout may actually use.
    static let expandedWidth: CGFloat = 604

    init(
        notchSize: CGSize,
        notchCornerRadius: CGFloat,
        contentHeight: CGFloat,
        windowWidth: CGFloat
    ) {
        self.notchSize = notchSize
        self.notchCornerRadius = notchCornerRadius
        self.contentHeight = contentHeight
        self.windowWidth = windowWidth
    }

    /// Size of the surface in a given state.
    func size(for state: SurfaceState) -> CGSize {
        switch state {
        case .collapsed:
            CGSize(width: notchSize.width, height: notchSize.height)
        case .peek:
            CGSize(
                width: notchSize.width + Self.peekWing * 2,
                height: notchSize.height + Self.peekDrop
            )
        case .activity:
            CGSize(
                width: notchSize.width + Self.peekWing * 2,
                height: notchSize.height + Self.peekDrop + 6
            )
        case .expanded:
            CGSize(
                width: min(Self.expandedWidth, windowWidth - 24),
                height: notchSize.height + contentHeight
            )
        }
    }

    /// Bottom-corner radius for a state.
    ///
    /// Grows with the surface so the silhouette stays proportionate; a notch
    /// radius on a 560-point panel would look like a rectangle, and a panel
    /// radius on the collapsed notch would not match the hardware.
    func bottomRadius(for state: SurfaceState) -> CGFloat {
        switch state {
        case .collapsed: notchCornerRadius
        case .peek: notchCornerRadius + 6
        case .activity: notchCornerRadius + 10
        case .expanded: 28
        }
    }

    /// Concave flare where the surface is wider than the notch.
    ///
    /// Zero when collapsed — at notch width there is nothing to flare out
    /// from, and a flare would put a visible notch in the hardware notch.
    func flareRadius(for state: SurfaceState) -> CGFloat {
        switch state {
        case .collapsed: 0
        case .peek: 14
        case .activity: 16
        case .expanded: 24
        }
    }

    /// Horizontal inset the content must respect in a given state.
    ///
    /// The flare pulls the shape's sides inward, so content laid out to the
    /// full surface width is clipped by exactly that much on each side. Getting
    /// this wrong is invisible until the flare is large — which is how the tab
    /// strip and the timestamps ended up cut off when the shoulders were made
    /// more pronounced.
    func contentInset(for state: SurfaceState) -> CGFloat {
        flareRadius(for: state)
    }

    /// Width available to content, inside the flare.
    func contentWidth(for state: SurfaceState) -> CGFloat {
        max(0, size(for: state).width - contentInset(for: state) * 2)
    }

    /// Width of the region either side of the notch in a wing-shaped state.
    ///
    /// Derived rather than assumed. Laying these out as two fixed `peekWing`
    /// columns plus the notch made the content wider than the surface, so both
    /// sides were silently clipped — which is why the device announcement
    /// rendered as an empty pill.
    func wingWidth(for state: SurfaceState, padding: CGFloat) -> CGFloat {
        let available = contentWidth(for: state) - padding * 2 - notchSize.width
        return max(0, available / 2)
    }

    /// The surface's rect inside the window, in SwiftUI's top-left origin space.
    ///
    /// Always anchored to the top edge and horizontally centred, because the
    /// surface is physically attached to the notch.
    func rect(for state: SurfaceState) -> CGRect {
        let size = size(for: state)
        return CGRect(
            x: (windowWidth - size.width) / 2,
            y: 0,
            width: size.width,
            height: size.height
        )
    }

    /// The same rect in AppKit's bottom-left origin space, for hit testing.
    func appKitRect(for state: SurfaceState, windowHeight: CGFloat) -> CGRect {
        let rect = rect(for: state)
        return CGRect(
            x: rect.minX,
            y: windowHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Margin added around the collapsed surface for *hover* purposes only.
    ///
    /// The drawn shape at rest is exactly the notch, but the notch is a hole in
    /// the display: aiming at it means aiming at nothing, and requiring a hit
    /// inside its exact bounds makes the surface feel like it only opens if you
    /// clip its edge. The hover region is therefore larger than the drawn one —
    /// approaching the notch from any direction opens it, including from
    /// directly below where the pointer is under the cut-out rather than on it.
    static let hoverPadding = CGSize(width: 26, height: 14)

    /// The region that counts as "on the surface" for hover.
    ///
    /// Deliberately distinct from the drawn rect. While resting it is padded;
    /// once open it matches the panel exactly, because a padded region around
    /// an open panel would keep it open while the pointer is clearly elsewhere.
    func hoverRect(for state: SurfaceState, windowHeight: CGFloat) -> CGRect {
        let rect = appKitRect(for: state, windowHeight: windowHeight)
        switch state {
        case .collapsed, .peek, .activity:
            return rect.insetBy(dx: -Self.hoverPadding.width, dy: -Self.hoverPadding.height)
        case .expanded:
            return rect
        }
    }

    /// Total window height needed to contain the largest state plus room for
    /// its shadow.
    var windowHeight: CGFloat {
        size(for: .expanded).height + 60
    }
}
