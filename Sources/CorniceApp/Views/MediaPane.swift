import SwiftUI
import CorniceKit

/// The Now Playing module.
///
/// The layout is the Island's: artwork, then title and artist, then a full-width
/// scrubber with the times beneath it, then chrome-free transport. Putting the
/// scrubber under everything rather than beside the artwork is what gives it
/// enough width to be precise enough to actually drag.
///
/// The artwork itself is *not* drawn here. It belongs to the travelling layer in
/// `RootView`, so that it arrives from the peek position rather than appearing;
/// this pane reserves the space it lands in.
struct MediaPane: View {
    @Bindable var model: AppModel
    let geometry: SurfaceGeometry
    let clock: FrameClock

    @Environment(\.colorScheme) private var scheme
    private var ink: Theme.Ink { .of(scheme) }

    private var snapshot: MediaSnapshot? { model.media }
    private var isExpanded: Bool { model.surfaceState == .expanded }

    /// What an engaged toggle is coloured with.
    ///
    /// The artwork's own accent rather than plain white: on a surface that is
    /// already picking up colour from the cover, "on" reading as *slightly
    /// brighter grey* is not a state anyone notices.
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

    /// Glyph only, no button fills. On the Island the transport has no chrome at
    /// all — the surface is the chrome — and adding circles behind these turns a
    /// media surface into a media *player*, which is a different, heavier thing.
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
            .buttonStyle(PressScaleStyle(pressedScale: 0.84))
            .help("Shuffle")

            Spacer(minLength: 0)

            HStack(spacing: 22) {
                Button { model.previousTrack() } label: {
                    TransportGlyph(name: "backward.fill", size: 21, diameter: 32, isOn: true, ink: ink)
                }
                .buttonStyle(SkipButtonStyle(direction: -1))
                .help("Previous")

                Button { model.playPause() } label: {
                    // A symbol *replace*, not a cross-fade: the outgoing glyph is
                    // removed and the incoming one pops in from 0.68. Fading two
                    // glyphs through each other produces a moment where the
                    // control shows neither state, which is exactly the moment
                    // the user is looking at it.
                    PlayPauseGlyph(isPlaying: snapshot.state.isPlaying, ink: ink)
                }
                .buttonStyle(PressScaleStyle())
                .help(snapshot.state.isPlaying ? "Pause" : "Play")
                .keyboardShortcut(.space, modifiers: [])

                Button { model.nextTrack() } label: {
                    TransportGlyph(name: "forward.fill", size: 21, diameter: 32, isOn: true, ink: ink)
                }
                .buttonStyle(SkipButtonStyle(direction: 1))
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
                .buttonStyle(PressScaleStyle(pressedScale: 0.84))
                .help("Repeat")

                // Where the sound is actually going. Worth a permanent slot: with
                // wireless audio it is genuinely ambiguous, and it is the question
                // people open the menu bar to answer.
                Button { model.openSoundSettings() } label: {
                    TransportGlyph(
                        name: "airplayaudio",
                        size: 15,
                        diameter: 28,
                        isOn: false,
                        ink: ink
                    )
                }
                .buttonStyle(PressScaleStyle(pressedScale: 0.84))
                .help(model.outputDevice.map { "Output: \($0.name)" } ?? "Output device")
            }
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

/// The scrubber and its timestamps.
///
/// Split out so that the one part of the player that moves every frame is also
/// the only part that redraws. It reads the frame clock; nothing above it does.
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

/// A transport glyph, with the 3.5 pt state dot beneath it.
///
/// The dot is how a toggle reads as "on" without a fill: the glyph goes to full
/// ink and a dot pops in below it, which is the convention across iOS.
struct TransportGlyph: View {
    let name: String
    let size: CGFloat
    let diameter: CGFloat
    let isOn: Bool
    let ink: Theme.Ink
    /// Colour for the engaged state. Defaults to full-strength ink, which is
    /// what the always-on glyphs — the skips — want.
    var onColor: Color?

    /// Toggle glyphs go from tertiary to primary ink; the always-on ones — the
    /// skips — are simply primary.
    var body: some View {
        ZStack(alignment: .bottom) {
            Image(systemName: name)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isOn ? (onColor ?? ink.primary) : ink.tertiary)
            if isOn, onColor != nil {
                Circle()
                    .fill(onColor ?? ink.primary)
                    .frame(width: 3.5, height: 3.5)
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

/// A draggable progress bar: 6 pt, no knob, seekable anywhere along its length.
///
/// Dragging updates a local value and only commits on release, so the bar
/// follows the pointer exactly instead of fighting the poll that would otherwise
/// snap it back to the player's last reported position.
struct Scrubber: View {
    let progress: Double
    let track: Color
    let fill: Color
    let onSeek: (Double) -> Void

    @State private var dragProgress: Double?

    private var displayed: Double { dragProgress ?? progress }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(track)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(fill)
                    .frame(width: max(0, min(width, width * displayed)))
                    .animation(.linear(duration: 0.16), value: displayed)
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
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
        .frame(height: 12)
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
