import SwiftUI
import CorniceKit

/// Album art that pulses with the beat.
///
/// A thin wrapper whose only job is to read `levels` here, in a leaf, rather
/// than in the view that positions it. Read higher up, every analysed frame
/// invalidated the whole surface.
struct PulsingArtwork: View {
    @Bindable var model: AppModel
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ArtworkThumbnail(
            image: model.artwork,
            size: size,
            cornerRadius: cornerRadius,
            beatIntensity: model.indicatorMode == .spectrum ? model.levels.beatIntensity : 0
        )
    }
}

/// Album art, with a placeholder that never leaves an empty hole.
struct ArtworkThumbnail: View {
    let image: NSImage?
    let size: CGFloat
    var cornerRadius: CGFloat = 8
    /// Scales with the beat when the visualiser is running.
    var beatIntensity: Float = 0

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // A neutral placeholder rather than a coloured one: an invented
                // colour next to real album art looks like a loading failure.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(white: 0.18))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.4, weight: .medium))
                            .foregroundStyle(Color(white: 0.45))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // A restrained pulse: 3% at full beat. Anything larger turns album art
        // into a throbbing distraction two feet from your eyes.
        .scaleEffect(1 + CGFloat(beatIntensity) * 0.03)
        .animation(.easeOut(duration: 0.12), value: beatIntensity)
    }
}

/// Six frequency bands, growing around the centre like the Dynamic Island.
struct EqualizerIndicator: View {
    @Bindable var model: AppModel
    let isLive: Bool
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barCount = 6
    private let barHeight: CGFloat = 14
    private let resting: Float = 2.0 / 14.0
    private var mode: AudioIndicatorMode { isLive ? model.indicatorMode : .resting }

    var body: some View {
        // Only use a display clock for the playback indicator shown when audio
        // capture is off. Captured audio already has its own sampling clock.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: mode != .playback || reduceMotion)) { context in
            let heights = heights(at: context.date)
            WaveformBars(heights: heights, tint: tint, height: barHeight)
                .animation(reduceMotion ? nil : .linear(duration: 1.0 / 30), value: heights)
                .accessibilityHidden(true)
        }
    }

    private func heights(at date: Date) -> [Float] {
        guard mode != .resting else { return Array(repeating: resting, count: barCount) }
        if mode == .spectrum {
            return model.levels.barHeights(count: barCount, resting: resting, outputVolume: model.outputVolume)
        }
        guard !reduceMotion else { return Array(repeating: resting, count: barCount) }

        // A playback indicator until capture is enabled. Different periods and
        // phases keep the bars from moving together or restarting on a redraw.
        let periods = [0.83, 1.07, 0.71, 0.97, 0.79, 1.13]
        let time = date.timeIntervalSinceReferenceDate
        return (0..<barCount).map { index in
            let phase = time.truncatingRemainder(dividingBy: periods[index]) / periods[index]
            let wave = Float((sin(phase * 2 * .pi + Double(index) * 0.9) + 1) / 2)
            return resting + (0.86 - resting) * wave
        }
    }
}

struct WaveformBars: View {
    let heights: [Float]
    let tint: Color
    var height: CGFloat = 14

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: 2, height: max(2, CGFloat(heights[index]) * height))
            }
        }
        .frame(width: 2 * CGFloat(heights.count) + 1.5 * CGFloat(max(0, heights.count - 1)), height: height)
    }
}
