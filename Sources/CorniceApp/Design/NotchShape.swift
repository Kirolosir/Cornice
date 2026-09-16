import SwiftUI

/// The collapsed surface's outline.
///
/// Three distinct corner treatments, which is what makes it read as part of the
/// hardware rather than as a floating pill:
///
/// - The top edge is flush with the screen, so its corners have no radius at
///   all. A rounded top corner would show desktop wallpaper above it.
/// - The bottom corners are convex, matching the notch cut-out.
/// - Where the surface is wider than the notch, the top corners flare *outward*
///   with a concave curve, so the extra width appears to grow out of the notch
///   instead of being a rectangle stuck beside it. This is the detail that most
///   distinguishes a considered notch shape from a rounded rectangle.
struct NotchShape: Shape {
    /// Convex radius of the two bottom corners.
    var bottomRadius: CGFloat
    /// Concave radius of the outward flare at the top. Zero collapses the shape
    /// to a plain bottom-rounded rectangle, which is correct when the surface
    /// is exactly notch-width.
    var flareRadius: CGFloat

    /// Lets SwiftUI interpolate the outline itself during expand/collapse, so
    /// the corners round out over the animation rather than snapping at the end.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, flareRadius) }
        set {
            bottomRadius = newValue.first
            flareRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        // Clamp so an animation passing through a small size cannot produce
        // self-intersecting geometry.
        let flare = max(0, min(flareRadius, width / 2))
        let bottom = max(0, min(bottomRadius, min(height, (width - 2 * flare) / 2)))

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Concave flare down into the body on the left.
        if flare > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + flare, y: rect.minY + flare),
                control: CGPoint(x: rect.minX + flare, y: rect.minY)
            )
        }

        path.addLine(to: CGPoint(x: rect.minX + flare, y: rect.maxY - bottom))

        if bottom > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + flare + bottom, y: rect.maxY),
                control: CGPoint(x: rect.minX + flare, y: rect.maxY)
            )
        }

        path.addLine(to: CGPoint(x: rect.maxX - flare - bottom, y: rect.maxY))

        if bottom > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - flare, y: rect.maxY - bottom),
                control: CGPoint(x: rect.maxX - flare, y: rect.maxY)
            )
        }

        path.addLine(to: CGPoint(x: rect.maxX - flare, y: rect.minY + flare))

        if flare > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY),
                control: CGPoint(x: rect.maxX - flare, y: rect.minY)
            )
        }

        path.closeSubpath()
        return path
    }
}

/// The expanded panel's outline: rounded on all four corners, using the
/// continuous (squircle) curve macOS uses for its own large surfaces.
///
/// `InsettableShape` rather than plain `Shape` so the border can be drawn with
/// `strokeBorder`, which insets by half the line width. A plain `stroke`
/// straddles the path, so half of every border pixel falls outside the fill and
/// the panel's edge reads as soft rather than crisp.
struct PanelShape: InsettableShape {
    var cornerRadius: CGFloat
    var inset: CGFloat = 0

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: inset, dy: inset)
        let radius = min(cornerRadius - inset, min(bounds.width, bounds.height) / 2)
        return RoundedRectangle(cornerRadius: max(0, radius), style: .continuous).path(in: bounds)
    }

    func inset(by amount: CGFloat) -> PanelShape {
        PanelShape(cornerRadius: cornerRadius, inset: inset + amount)
    }
}
