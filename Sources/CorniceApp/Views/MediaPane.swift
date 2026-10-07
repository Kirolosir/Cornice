import SwiftUI
import CorniceKit

/// The player controls and track text. RootView draws the moving artwork; this view leaves
/// room for it and puts the scrubber across the full width.
struct MediaPane: View {
    @Bindable var model: AppModel
    let geometry: SurfaceGeometry
    let clock: FrameClock

    @Environment(\.colorScheme) private var scheme
    private var ink: Theme.Ink { .of(scheme) }

    private var snapshot: MediaSnapshot? { model.media }
    private var isExpanded: Bool { model.surfaceState == .expanded }

    /// Use the cover's accent for active controls so their state is easy to spot.
    private var accent: Color { model.artworkTint ?? Theme.Palette.accent }

    var body: some View {
        if model.mediaPermissionDenied {
            permissionPrompt
        } else if let snapshot, snapshot.hasTrack {
            player(snapshot)
        } else {
            idle
        }
    }

    // MARK: - Player

    private func player(_ snapshot: MediaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.rowGap) {
            identity(snapshot)

            // The scrubber and the transport arrive late in the morph, on top of
            // a shape that is already the right size. The outline never waits
            // for its contents.
            VStack(alignment: .leading, spacing: Theme.Metrics.rowGap) {
                ScrubberRow(model: model, clock: clock, ink: ink)
                transport(snapshot)
            }
            .opacity(isExpanded ? 1 : 0)
            .animation(Theme.Motion.contentLate, value: isExpanded)
        }
    }

    private func identity(_ snapshot: MediaSnapshot) -> some View {
        HStack(alignment: .center, spacing: 15) {
            // The space the travelling artwork lands in.
            Color.clear.frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title)
                    .font(Theme.Typeface.panelTitle)
                    .tracking(-0.18)
                    .foregroundStyle(ink.primary)
                Text(snapshot.artist)
                    .font(Theme.Typeface.body)
                    .tracking(-0.065)
                    .foregroundStyle(ink.secondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer(minLength: 0)
        }
    }

    /// Use plain transport icons to keep the control row light.
    private func transport(_ snapshot: MediaSnapshot) -> some View {
        HStack(spacing: 0) {
            Button { model.toggleShuffle() } label: {
                TransportGlyph(
                    name: "shuffle",
                    size: 15,
                    diameter: 28,
                    isOn: snapshot.isShuffling,
                    ink: ink,
                    onColor: accent
                )
            }
            .buttonStyle(PressScaleStyle(pressedScale: 0.94))
            .help("Shuffle")

            Spacer(minLength: 0)

            HStack(spacing: 22) {
                SkipButton(direction: -1) { model.previousTrack() } label: {
                    TransportGlyph(name: "backward.fill", size: 21, diameter: 32, isOn: true, ink: ink)
                }
                .help("Previous")

                Button { model.playPause() } label: {
                    // Replace the play/pause icon instead of fading two symbols over each
                    // other.
                    PlayPauseGlyph(isPlaying: snapshot.state.isPlaying, ink: ink)
                }
                .buttonStyle(PressScaleStyle())
                .help(snapshot.state.isPlaying ? "Pause" : "Play")
                .keyboardShortcut(.space, modifiers: [])

                SkipButton(direction: 1) { model.nextTrack() } label: {
                    TransportGlyph(name: "forward.fill", size: 21, diameter: 32, isOn: true, ink: ink)
                }
                .help("Next")
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button { model.cycleRepeat() } label: {
                    TransportGlyph(
                        name: snapshot.repeatMode == .one ? "repeat.1" : "repeat",
                        size: 15,
                        diameter: 28,
                        isOn: snapshot.repeatMode != .off,
                        ink: ink,
                        onColor: accent
                    )
                }
                .buttonStyle(PressScaleStyle(pressedScale: 0.94))
                // Spells out the state, because Spotify's is a two-way where
                // Music's is a three-way and nothing on the glyph says so.
                .help(Self.repeatHelp(snapshot))

                // Show the output device under the controls so the audio destination is
                // clear.
                Button { model.openSoundSettings() } label: {
                    TransportGlyph(
                        name: "airplayaudio",
                        size: 15,
                        diameter: 28,
                        isOn: false,
                        ink: ink
                    )
                }
                .buttonStyle(PressScaleStyle(pressedScale: 0.94))
                .help(model.outputDevice.map { "Output: \($0.name)" } ?? "Output device")
            }
        }
    }

    /// A tooltip that names the current repeat state.
    static func repeatHelp(_ snapshot: MediaSnapshot) -> String {
        switch snapshot.repeatMode {
        case .off: "Repeat off"
        case .one: "Repeating this track"
        case .all: "Repeating everything"
        }
    }

    // MARK: - Empty and error states

    private var idle: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(ink.tertiary)
            Text(model.runningPlayers.isEmpty ? "No player running" : "Nothing playing")
                .font(Theme.Typeface.body)
                .foregroundStyle(ink.secondary)
            if model.runningPlayers.isEmpty {
                Text("Open Music or Spotify and press play.")
                    .font(Theme.Typeface.hudBody)
                    .foregroundStyle(ink.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionPrompt: some View {
        VStack(spacing: 10) {
            Text("Cornice needs permission to control your music")
                .font(Theme.Typeface.hudTitle)
                .foregroundStyle(ink.primary)
            Text("Enable Cornice for Music and Spotify under Privacy & Security › Automation.")
                .font(Theme.Typeface.hudBody)
                .lineSpacing(3)
                .foregroundStyle(ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Try Again") { model.retryMediaPermission() }
                    .buttonStyle(SoftButtonStyle(height: 32, cornerRadius: 9, pressedScale: 0.96))
                Button("Open Settings") { model.openAutomationSettings() }
                    .buttonStyle(SoftButtonStyle(height: 32, cornerRadius: 9, fill: Theme.Palette.blue, pressedScale: 0.96))
            }
            .font(Theme.Typeface.body)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}

/// Keep the scrubber in its own view. It reads the frame clock without redrawing the rest
/// of the player.
struct ScrubberRow: View {
    @Bindable var model: AppModel
    let clock: FrameClock
    let ink: Theme.Ink

    var body: some View {
        // Read so this view, and only this view, depends on the clock.
        _ = clock.tick
        let snapshot = model.media
        return VStack(spacing: 6) {
            Scrubber(
                progress: snapshot?.progress() ?? 0,
                track: ink.track,
                fill: ink.fill
            ) { target in
                model.seek(toProgress: target)
            }

            HStack(spacing: 0) {
                Text(Format.duration(snapshot?.extrapolatedPosition() ?? 0))
                Spacer(minLength: 0)
                Text(verbatim: "-\(Format.duration(snapshot?.remaining() ?? 0))")
            }
            .font(Theme.Typeface.stamp.monospacedDigit())
            .foregroundStyle(ink.tertiary)
        }
    }
}

/// A small dot below the icon shows that shuffle or repeat is on.
struct TransportGlyph: View {
    let name: String
    let size: CGFloat
    let diameter: CGFloat
    let isOn: Bool
    let ink: Theme.Ink
    /// Colour for the engaged state. Defaults to full-strength ink, which is
    /// what the always-on glyphs (the skips) want.
    var onColor: Color?

    /// Toggle glyphs go from tertiary to primary ink; the always-on ones (the
    /// skips) are simply primary.
    var body: some View {
        ZStack(alignment: .bottom) {
            // Keep active icons bright. Put the artwork color in the dot so dark covers
            // don't make an active button look dimmer.
            Image(systemName: name)
                .font(.system(size: size, weight: isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? ink.primary : ink.tertiary)
            if isOn, let onColor {
                Circle()
                    .fill(onColor)
                    .frame(width: 4, height: 4)
                    .transition(.scale(scale: 0).combined(with: .opacity))
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(Theme.Motion.symbolReplace, value: isOn)
    }
}

/// Play and pause, swapped by replacement rather than by cross-fade.
struct PlayPauseGlyph: View {
    let isPlaying: Bool
    let ink: Theme.Ink

    var body: some View {
        ZStack {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(ink.primary)
                .id(isPlaying)
                .transition(.scale(scale: 0.68).combined(with: .opacity))
        }
        .frame(width: 34, height: 34)
        .animation(Theme.Motion.symbolReplace, value: isPlaying)
    }
}

/// Click or drag to seek. Update dragging directly and animate seeks. Send the position on
/// release so polls do not pull it back during the drag.
struct Scrubber: View {
    let progress: Double
    let track: Color
    let fill: Color
    let onSeek: (Double) -> Void

    /// Where the pointer is, while a drag is in progress.
    @State private var dragProgress: Double?
    /// Where the bar is drawn. Follows `progress` except during a drag.
    @State private var shown: Double = 0
    @State private var isHovering = false

    private var isDragging: Bool { dragProgress != nil }
    private var displayed: Double { dragProgress ?? shown }

    /// Grows under the pointer, and again when you grab it. Same idea as the
    /// scrubber in Music: the bar acknowledges that it is a control.
    private var barHeight: CGFloat {
        if isDragging { return 10 }
        return isHovering ? 8 : 6
    }

    /// Treat a large change as a seek or skip. Normal playback moves much less than this
    /// between frames.
    private static let jumpThreshold = 0.04

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(track)
                Capsule(style: .continuous)
                    .fill(fill)
                    .frame(width: max(0, min(width, width * displayed)))
            }
            .frame(height: barHeight)
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(Theme.Motion.scrubGrab, value: barHeight)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragProgress = (value.location.x / width).clamped(to: 0...1)
                    }
                    .onEnded { value in
                        let target = (value.location.x / width).clamped(to: 0...1)
                        // Take the drop position before letting go of the drag,
                        // or the bar flicks back to the last poll for the moment
                        // it takes the player to answer.
                        shown = target
                        dragProgress = nil
                        onSeek(target)
                    }
            )
        }
        .frame(height: 12)
        .onAppear { shown = progress }
        .onChange(of: progress) { previous, current in
            guard !isDragging else { return }
            if abs(current - previous) > Self.jumpThreshold {
                withAnimation(Theme.Motion.scrubJump) { shown = current }
            } else {
                shown = current
            }
        }
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
