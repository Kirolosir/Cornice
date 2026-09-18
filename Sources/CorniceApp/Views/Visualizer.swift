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
            beatIntensity: model.levels.beatIntensity
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

/// The three-bar playing indicator beside a track title.
///
/// This is a *playing* indicator first and a spectrum second, which is the
/// distinction that decides how it behaves when system audio capture is off:
/// it keeps the standard staggered bob, because what it is reporting then is
/// "this is playing", not "the music sounds like this". When capture is on it
/// is driven by the analyser instead and reports both.
///
/// Sized exactly as the handoff draws it: three 2 pt bars, 2 pt apart, 13 pt
/// tall, standing on their baseline.
struct EqualizerIndicator: View {
    @Bindable var model: AppModel
    /// Whether the track is actually playing. A paused track stands still.
    let isLive: Bool
    let tint: Color
    /// How many bars to draw. The panel has room for more resolution than the
    /// resting strip beside the menu bar clock does.
    var barCount: Int = 3

    @State private var bobbing = false

    private var levels: AudioLevels { model.levels }

    /// Whether the bars follow the analyser or fall back to the standard bob.
    ///
    /// A *stable* answer, not a per-second one: switching between the two
    /// motions is jarring, and the band values already go to zero on their own
    /// when there is nothing to show.
    private var audioDriven: Bool { model.barsFollowAudio }

    /// Deliberately co-prime-ish, so the three bars never fall into step and
    /// start reading as one block moving up and down.
    private static let durations: [Double] = [0.80, 0.93, 1.06, 0.87, 1.00]
    private static let phases: [Double] = [0, 0.17, 0.34, 0.09, 0.26]

    private let barWidth: CGFloat = 2
    private let barHeight: CGFloat = 13
    private let resting: CGFloat = 0.3

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: barWidth, height: barHeight)
                    .scaleEffect(y: scale(at: index), anchor: .bottom)
                    .animation(animation(at: index), value: animationKey(at: index))
            }
        }
        .frame(
            width: barWidth * CGFloat(barCount) + 2 * CGFloat(barCount - 1),
            height: barHeight,
            alignment: .bottom
        )
        .onAppear { bobbing = true }
        .accessibilityHidden(true)
    }

    /// How tall a bar stands, 0...1 of its full height. The mapping itself lives
    /// in `AudioLevels`, where it can be tested against known spectra.
    private func scale(at index: Int) -> CGFloat {
        guard isLive else { return resting }
        guard audioDriven else { return bobbing ? 1 : resting }
        let heights = levels.barHeights(
            count: barCount,
            resting: Float(resting),
            outputVolume: model.outputVolume
        )
        guard index < heights.count else { return resting }
        return CGFloat(heights[index])
    }

    private func animationKey(at index: Int) -> Double {
        guard isLive else { return -1 }
        return audioDriven ? Double(scale(at: index)) : (bobbing ? 1 : 0)
    }

    private func animation(at index: Int) -> Animation? {
        guard isLive else { return .easeOut(duration: 0.18) }
        if audioDriven { return .easeOut(duration: 0.09) }
        let slot = index % Self.durations.count
        return .easeInOut(duration: Self.durations[slot])
            .repeatForever(autoreverses: true)
            .delay(Self.phases[slot])
    }

}
