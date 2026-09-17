import SwiftUI

/// The surface's outline, in every state.
///
/// One shape for collapsed, peek, and expanded, so SwiftUI interpolates the
/// *geometry* between them rather than cross-fading two different views. That
/// is what makes the surface read as a single object changing size instead of
/// one thing replacing another.
///
/// Three corner treatments:
/// - The top edge is flush with the screen, so its corners have no radius.
///   Rounding them would show desktop above the surface.
/// - The bottom corners are convex, matching the hardware cut-out.
/// - Where the surface is wider than the notch, the top corners flare
///   *outward* with a concave curve, so the extra width appears to grow out of
///   the notch rather than being a rectangle stuck beside it.
struct SurfaceShape: InsettableShape {
    var bottomRadius: CGFloat
    var flareRadius: CGFloat
    var inset: CGFloat = 0

    /// Lets SwiftUI animate the outline itself, so corners round out over the
    /// transition instead of snapping at the end of it.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, flareRadius) }
        set {
            bottomRadius = newValue.first
            flareRadius = newValue.second
        }
    }

    func inset(by amount: CGFloat) -> SurfaceShape {
        SurfaceShape(bottomRadius: bottomRadius, flareRadius: flareRadius, inset: inset + amount)
    }

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: inset, dy: 0)
        var path = Path()

        // Clamped so an in-flight animation cannot produce self-intersecting
        // geometry as the surface passes through small sizes.
        let flare = max(0, min(flareRadius, bounds.width / 2))
        let bottom = max(0, min(bottomRadius, min(bounds.height - inset, (bounds.width - 2 * flare) / 2)))

        path.move(to: CGPoint(x: bounds.minX, y: bounds.minY))

        if flare > 0 {
            path.addQuadCurve(
                to: CGPoint(x: bounds.minX + flare, y: bounds.minY + flare),
                control: CGPoint(x: bounds.minX + flare, y: bounds.minY)
            )
        }

        path.addLine(to: CGPoint(x: bounds.minX + flare, y: bounds.maxY - bottom - inset))

        if bottom > 0 {
            path.addQuadCurve(
                to: CGPoint(x: bounds.minX + flare + bottom, y: bounds.maxY - inset),
                control: CGPoint(x: bounds.minX + flare, y: bounds.maxY - inset)
            )
        }

        path.addLine(to: CGPoint(x: bounds.maxX - flare - bottom, y: bounds.maxY - inset))

        if bottom > 0 {
            path.addQuadCurve(
                to: CGPoint(x: bounds.maxX - flare, y: bounds.maxY - bottom - inset),
                control: CGPoint(x: bounds.maxX - flare, y: bounds.maxY - inset)
            )
        }

        path.addLine(to: CGPoint(x: bounds.maxX - flare, y: bounds.minY + flare))

        if flare > 0 {
            path.addQuadCurve(
                to: CGPoint(x: bounds.maxX, y: bounds.minY),
                control: CGPoint(x: bounds.maxX - flare, y: bounds.minY)
            )
        }

        path.closeSubpath()
        return path
    }
}
