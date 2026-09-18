import AppKit
import SwiftUI

/// One colour taken from the artwork, and where on the cover it came from.
struct ArtworkAccent: Equatable {
    let color: Color
    /// Where in the cover this colour dominates, in unit coordinates. The
    /// surface paints it in the matching corner, so the background is laid out
    /// like the artwork rather than being an average of it.
    let position: UnitPoint
    /// How much of the sampled region it accounted for, 0...1. Drives opacity,
    /// so a colour that covers half the cover carries more of the surface than
    /// one that appears in a corner.
    let weight: Double
}

/// Extracts colour from album artwork.
///
/// A single averaged colour is what makes a tinted surface look generic: every
/// cover collapses to one wash, and two very different albums can produce nearly
/// the same one. This samples the cover by region instead and keeps several
/// colours with their positions, so a sleeve that is red at the top and blue at
/// the bottom paints a surface that is red at the top and blue at the bottom.
///
/// Two rules keep it from looking like an accident:
///
/// - **Saturation is enforced.** Averaging pixels lands on a muddy grey-brown,
///   because opposing hues cancel. Weighting by saturation finds the colour a
///   person would say the cover *is*.
/// - **Brightness is bounded.** The colour sits behind white text on a near-black
///   surface, so an unclamped bright yellow would make the title unreadable.
///   Contrast is not negotiable for a decorative flourish.
enum ArtworkPalette {

    /// Downsample size. Small enough to cost a fraction of a millisecond — this
    /// runs on every track change — and large enough that a region still holds
    /// enough pixels to have a dominant hue.
    private static let sampleSize = 24

    /// The regions sampled, and where each one is painted.
    private static let regions: [(rect: (x: Int, y: Int, width: Int, height: Int), position: UnitPoint)] = [
        ((0, 0, 12, 12), .topLeading),
        ((12, 0, 12, 12), .topTrailing),
        ((0, 12, 12, 12), .bottomLeading),
        ((12, 12, 12, 12), .bottomTrailing),
    ]

    /// Up to four colours with their positions, strongest first.
    static func accents(of image: NSImage) -> [ArtworkAccent] {
        guard let bitmap = downsample(image) else { return [] }

        var accents: [ArtworkAccent] = []
        for region in regions {
            guard let found = dominantHSB(in: bitmap, region: region.rect) else { continue }
            accents.append(
                ArtworkAccent(
                    color: clampedColor(found.hue, found.saturation, found.brightness),
                    position: region.position,
                    weight: found.share
                )
            )
        }

        // Near-identical neighbours add nothing but overdraw, and a cover that is
        // one flat colour should paint one wash rather than four.
        var distinct: [ArtworkAccent] = []
        for accent in accents.sorted(by: { $0.weight > $1.weight }) {
            let isNew = distinct.allSatisfy { existing in
                hueDistance(existing.color, accent.color) > 0.06
            }
            if isNew { distinct.append(accent) }
        }
        return distinct
    }

    /// The single strongest colour, for the base wash and for anything that
    /// needs one colour to stand for the cover.
    static func dominantColor(of image: NSImage) -> Color? {
        accents(of: image).first?.color
    }

    // MARK: - Sampling

    private static func dominantHSB(
        in bitmap: NSBitmapImageRep,
        region: (x: Int, y: Int, width: Int, height: Int)
    ) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, share: Double)? {
        var bestScore: CGFloat = -1
        var best: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat)?
        var considered = 0
        var counted = 0

        for x in region.x..<min(region.x + region.width, bitmap.pixelsWide) {
            for y in region.y..<min(region.y + region.height, bitmap.pixelsHigh) {
                considered += 1
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }

                var hue: CGFloat = 0, saturation: CGFloat = 0
                var brightness: CGFloat = 0, alpha: CGFloat = 0
                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                guard alpha > 0.5 else { continue }

                // Near-black and near-white pixels carry no hue, and most covers
                // have a lot of both — but *white* is the low-saturation case,
                // which the saturation test already catches. A brightness
                // ceiling low enough to matter throws away vivid colour instead:
                // at 0.96 a fully saturated red or yellow was rejected outright,
                // so the most characteristic pixels on a bright cover were the
                // ones never sampled.
                guard brightness > 0.10, saturation > 0.15 else { continue }
                counted += 1

                // Favour saturated, mid-bright pixels: the colour a person would
                // name if asked what the cover looks like.
                let score = saturation * (1 - abs(brightness - 0.6))
                if score > bestScore {
                    bestScore = score
                    best = (hue, saturation, brightness)
                }
            }
        }

        guard let best, considered > 0 else { return nil }
        return (best.hue, best.saturation, best.brightness, Double(counted) / Double(considered))
    }

    /// Clamped so the colour reads as the cover's without putting the surface's
    /// own text at risk.
    private static func clampedColor(
        _ hue: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat
    ) -> Color {
        Color(
            hue: Double(hue),
            // A little more headroom than a single flat wash could afford: these
            // are painted at lower opacity and layered, so the saturation is
            // what carries the cover's character.
            saturation: Double(min(max(saturation, 0.35), 0.92)),
            brightness: Double(min(max(brightness, 0.45), 0.72))
        )
    }

    private static func hueDistance(_ first: Color, _ second: Color) -> CGFloat {
        let one = NSColor(first).usingColorSpace(.deviceRGB)
        let two = NSColor(second).usingColorSpace(.deviceRGB)
        guard let one, let two else { return 1 }
        var h1: CGFloat = 0, s1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var h2: CGFloat = 0, s2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        one.getHue(&h1, saturation: &s1, brightness: &b1, alpha: &a1)
        two.getHue(&h2, saturation: &s2, brightness: &b2, alpha: &a2)
        // Hue is a circle, so 0.95 and 0.02 are neighbours.
        let raw = abs(h1 - h2)
        return min(raw, 1 - raw)
    }

    private static func downsample(_ image: NSImage) -> NSBitmapImageRep? {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: sampleSize,
            pixelsHigh: sampleSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: sampleSize, height: sampleSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        return representation
    }
}
