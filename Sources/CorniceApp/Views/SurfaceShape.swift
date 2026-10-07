import SwiftUI

/// A cubic Bezier approximation of a quarter circle. This avoids addArc's direction
/// changing in flipped coordinates.
private let quarterCircleKappa: CGFloat = 0.5522847498

/// The same outline for every state: square top corners, rounded bottom corners and concave
/// shoulders. With zero flare it becomes the resting notch shape.
struct SurfaceShape: InsettableShape {
    var bottomRadius: CGFloat
    var flareRadius: CGFloat
    var inset: CGFloat = 0

    /// Lets SwiftUI animate the outline itself, so the corners round out over
    /// the transition instead of snapping at the end of it.
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
        // Inset horizontally and along the bottom only. Insetting the top would
        // pull the surface away from the screen edge, which is the one thing
        // that must never happen.
        let bounds = CGRect(
            x: rect.minX + inset,
            y: rect.minY,
            width: max(0, rect.width - inset * 2),
            height: max(0, rect.height - inset)
        )

        // Clamped so an in-flight animation cannot produce self-intersecting
        // geometry as the surface passes through small sizes.
        let flare = max(0, min(flareRadius, min(bounds.width / 2, bounds.height)))
        let bottom = max(0, min(bottomRadius, min(bounds.height, (bounds.width - 2 * flare) / 2)))

        let bodyMinX = bounds.minX + flare
        let bodyMaxX = bounds.maxX - flare
        let kf = quarterCircleKappa * flare
        let kb = quarterCircleKappa * bottom

        var path = Path()
        path.move(to: CGPoint(x: bounds.minX, y: bounds.minY))

        // Left cove: both control points pull toward the cove square's top-right
        // corner, which is what bends the curve away from the body.
        if flare > 0 {
            path.addCurve(
                to: CGPoint(x: bodyMinX, y: bounds.minY + flare),
                control1: CGPoint(x: bounds.minX + kf, y: bounds.minY),
                control2: CGPoint(x: bodyMinX, y: bounds.minY + flare - kf)
            )
        }

        path.addLine(to: CGPoint(x: bodyMinX, y: bounds.maxY - bottom))

        if bottom > 0 {
            path.addCurve(
                to: CGPoint(x: bodyMinX + bottom, y: bounds.maxY),
                control1: CGPoint(x: bodyMinX, y: bounds.maxY - bottom + kb),
                control2: CGPoint(x: bodyMinX + bottom - kb, y: bounds.maxY)
            )
        }

        path.addLine(to: CGPoint(x: bodyMaxX - bottom, y: bounds.maxY))

        if bottom > 0 {
            path.addCurve(
                to: CGPoint(x: bodyMaxX, y: bounds.maxY - bottom),
                control1: CGPoint(x: bodyMaxX - bottom + kb, y: bounds.maxY),
                control2: CGPoint(x: bodyMaxX, y: bounds.maxY - bottom + kb)
            )
        }

        path.addLine(to: CGPoint(x: bodyMaxX, y: bounds.minY + flare))

        // Right cove, mirrored.
        if flare > 0 {
            path.addCurve(
                to: CGPoint(x: bounds.maxX, y: bounds.minY),
                control1: CGPoint(x: bodyMaxX, y: bounds.minY + flare - kf),
                control2: CGPoint(x: bounds.maxX - kf, y: bounds.minY)
            )
        }

        path.closeSubpath()
        return path
    }
}

/// Mask the camera cutout back to black when the expanded panel uses a light background.
struct NotchHoleShape: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = max(0, min(cornerRadius, min(rect.width / 2, rect.height)))
        let k = quarterCircleKappa * radius

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        if radius > 0 {
            path.addCurve(
                to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                control1: CGPoint(x: rect.minX, y: rect.maxY - radius + k),
                control2: CGPoint(x: rect.minX + radius - k, y: rect.maxY)
            )
        }
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        if radius > 0 {
            path.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
                control1: CGPoint(x: rect.maxX - radius + k, y: rect.maxY),
                control2: CGPoint(x: rect.maxX, y: rect.maxY - radius + k)
            )
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
