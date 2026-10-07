import AppKit
import CorniceKit

@MainActor
extension Probes {
    static func probeAppearance() async {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { print("FAIL: \(message)"); exit(1) }
            print("PASS: \(message)")
        }
        func cover(_ colors: [NSColor]) -> NSImage {
            let image = NSImage(size: NSSize(width: 120, height: 120))
            image.lockFocus()
            for (index, color) in colors.enumerated() {
                color.setFill()
                NSRect(x: index * 120 / colors.count, y: 0,
                       width: 120 / colors.count, height: 120).fill()
            }
            image.unlockFocus()
            return image
        }
        func rgb(_ image: NSImage) -> NSColor {
            NSColor(ArtworkPalette.accents(of: image).first!.color).usingColorSpace(.sRGB)!
        }
        let grey = rgb(cover([NSColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1)]))
        check(grey.saturationComponent < 0.02, "grey artwork stays neutral")
        let cream = rgb(cover([NSColor(srgbRed: 0.9, green: 0.8, blue: 0.65, alpha: 1)]))
        check(abs(cream.redComponent - 0.9) < 0.03 && abs(cream.blueComponent - 0.65) < 0.03,
              "cream artwork keeps its original RGB colours")
        let dark = rgb(cover([NSColor(srgbRed: 0.15, green: 0.05, blue: 0.05, alpha: 1)]))
        let bright = rgb(cover([NSColor(srgbRed: 0.9, green: 0.3, blue: 0.3, alpha: 1)]))
        check(bright.brightnessComponent - dark.brightnessComponent > 0.6,
              "similar hues keep different brightness instead of sharing a clamped colour")
        let multicolor = cover([.systemRed, .systemGreen, .systemBlue])
        let accents = ArtworkPalette.accents(of: multicolor)
        check(accents.count >= 3, "a cover keeps several distinct colours")
        check(accents == ArtworkPalette.accents(of: multicolor), "palette extraction is deterministic")
        check(!ArtworkPalette.accents(of: cover([.black])).isEmpty, "black artwork has a neutral palette")

        let model = AppModel(services: PreviewServices.container())
        model.applyArtwork(multicolor)
        var palettePreferences = model.preferences
        palettePreferences.tintFromArtwork = false
        model.applyPreferences(palettePreferences)
        check(model.artworkAccents.isEmpty && model.artworkTint == nil, "turning tint off clears it immediately")
        palettePreferences.tintFromArtwork = true
        model.applyPreferences(palettePreferences)
        check(model.artworkAccents == accents, "turning tint on restores the current cover's palette")
        await model.start()
        defer { model.stopRefreshLoops() }
        try? await Task.sleep(for: .seconds(1))
        guard let song = model.media else { check(false, "preview track loads"); exit(1) }
        check(model.indicatorMode == .playback, "confirmed playing song animates with capture off")
        model.playPause()
        try? await Task.sleep(for: .milliseconds(200))
        for _ in 0..<5 {
            model.setHovering(true)
            model.present(.expanded)
            check(model.indicatorMode == .resting, "hovering a paused song leaves the bars at rest")
            model.setHovering(false)
            model.present(.collapsed)
        }
        // Stop the fake player from republishing its playing fixture.
        model.stopRefreshLoops()
        try? await Task.sleep(for: .seconds(9))
        model.present(.expanded)
        check(model.indicatorMode == .resting, "a long pause never starts synthetic motion")
        var preferences = model.preferences
        preferences.audioVisualizerEnabled = true
        model.applyPreferences(preferences)
        model.applyMedia(song.with(state: .playing))
        check(model.indicatorMode == .resting, "unavailable capture never pretends to hear music")
        model.applyVisualizerStatus(.running)
        check(model.indicatorMode == .resting, "a running but silent tap leaves the bars at rest")
        print("Appearance probe passed")
        exit(0)
    }
}
