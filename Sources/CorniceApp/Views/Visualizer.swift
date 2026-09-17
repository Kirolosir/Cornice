import SwiftUI
import CorniceKit

/// Vertical bars driven by the spectrum analyser.
///
/// Drawn with `Canvas` rather than a stack of shapes: this repaints at display
/// rate, and a view per bar would have SwiftUI diffing a tree sixty times a
/// second for what is ultimately a handful of rounded rectangles.
///
/// When no audio is being captured the bars fall to a resting height rather
/// than disappearing, so the component never pops in and out as playback
/// starts and stops.
struct SpectrumBars: View {
    let levels: AudioLevels
    let tint: Color
    var barCount: Int = 5
    /// Whether the music is actually playing. A paused track shows the resting
    /// state even if stale audio is still in the buffer.
    var isLive: Bool = true

    /// Minimum bar height as a fraction, so the row reads as a control rather
    /// than as a glitch when silent.
    private let restingHeight: CGFloat = 0.14

    var body: some View {
        Canvas { context, size in
            let count = max(1, barCount)
            let spacing = size.width * 0.22 / CGFloat(count)
            let barWidth = (size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            let radius = min(barWidth / 2, 2)

            for index in 0..<count {
                let value = bandValue(at: index, of: count)
                let height = max(size.height * restingHeight, size.height * CGFloat(value))
                let x = CGFloat(index) * (barWidth + spacing)
                // Grown from the vertical centre, which reads as a waveform;
                // growing from the baseline reads as a bar chart.
                let rect = CGRect(
                    x: x,
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: radius),
                    with: .color(tint.opacity(isLive ? 0.95 : 0.4))
                )
            }
        }
        .accessibilityHidden(true)
    }

    /// Maps the analyser's bands onto however many bars are being drawn.
    ///
    /// The collapsed surface shows four bars and the panel shows more, from the
    /// same eight-band analysis, so bands are averaged into buckets rather than
    /// the analyser being reconfigured per view.
    private func bandValue(at index: Int, of count: Int) -> Float {
        guard !levels.bands.isEmpty else { return 0 }
        guard isLive else { return 0 }
        let bandsPerBar = max(1, levels.bands.count / count)
        let start = min(index * bandsPerBar, levels.bands.count - 1)
        let end = min(start + bandsPerBar, levels.bands.count)
        let slice = levels.bands[start..<end]
        guard !slice.isEmpty else { return 0 }
        return slice.reduce(0, +) / Float(slice.count)
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

/// A draggable progress bar.
///
/// Dragging updates a local value and only commits on release, so the bar
/// follows the pointer exactly instead of fighting the poll that would
/// otherwise snap it back to the player's last reported position.
struct Scrubber: View {
    let progress: Double
    let tint: Color
    let onSeek: (Double) -> Void

    @State private var dragProgress: Double?
    @State private var isHovering = false

    private var displayed: Double { dragProgress ?? progress }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height: CGFloat = isHovering || dragProgress != nil ? 6 : 4

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(width, width * displayed)))
            }
            .frame(height: height)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: height)
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragProgress = (value.location.x / width).clamped(to: 0...1)
                    }
                    .onEnded { value in
                        let target = (value.location.x / width).clamped(to: 0...1)
                        dragProgress = nil
                        onSeek(target)
                    }
            )
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(displayed * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            let target = direction == .increment ? displayed + step : displayed - step
            onSeek(target.clamped(to: 0...1))
        }
    }
}
