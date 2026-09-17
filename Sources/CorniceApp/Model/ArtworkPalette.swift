import AppKit
import SwiftUI

/// Extracts a tint colour from album artwork.
///
/// The surface picks up a hint of the current cover, the way Apple's own media
/// UIs do. Two rules make the difference between that looking considered and
/// looking like a colour accident:
///
/// - **Saturation is enforced.** Averaging an image usually lands on a muddy
///   grey-brown, because opposing hues cancel. Weighting by saturation finds
///   the colour a person would say the cover *is*.
/// - **Brightness is bounded.** The tint sits behind white text on a near-black
///   surface, so an unclamped bright yellow would make the title unreadable.
///   Contrast is not negotiable for a decorative flourish.
enum ArtworkPalette {

    /// Downsample size. Sixteen pixels square is plenty to find a dominant hue
    /// and keeps this to a fraction of a millisecond — it runs on every track
    /// change, and the answer is a single colour.
    private static let sampleSize = 16

    static func dominantColor(of image: NSImage) -> Color? {
        guard let bitmap = downsample(image) else { return nil }

        var bestScore: CGFloat = -1
        var best: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat)?

        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }

                var hue: CGFloat = 0, saturation: CGFloat = 0
                var brightness: CGFloat = 0, alpha: CGFloat = 0
                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                guard alpha > 0.5 else { continue }

                // Ignore near-black and near-white pixels: they carry no hue,
                // and most covers have a lot of both.
                guard brightness > 0.15, brightness < 0.95, saturation > 0.15 else { continue }

                // Favour saturated, mid-bright pixels.
                let score = saturation * (1 - abs(brightness - 0.6))
                if score > bestScore {
                    bestScore = score
                    best = (hue, saturation, brightness)
                }
            }
        }

        guard let best else { return nil }

        return Color(
            hue: Double(best.hue),
            // Clamped so the tint reads as a tint rather than a colour wash.
            saturation: Double(min(best.saturation, 0.75)),
            brightness: Double(min(max(best.brightness, 0.45), 0.72))
        )
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
