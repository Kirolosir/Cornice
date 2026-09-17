import SwiftUI
import CorniceKit

/// The resting state: artwork on one side of the notch, live spectrum on the other.
///
/// Everything here has to survive being in a developer's peripheral vision for
/// eight hours, so it is deliberately minimal — and shows nothing at all when
/// nothing is playing.
struct CollapsedContentView: View {
    @Bindable var model: AppModel
    let geometry: SurfaceGeometry

    private var snapshot: MediaSnapshot? { model.media }
    private var padding: CGFloat { geometry.contentInset(for: .collapsed) + 8 }

    var body: some View {
        // The notch is a hole in the display; nothing can be drawn inside it,
        // so content sits in the margins the surface adds either side.
        HStack(spacing: 0) {
            leading
                .frame(width: geometry.wingWidth(for: .collapsed, padding: padding), alignment: .leading)
            // The notch itself — a hole in the display, so it is reserved empty.
            Color.clear.frame(width: geometry.notchSize.width)
            trailing
                .frame(width: geometry.wingWidth(for: .collapsed, padding: padding), alignment: .trailing)
        }
        .padding(.horizontal, padding)
        .frame(maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var leading: some View {
        if let snapshot, snapshot.hasTrack, model.preferences.idleDisplay != .nothing {
            ArtworkThumbnail(image: model.artwork, size: 20, cornerRadius: 5)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    /// The spectrum is only shown when it is actually being driven by audio.
    /// Bars that sit at a resting height because capture is off look like a
    /// broken component, and faking motion would misrepresent what the app
    /// knows.
    private var showsSpectrum: Bool {
        model.preferences.idleDisplay == .artworkAndSpectrum
            && model.preferences.audioVisualizerEnabled
    }

    @ViewBuilder
    private var trailing: some View {
        if let snapshot, snapshot.hasTrack, model.preferences.idleDisplay != .nothing {
            if showsSpectrum {
                SpectrumBars(
                    levels: model.levels,
                    tint: model.artworkTint ?? Theme.Palette.accent,
                    barCount: 4,
                    isLive: snapshot.state.isPlaying
                )
                .frame(width: 26, height: 14)
            } else {
                Text(snapshot.title)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Color(white: 0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// The hover state: enough to recognise the track without committing to the panel.
///
/// This exists purely so hovering produces an *immediate* response. A dwell
/// timer with nothing happening during it feels broken no matter how short it
/// is; growing instantly and then opening reads as fast even though the total
/// time is the same.
struct PeekContentView: View {
    @Bindable var model: AppModel
    let geometry: SurfaceGeometry
    let tick: Int

    private var snapshot: MediaSnapshot? { model.media }
    private var padding: CGFloat { geometry.contentInset(for: .peek) + 8 }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ArtworkThumbnail(
                    image: model.artwork,
                    size: 26,
                    cornerRadius: 6,
                    beatIntensity: model.levels.beatIntensity
                )
                if let snapshot, snapshot.hasTrack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(snapshot.artist)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color(white: 0.62))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                } else {
                    Text("Nothing playing")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color(white: 0.55))
                }
                Spacer(minLength: 0)
            }
            .frame(width: geometry.wingWidth(for: .peek, padding: padding), alignment: .leading)

            Color.clear.frame(width: geometry.notchSize.width)

            Group {
                if model.preferences.audioVisualizerEnabled {
                    SpectrumBars(
                        levels: model.levels,
                        tint: model.artworkTint ?? Theme.Palette.accent,
                        barCount: 5,
                        isLive: snapshot?.state.isPlaying == true
                    )
                    .frame(width: 34, height: 16)
                } else if snapshot?.state.isPlaying == true {
                    // Without audio capture there is nothing honest to
                    // visualise, so this just states that something is playing.
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.artworkTint ?? Theme.Palette.accent)
                }
            }
            .frame(width: geometry.wingWidth(for: .peek, padding: padding), alignment: .trailing)
        }
        .padding(.horizontal, padding)
        .padding(.bottom, SurfaceGeometry.peekDrop)
        .frame(maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
    }
}

/// The open panel.
struct ExpandedContentView: View {
    @Bindable var model: AppModel
    let geometry: SurfaceGeometry
    let tick: Int

    var body: some View {
        VStack(spacing: 0) {
            // Reserve the notch strip: the panel hangs below the cut-out.
            Color.clear.frame(height: geometry.notchSize.height)

            VStack(spacing: 10) {
                TabStrip(model: model)

                Group {
                    switch model.activeModule {
                    case .media:
                        MediaPane(model: model, tick: tick)
                    case .timers:
                        TimersPane(model: model, tick: tick)
                    case .stats:
                        StatsPane(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            // The flare narrows the shape's sides, so content is inset by it
            // before its own padding is applied.
            .padding(.horizontal, geometry.contentInset(for: .expanded) + 14)
            .padding(.bottom, 16)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(Theme.Motion.contentSwap, value: model.toast)
    }
}

/// Module tabs.
struct TabStrip: View {
    @Bindable var model: AppModel

    private var modules: [ModuleKind] {
        ModuleKind.allCases.filter { model.preferences.enabledModules.contains($0) }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(modules) { module in
                TabButton(
                    module: module,
                    isActive: model.activeModule == module,
                    tint: model.artworkTint ?? Theme.Palette.accent
                ) {
                    model.select(module: module)
                }
            }

            Spacer(minLength: 8)

            if let battery = model.telemetry.latest?.battery {
                BatteryIndicator(battery: battery)
            }

            Button {
                SettingsWindow.shared.show(model: model)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(SurfaceIconButtonStyle())
            .help("Settings")

            Button {
                model.present(.collapsed)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(SurfaceIconButtonStyle())
            .help("Collapse (Esc)")
            .accessibilityLabel("Collapse panel")
        }
        .frame(height: 28)
    }
}

struct TabButton: View {
    let module: ModuleKind
    let isActive: Bool
    let tint: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: module.symbol)
                    .font(.system(size: 11, weight: .medium))
                if isActive {
                    Text(module.title)
                        .font(Theme.Typeface.caption)
                        .fixedSize()
                }
            }
            .padding(.horizontal, isActive ? 9 : 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(isActive ? 0.12 : (isHovering ? 0.07 : 0)))
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.white : Color(white: 0.6))
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.contentSwap, value: isActive)
        .accessibilityLabel(module.title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

/// A circular icon button sized for the dark surface.
struct SurfaceIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 26
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(white: 0.85))
            .frame(width: diameter, height: diameter)
            .background(
                Circle().fill(Color.white.opacity(configuration.isPressed ? 0.18 : (isHovering ? 0.10 : 0.05)))
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
            .onHover { isHovering = $0 }
    }
}

struct BatteryIndicator: View {
    let battery: BatteryState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
            Text(verbatim: "\(Int((battery.level * 100).rounded()))%")
                .font(Theme.Typeface.monoSmall)
                .foregroundStyle(Color(white: 0.62))
        }
        .accessibilityLabel("Battery \(Int(battery.level * 100)) percent")
    }

    private var symbol: String {
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.level {
        case ..<0.15: return "battery.0"
        case ..<0.45: return "battery.25"
        case ..<0.80: return "battery.75"
        default: return "battery.100"
        }
    }

    /// Red only when genuinely low *and* not charging — a 10% battery on the
    /// charger is not a problem, and colouring it red trains people to ignore it.
    private var tint: Color {
        if battery.isCharging { return Theme.Palette.success }
        return battery.level < 0.15 ? Theme.Palette.failure : Color(white: 0.6)
    }
}
