import SwiftUI
import CorniceKit

// MARK: - Resting

/// What the resting surface shows. All of it *outside* the surface.
///
/// At rest the surface is exactly the notch: pure black, no tint, seamless. The
/// notch is a hole in the display, so anything drawn inside its rectangle does
/// not exist on real hardware. Both pieces of content therefore sit in the
/// menu-bar margins either side of the hole, which is the only place they can
/// be seen at all.
///
/// With nothing playing there is nothing here. No pill, no placeholder.
struct RestingMarginView: View {
    @Bindable var model: AppModel
    let geometry: SurfaceGeometry

    private var snapshot: MediaSnapshot? { model.media }

    /// An 88 pt column starting 8 pt right of the notch's right edge.
    private var columnLeft: CGFloat {
        geometry.notchLeft + geometry.notchSize.width + 8
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let snapshot, snapshot.hasTrack, model.preferences.idleDisplay != .nothing {
                trailing(snapshot)
                    .frame(width: 88, height: geometry.notchSize.height, alignment: .leading)
                    .offset(x: columnLeft)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var showsSpectrum: Bool {
        model.preferences.idleDisplay == .artworkAndSpectrum
    }

    @ViewBuilder
    private func trailing(_ snapshot: MediaSnapshot) -> some View {
        if showsSpectrum {
            EqualizerIndicator(
                model: model,
                isLive: model.surfaceState == .collapsed && snapshot.state.isPlaying,
                tint: Theme.Ink.dark.secondary
            )
        } else {
            Text(snapshot.title)
                .font(Theme.Typeface.stamp)
                .foregroundStyle(Color(white: 1, opacity: 0.72))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

// MARK: - Peek

/// The hover state: enough to recognise the track without committing to the
/// full panel.
///
/// This exists purely so hovering produces an *immediate* response. A dwell
/// timer with nothing happening during it feels broken no matter how short it
/// is; growing instantly and then opening reads as fast even though the total
/// time is the same.
///
/// The artwork is not drawn here. It belongs to the travelling layer in
/// `RootView`, which is what lets it arrive from the resting position rather
/// than appearing.
struct PeekContentView: View {
    @Bindable var model: AppModel
    let geometry: SurfaceGeometry

    private var snapshot: MediaSnapshot? { model.media }

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Spacer(minLength: 0)

            if let snapshot, snapshot.hasTrack {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(snapshot.title)
                        .font(Theme.Typeface.statusStrong)
                        .foregroundStyle(Theme.Ink.dark.primary)
                    Text(snapshot.artist)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.Ink.dark.tertiary)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                // 94 pt of usable margin at this width, and the artwork and the
                // indicator take their share of it.
                .frame(maxWidth: 64, alignment: .trailing)

                EqualizerIndicator(
                    model: model,
                    isLive: model.surfaceState == .peek && snapshot.state.isPlaying,
                    tint: Theme.Ink.dark.secondary
                )
            } else {
                Text("Nothing playing")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.Ink.dark.tertiary)
            }
        }
        .padding(.trailing, geometry.flareRadius(for: .peek) + 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .allowsHitTesting(false)
    }
}

// MARK: - Expanded

/// The open panel: a 38 pt band that can only use its two margins, and a module
/// below it that has the whole width.
struct ExpandedContentView: View {
    @Bindable var model: AppModel
    let geometry: SurfaceGeometry
    let clock: FrameClock

    @Environment(\.colorScheme) private var scheme
    private var ink: Theme.Ink { .of(scheme) }

    /// Horizontal inset from the *surface*: past the cove, then the content
    /// padding.
    private var sideInset: CGFloat {
        geometry.flareRadius(for: .expanded) + Theme.Metrics.contentPadding
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            band
            module
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(Theme.Typeface.stamp)
                    .foregroundStyle(ink.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.contentSwap, value: model.toast)
    }

    /// The band across the notch. Nothing may be drawn in the middle of it, so
    /// the source name takes the left margin and the module switcher the right.
    ///
    /// The segmented control that used to live below the notch was moved up
    /// here precisely because the band is otherwise dead space, and it was
    /// moved to the *right margin* because anything centred would fall inside
    /// the hole.
    private var band: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(sourceName)
                    .font(Theme.Typeface.status)
                    .foregroundStyle(ink.tertiary)
                    .lineLimit(1)

                // The live indicator. In the band rather than beside the artwork
                // because the band is visible for as long as the panel is. Peek,
                // where it used to live, is skipped entirely when the hover
                // dwell is zero, which is the default.
                if model.activeModule == .media, model.showsIndicator {
                    EqualizerIndicator(
                        model: model,
                        isLive: model.surfaceState == .expanded,
                        tint: model.artworkTint ?? ink.secondary,
                        barCount: 5
                    )
                }
            }
            .padding(.leading, sideInset)

            Spacer(minLength: 0)

            ModuleSwitcher(model: model)
                .padding(.trailing, geometry.flareRadius(for: .expanded) + 18)
        }
        .frame(height: geometry.bandHeight)
    }

    private var sourceName: String {
        switch model.activeModule {
        case .stats: "System"
        case .timers: "Timers"
        case .media: model.media?.source.displayName ?? ""
        }
    }

    private var module: some View {
        Group {
            switch model.activeModule {
            case .media: MediaPane(model: model, geometry: geometry, clock: clock)
            case .timers: TimersPane(model: model, clock: clock)
            case .stats: StatsPane(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, sideInset)
        .padding(.top, Theme.Metrics.contentTop)
        .padding(.bottom, 18)
    }
}

/// Three round buttons, 26 pt across and 2 pt apart, in the band's right margin.
struct ModuleSwitcher: View {
    @Bindable var model: AppModel
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var modules: [ModuleKind] {
        ModuleKind.allCases.filter { model.preferences.enabledModules.contains($0) }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modules) { module in
                ModuleButton(module: module, isActive: model.activeModule == module, selection: selection) {
                    withAnimation(reduceMotion ? nil : Theme.Motion.release) {
                        model.select(module: module)
                    }
                }
            }
        }
    }
}

struct ModuleButton: View {
    let module: ModuleKind
    let isActive: Bool
    let selection: Namespace.ID
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var ink: Theme.Ink { .of(scheme) }

    var body: some View {
        Button(action: action) {
            Image(systemName: module.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(
                    width: Theme.Metrics.switcherButton,
                    height: Theme.Metrics.switcherButton
                )
                .background {
                    if isActive {
                        Circle().fill(ink.chip)
                            .matchedGeometryEffect(id: "module", in: selection)
                    }
                }
                .foregroundStyle(isActive ? ink.primary : ink.tertiary)
        }
        .buttonStyle(PressScaleStyle(pressedScale: 0.94))
        .animation(Theme.Motion.contentSwap, value: isActive)
        .help(module.title)
        .accessibilityLabel(module.title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Button behaviour

/// A small press dip and a quiet hover highlight.
struct PressScaleStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.94
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(isHovering && isEnabled ? 0.07 : 0), in: Capsule())
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .animation(configuration.isPressed ? .easeOut(duration: 0.08) : Theme.Motion.release,
                       value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// A short directional nudge after a skip.
struct SkipButton<Label: View>: View {
    let direction: CGFloat
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clicks = 0

    var body: some View {
        let travel: CGFloat = reduceMotion ? 0 : direction
        return Button {
            action()
            clicks += 1
        } label: {
            label()
                .modifier(SkipFeedback(clicks: clicks, travel: travel))
        }
        .buttonStyle(PressScaleStyle())
    }
}

private struct SkipFeedback: ViewModifier {
    let clicks: Int
    let travel: CGFloat

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat.zero, trigger: clicks) { view, offset in
            view.offset(x: offset * travel)
        } keyframes: { _ in
            CubicKeyframe(3, duration: 0.08)
            SpringKeyframe(0, duration: 0.22, spring: .smooth)
        }
    }
}

/// A filled round button, as used by the timer controls.
struct FilledCircleButtonStyle: ButtonStyle {
    var fill: Color
    var hoverFill: Color
    var diameter: CGFloat = 30

    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill((isHovering || configuration.isPressed) && enabled ? hoverFill : fill))
            .contentShape(Circle())
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reducedMotion ? 0.94 : 1)
            .animation(
                configuration.isPressed ? .easeOut(duration: 0.06) : Theme.Motion.release,
                value: configuration.isPressed
            )
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// A soft-filled rectangular button: the timer presets, and the actions in a HUD.
struct SoftButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var cornerRadius: CGFloat = 8
    var fill: Color?
    var pressedScale: CGFloat = 0.94

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let base = scheme == .dark ? Color.white : Color.black
        let background = fill ?? base.opacity(configuration.isPressed ? 0.20 : (isHovering ? 0.14 : 0.08))
        return configuration.label
            .foregroundStyle(fill == nil ? Theme.Ink.of(scheme).primary.opacity(0.82) : .white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(background)
                    .overlay(alignment: .top) {
                        // The half-point highlight that keeps a low-contrast fill
                        // from reading as a hole rather than a raised surface.
                        Rectangle()
                            .fill(Theme.Palette.cardHighlight(scheme).opacity(0.6))
                            .frame(height: 0.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reducedMotion ? pressedScale : 1)
            .animation(
                configuration.isPressed ? .easeOut(duration: 0.06) : Theme.Motion.release,
                value: configuration.isPressed
            )
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .onHover { isHovering = $0 }
    }
}
