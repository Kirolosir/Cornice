import SwiftUI
import CorniceKit

/// The player.
struct MediaPane: View {
    @Bindable var model: AppModel
    let tick: Int

    private var snapshot: MediaSnapshot? { model.media }
    private var tint: Color { model.artworkTint ?? Theme.Palette.accent }

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

    /// Layout follows Apple's own media surfaces: identity on top, a full-width
    /// scrubber beneath it, and the transport as a distinct row. Putting the
    /// scrubber under everything rather than beside the artwork gives it the
    /// full panel width, which makes it precise enough to actually drag.
    private func player(_ snapshot: MediaSnapshot) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 11) {
                ArtworkThumbnail(
                    image: model.artwork,
                    size: 46,
                    cornerRadius: 10,
                    beatIntensity: model.levels.beatIntensity
                )
                .shadow(color: .black.opacity(0.45), radius: 8, y: 3)

                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(snapshot.artist)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color(white: 0.66))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if model.preferences.audioVisualizerEnabled {
                    SpectrumBars(
                        levels: model.levels,
                        tint: tint,
                        barCount: 5,
                        isLive: snapshot.state.isPlaying
                    )
                    .frame(width: 26, height: 16)
                } else {
                    Text(snapshot.source.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color(white: 0.55))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }

            HStack(spacing: 9) {
                Text(Format.duration(snapshot.extrapolatedPosition()))
                    .frame(width: 34, alignment: .leading)
                Scrubber(progress: snapshot.progress(), tint: tint) { target in
                    model.seek(toProgress: target)
                }
                Text(verbatim: "-\(Format.duration(snapshot.remaining()))")
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(Color(white: 0.52))

            transport(snapshot)
        }
    }

    private func transport(_ snapshot: MediaSnapshot) -> some View {
        HStack(spacing: 0) {
            Button { model.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(SurfaceIconButtonStyle(diameter: 28))
            .foregroundStyle(snapshot.isShuffling ? tint : Color(white: 0.6))
            .help("Shuffle")

            Spacer(minLength: 0)

            Button { model.previousTrack() } label: {
                Image(systemName: "backward.fill").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(SurfaceIconButtonStyle(diameter: 32))
            .help("Previous")

            Spacer(minLength: 0)

            // The primary control, with the weight Apple gives it: a filled
            // white circle and a dark glyph.
            Button { model.playPause() } label: {
                Image(systemName: snapshot.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white))
            }
            .buttonStyle(PressScaleStyle())
            .help(snapshot.state.isPlaying ? "Pause" : "Play")
            .keyboardShortcut(.space, modifiers: [])

            Spacer(minLength: 0)

            Button { model.nextTrack() } label: {
                Image(systemName: "forward.fill").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(SurfaceIconButtonStyle(diameter: 32))
            .help("Next")

            Spacer(minLength: 0)

            // Where the sound is actually going. Worth a permanent slot: with
            // wireless audio it is genuinely ambiguous, and it is the question
            // people check the menu bar for.
            Button { model.openSoundSettings() } label: {
                Image(systemName: model.outputDevice?.transport.symbol ?? "speaker.wave.2")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .buttonStyle(SurfaceIconButtonStyle(diameter: 28))
            .foregroundStyle(
                model.outputDevice?.isWireless == true ? tint : Color(white: 0.6)
            )
            .help(model.outputDevice.map { "Output: \($0.name)" } ?? "Output device")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 2)
    }

    // MARK: - Empty and error states

    private var idle: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color(white: 0.4))
            Text(model.runningPlayers.isEmpty ? "No player running" : "Nothing playing")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(white: 0.6))
            if model.runningPlayers.isEmpty {
                Text("Open Music or Spotify and press play.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Color(white: 0.42))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.raised")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.Palette.running)
            Text("Cornice needs permission to control your music")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text("Enable Cornice for Music and Spotify under Privacy & Security › Automation.")
                .font(Theme.Typeface.caption)
                .foregroundStyle(Color(white: 0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Open Settings") { model.openAutomationSettings() }
                Button("Try Again") { model.retryMediaPermission() }
            }
            .buttonStyle(SurfaceCapsuleButtonStyle(tint: Theme.Palette.accent))
            .font(Theme.Typeface.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }
}

/// Dips slightly on press, for controls with their own background.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

struct SurfaceCapsuleButtonStyle: ButtonStyle {
    var tint: Color = .white
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.20 : (isHovering ? 0.14 : 0.09)))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
            .onHover { isHovering = $0 }
    }
}
