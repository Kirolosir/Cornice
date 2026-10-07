import AppKit
import SwiftUI

struct ArtworkAccent: Equatable {
    let color: Color
    let position: UnitPoint
    let weight: Double
}

enum ArtworkPalette {
    private static let sampleSize = 36

    private struct Pool {
        var red: Double = 0
        var green: Double = 0
        var blue: Double = 0
        var count: Double = 0

        var components: [Double] { [red / count, green / count, blue / count] }
        var score: Double {
            let rgb = components
            let brightness = rgb.max() ?? 0
            let saturation = brightness > 0 ? (brightness - (rgb.min() ?? 0)) / brightness : 0
            return count * (0.6 + 0.4 * saturation) * (0.25 + 0.75 * brightness)
        }
        var color: Color {
            let rgb = components
            return Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2], opacity: 1)
        }
    }

    // Keep actual RGB colours, including grey and cream. A saturation floor
    // made muted covers look like the same handful of bright albums.
    static func accents(of image: NSImage) -> [ArtworkAccent] {
        guard let bitmap = downsample(image) else { return [] }
        let step = sampleSize / 3
        var accents: [ArtworkAccent] = []
        for row in 0..<3 {
            for column in 0..<3 {
                var bins: [Int: Pool] = [:]
                for y in row * step..<(row + 1) * step {
                    for x in column * step..<(column + 1) * step {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              color.alphaComponent > 0.5 else { continue }
                        let r = Double(color.redComponent)
                        let g = Double(color.greenComponent)
                        let b = Double(color.blueComponent)
                        let key = min(7, Int(r * 8)) * 64 + min(7, Int(g * 8)) * 8 + min(7, Int(b * 8))
                        var pool = bins[key, default: Pool()]
                        pool.red += r; pool.green += g; pool.blue += b; pool.count += 1
                        bins[key] = pool
                    }
                }
                // Sort the keys too, so ties produce the same palette on every run.
                let ranked = bins.keys.sorted().compactMap { bins[$0] }.sorted { $0.score > $1.score }
                guard let winner = ranked.first else { continue }
                accents.append(ArtworkAccent(
                    color: winner.color,
                    position: UnitPoint(x: (Double(column) + 0.5) / 3, y: (Double(row) + 0.5) / 3),
                    weight: min(1, winner.count / Double(step * step) * 2)
                ))
            }
        }
        var distinct: [ArtworkAccent] = []
        for accent in accents.sorted(by: { $0.weight > $1.weight }) {
            if distinct.allSatisfy({ distance($0.color, accent.color) > 0.14 }) {
                distinct.append(accent)
            }
            if distinct.count == 6 { break }
        }
        return distinct
    }

    static func dominantColor(of image: NSImage) -> Color? { accents(of: image).first?.color }

    // Small glyphs need a brighter version; the backdrop uses the original.
    static func indicatorColor(_ color: Color) -> Color {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(s * 0.85), brightness: Double(max(0.78, b)))
    }

    private static func distance(_ first: Color, _ second: Color) -> Double {
        guard let a = NSColor(first).usingColorSpace(.sRGB),
              let b = NSColor(second).usingColorSpace(.sRGB) else { return 1 }
        return sqrt(pow(Double(a.redComponent - b.redComponent), 2)
                    + pow(Double(a.greenComponent - b.greenComponent), 2)
                    + pow(Double(a.blueComponent - b.blueComponent), 2))
    }

    private static func downsample(_ image: NSImage) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: sampleSize, pixelsHigh: sampleSize,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: sampleSize, height: sampleSize),
                   from: .zero, operation: .copy, fraction: 1)
        return bitmap
    }
}
