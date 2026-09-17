import SwiftUI

/// The visual language.
///
/// Two decisions shape everything here.
///
/// **The collapsed surface is always black; the expanded panel adapts.** When
/// collapsed, the surface sits flush against a physical notch, which is an
/// unlit region of the panel. Anything other than true black would show a seam
/// against the hardware. The expanded panel floats away from the notch, so it
/// is free to follow the system appearance — and should, because a light-mode
/// user does not want a slab of black dropped onto their desktop.
///
/// **Colour carries status, not decoration.** A developer glancing at this
/// needs "is anything wrong?" answered pre-attentively, so red, amber and green
/// are reserved for failing, running and passing. The accent violet is used
/// only for interactive affordances, which keeps it from competing with the
/// status colours for attention.
enum Theme {

    // MARK: - Palette

    enum Palette {
        /// The notch's own black. Not `Color.black` through a material — an
        /// exact opaque black, so the collapsed surface is seamless against the
        /// hardware cut-out.
        static let notch = Color(red: 0, green: 0, blue: 0)

        /// Signature accent, used when artwork tinting is off or unavailable.
        static let accent = Color(red: 0.545, green: 0.486, blue: 1.0)

        // Status colours, each with a dimmed variant for large fills where the
        // saturated version would vibrate against black.
        static let success = Color(red: 0.24, green: 0.80, blue: 0.47)
        static let failure = Color(red: 1.00, green: 0.31, blue: 0.29)
        static let running = Color(red: 1.00, green: 0.70, blue: 0.25)
        static let neutral = Color(red: 0.56, green: 0.57, blue: 0.62)

        // Telemetry series. Distinguishable for the most common forms of colour
        // vision deficiency by pairing hue with position — each metric always
        // occupies the same slot in the grid, so hue is reinforcement, not the
        // only signal.
        static let cpu = Color(red: 0.36, green: 0.62, blue: 1.00)
        static let memory = Color(red: 0.36, green: 0.80, blue: 0.62)
        static let networkIn = Color(red: 0.98, green: 0.72, blue: 0.35)
        static let networkOut = Color(red: 0.93, green: 0.45, blue: 0.42)

        /// Panel background, adapting to appearance.
        static func panel(_ scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 0.055, green: 0.055, blue: 0.065)
                : Color(red: 0.98, green: 0.98, blue: 0.985)
        }

        /// Raised card inside the panel.
        static func card(_ scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 0.094, green: 0.094, blue: 0.106)
                : Color(red: 1.0, green: 1.0, blue: 1.0)
        }

        static func hairline(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.08)
        }

        static func primaryText(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(white: 0.96) : Color(white: 0.10)
        }

        static func secondaryText(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(white: 0.62) : Color(white: 0.42)
        }

        static func tertiaryText(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(white: 0.44) : Color(white: 0.58)
        }
    }

    // MARK: - Typography

    /// A four-step scale. More steps than this and a panel this small stops
    /// reading as a single object.
    enum Typeface {
        /// Headline values — a percentage, a timer, a branch name.
        static let title = Font.system(size: 15, weight: .semibold, design: .default)
        /// Standard row text.
        static let body = Font.system(size: 12, weight: .medium, design: .default)
        /// Labels and captions.
        static let caption = Font.system(size: 10.5, weight: .medium, design: .default)
        /// Hashes, ports, durations. Monospaced *digits* rather than a fully
        /// monospaced face, so numbers do not jitter as they update while the
        /// surrounding prose keeps normal letterforms.
        static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
        static let monoSmall = Font.system(size: 10, weight: .medium, design: .monospaced)
        /// Large telemetry readouts.
        static let metric = Font.system(size: 19, weight: .semibold, design: .rounded)
            .monospacedDigit()
    }

    // MARK: - Metrics

    /// Everything is a multiple of 4 so nested containers stay on a common
    /// rhythm and optical alignment does not have to be fixed by eye.
    enum Metrics {
        static let gridUnit: CGFloat = 4

        static let panelWidth: CGFloat = 560
        static let panelCornerRadius: CGFloat = 26
        static let panelPadding: CGFloat = 16
        static let cardCornerRadius: CGFloat = 12
        static let cardPadding: CGFloat = 10

        /// Vertical offset of the expanded panel below the notch. Small enough
        /// that the panel still reads as belonging to the notch, large enough
        /// that its shadow is visible against the desktop.
        static let panelDrop: CGFloat = 6

        /// How far the collapsed surface extends past the notch on each side
        /// when it has something to show.
        ///
        /// Sized so a typical prefixed branch name (`feature/notch-geometry`)
        /// keeps enough of both ends to be recognisable after truncation.
        static let wingWidth: CGFloat = 124
        /// Extra height the collapsed surface gains when showing content, so
        /// its rounded bottom edge clears the menu bar text beside it.
        static let wingDrop: CGFloat = 6

        static let rowHeight: CGFloat = 30
        static let tabStripHeight: CGFloat = 30
    }

    // MARK: - Motion

    /// Durations and curves.
    ///
    /// The expand/collapse spring is critically damped rather than bouncy. A
    /// surface anchored to the top edge of the screen that overshoots looks
    /// like it has come unstuck from the hardware; Apple's own notch
    /// animations settle rather than wobble.
    enum Motion {
        /// Opening. A touch of overshoot — `dampingFraction` below 1 — so the
        /// surface arrives with weight rather than easing to a polite stop.
        /// This is the single most important curve in the app: it is what the
        /// whole interaction is judged on.
        static let expand = SwiftUI.Animation.spring(response: 0.38, dampingFraction: 0.76)

        /// Closing. Faster and more damped than opening. Closing is a dismissal,
        /// and a bouncy dismissal reads as indecision.
        static let collapse = SwiftUI.Animation.spring(response: 0.30, dampingFraction: 0.86)

        /// Hover peek. Very fast, because this exists purely to acknowledge the
        /// pointer — any perceptible delay here is what makes a notch app feel
        /// unresponsive.
        static let peek = SwiftUI.Animation.spring(response: 0.22, dampingFraction: 0.82)
        /// Content swaps inside an already-open panel. Fast and linear-ish:
        /// this is a state change the user asked for, not an entrance.
        static let contentSwap = SwiftUI.Animation.easeOut(duration: 0.16)
        /// Value updates on a timer. Slow enough to read as continuous, short
        /// enough to finish before the next sample arrives.
        static let telemetry = SwiftUI.Animation.easeOut(duration: 0.45)
        static let press = SwiftUI.Animation.easeOut(duration: 0.08)
    }
}

// MARK: - Shared view modifiers

/// A card surface inside the expanded panel.
struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat = Theme.Metrics.cardPadding

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.Palette.card(scheme), in: RoundedRectangle(cornerRadius: Theme.Metrics.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline(scheme), lineWidth: 1)
            )
    }
}

extension View {
    func cardSurface(padding: CGFloat = Theme.Metrics.cardPadding) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

/// A button style that dips slightly on press.
///
/// The panel has no window chrome and does not take focus, so without an
/// explicit press state a click gives no feedback at all and feels broken.
struct PanelButtonStyle: ButtonStyle {
    var tint: Color?
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint ?? Theme.Palette.primaryText(scheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor(pressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
            .onHover { isHovering = $0 }
    }

    private func backgroundColor(pressed: Bool) -> Color {
        let base = scheme == .dark ? Color.white : Color.black
        if pressed { return base.opacity(0.14) }
        if isHovering { return base.opacity(0.08) }
        return base.opacity(0.04)
    }
}
