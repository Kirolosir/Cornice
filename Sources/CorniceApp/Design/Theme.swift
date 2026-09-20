import SwiftUI

/// The visual language.
///
/// Two rules shape it. **The surface is true black wherever it touches the
/// notch** (anything else shows a seam against the unlit cut-out), so only the
/// expanded panel follows the system appearance. And **colour is carried by a
/// value or a glyph, never by a block of text**, which is what keeps a surface
/// this small from turning into a dashboard.
enum Theme {

    // MARK: - Ink

    /// Foreground ramps. The light values are higher because alpha-muted ink
    /// loses contrast faster on a light ground than on black.
    struct Ink: Equatable {
        /// Full-strength ink, for the one-off alphas the ramp does not name.
        let base: Color
        let primary: Color
        let secondary: Color
        let tertiary: Color
        /// Background of a selected chip in the module switcher.
        let chip: Color
        /// Unfilled scrubber and slider track.
        let track: Color
        /// Filled portion of the scrubber.
        let fill: Color
        /// The hairline along the surface's bottom edge.
        let hairline: Color

        static let dark = Ink(
            base: .white,
            primary: .white,
            secondary: Color(white: 1, opacity: 0.66),
            tertiary: Color(white: 1, opacity: 0.52),
            chip: Color(white: 1, opacity: 0.10),
            track: Color(white: 1, opacity: 0.16),
            fill: .white,
            hairline: Color(white: 1, opacity: 0.07)
        )

        static let light = Ink(
            base: Color(red: 0.086, green: 0.082, blue: 0.102),
            primary: Color(red: 0.086, green: 0.082, blue: 0.102),
            secondary: Color(red: 0.086, green: 0.082, blue: 0.102).opacity(0.72),
            tertiary: Color(red: 0.086, green: 0.082, blue: 0.102).opacity(0.68),
            chip: Color(red: 0.086, green: 0.082, blue: 0.102).opacity(0.07),
            track: Color(red: 0.086, green: 0.082, blue: 0.102).opacity(0.14),
            fill: Color(red: 0.086, green: 0.082, blue: 0.102),
            hairline: Color(white: 0, opacity: 0.12)
        )

        static func of(_ scheme: ColorScheme) -> Ink { scheme == .dark ? .dark : .light }

        /// Ink at an arbitrary alpha, lifted on a light ground to hold contrast.
        func at(_ alpha: Double) -> Color {
            base.opacity(base == .white ? alpha : min(1, alpha * 1.3))
        }
    }

    // MARK: - Palette

    enum Palette {
        /// The notch's own black: exact and opaque, not a material, so the
        /// resting surface is seamless against the cut-out.
        static let notch = Color(red: 0, green: 0, blue: 0)
        /// The expanded panel's ground in light mode.
        static let sheet = Color(red: 0.945, green: 0.941, blue: 0.929)

        /// Signature accent, used when artwork tinting is off or unavailable.
        static let accent = Color(red: 0.545, green: 0.486, blue: 1.0)

        // Apple's own values, so a charge reading here is the same green as a
        // charge reading anywhere else on the machine.
        static let green = Color(red: 0.196, green: 0.820, blue: 0.345)   // #32d158
        static let red = Color(red: 1.000, green: 0.271, blue: 0.227)     // #ff453a
        /// Timer digits.
        static let orange = Color(red: 0.937, green: 0.604, blue: 0.110)  // #ef9a1c
        /// Slider fills and the pressed state of the pause button.
        static let orangeDeep = Color(red: 0.851, green: 0.518, blue: 0.059) // #d9840f
        /// The pause button's resting fill.
        static let orangeDark = Color(red: 0.761, green: 0.463, blue: 0.059) // #c2760f
        /// Affirmative action.
        static let blue = Color(red: 0.039, green: 0.435, blue: 0.847)    // #0a6fd8
        /// Download progress.
        static let blueLight = Color(red: 0.247, green: 0.608, blue: 0.961) // #3f9bf5
        /// Do Not Disturb.
        static let purple = Color(red: 0.663, green: 0.353, blue: 0.949)  // #a95af2

        // Chart series. Each metric keeps the same slot in the row, so hue
        // reinforces position rather than being the only signal.
        static let cpu = Color(red: 0.290, green: 0.565, blue: 0.886)     // #4a90e2
        static let memory = Color(red: 0.247, green: 0.663, blue: 0.420)  // #3fa96b
        static let networkIn = Color(red: 0.878, green: 0.635, blue: 0.235)  // #e0a23c
        static let networkOut = Color(red: 0.851, green: 0.345, blue: 0.247) // #d9583f

        /// Green above 30%, amber below, red below 15%.
        static func charge(_ level: Double) -> Color {
            switch level {
            case ..<0.15: red
            case ..<0.30: orange
            default: green
            }
        }

        /// The expanded panel's ground.
        static func panel(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? notch : sheet
        }

        /// A card inside the System module.
        static func card(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(white: 1, opacity: 0.055) : Color(white: 0, opacity: 0.045)
        }

        /// The half-point highlight along a card's top edge.
        static func cardHighlight(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(white: 1, opacity: 0.10) : Color(white: 1, opacity: 0.55)
        }
    }

    // MARK: - Typography

    /// Numeric readouts use tabular figures throughout, so a count never shifts
    /// its neighbours as it ticks.
    enum Typeface {
        /// Panel title: the track name in the expanded player.
        static let panelTitle = Font.system(size: 15, weight: .semibold)
        /// HUD title.
        static let hudTitle = Font.system(size: 14.5, weight: .semibold)
        /// Device name in an activity or HUD pill.
        static let deviceName = Font.system(size: 13.5, weight: .semibold)
        /// Body emphasis and labels. The artist line, a timer's label.
        static let body = Font.system(size: 13, weight: .medium)
        static let bodyStrong = Font.system(size: 13, weight: .semibold)
        /// Inline label in a short HUD.
        static let hudInline = Font.system(size: 12.5, weight: .medium)
        /// Status line and the source name in the top band.
        static let status = Font.system(size: 11.5, weight: .medium)
        static let statusStrong = Font.system(size: 11.5, weight: .semibold)
        /// Timestamps and the charge value inside a ring.
        static let stamp = Font.system(size: 11, weight: .medium)
        /// HUD body copy.
        static let hudBody = Font.system(size: 10.5, weight: .regular)
        /// Card header: uppercase, tracked out.
        static let cardHeader = Font.system(size: 10, weight: .semibold)
        static let cardSub = Font.system(size: 10, weight: .regular)

        /// A card's current value.
        static let cardValue = Font.system(size: 21, weight: .semibold, design: .monospaced)
        /// A session clock.
        static let sessionClock = Font.system(size: 21, weight: .semibold, design: .monospaced)
        /// A timer inside the Timers module.
        ///
        /// SF Pro with tabular figures, matching Apple's own countdowns. SF Mono
        /// reads as a terminal beside them; tabular is the part that matters.
        static let timerValue = Font.system(size: 30, weight: .medium).monospacedDigit()
        /// A timer in its own HUD, where it is the only thing on the row.
        static let timerHUD = Font.system(size: 34, weight: .medium).monospacedDigit()
        /// Small monospaced readouts: a legend, a rate.
        static let monoSmall = Font.system(size: 10, weight: .medium, design: .monospaced)
    }

    // MARK: - Metrics

    enum Metrics {
        /// Horizontal inset from the body's edge.
        static let contentPadding: CGFloat = 22
        /// First clear row below the notch band.
        static let contentTop: CGFloat = 58
        /// Vertical rhythm inside the expanded panel.
        static let rowGap: CGFloat = 16
        static let cardCornerRadius: CGFloat = 14
        static let cardHeight: CGFloat = 146
        static let cardGap: CGFloat = 12
        /// Diameter of a module-switcher button.
        static let switcherButton: CGFloat = 26
    }

    // MARK: - Motion

    /// Overshoot applies to width and height only, and height overshoots
    /// *downward*. The top edge is a fixed anchor: a surface attached to the top
    /// of the screen that overshoots upward looks like it has come unstuck.
    enum Motion {
        /// Opening stays close to its final size, with just a little give.
        static let expand = SwiftUI.Animation.spring(response: 0.36, dampingFraction: 0.88)

        /// Closing. Faster and more damped, because bounce on the way out
        /// looks like the app can't make up its mind.
        static let collapse = SwiftUI.Animation.spring(response: 0.28, dampingFraction: 0.94)

        /// Hover peek. Very fast: this exists purely to acknowledge the pointer.
        static let peek = SwiftUI.Animation.spring(response: 0.22, dampingFraction: 0.82)

        /// Content inside an already-open panel. Near-linear: this is a state
        /// change the user asked for, not an entrance.
        static let contentSwap = SwiftUI.Animation.easeOut(duration: 0.16)

        /// Value updates on a timer. Slow enough to read as continuous, short
        /// enough to finish before the next sample arrives.
        static let telemetry = SwiftUI.Animation.easeOut(duration: 0.45)

        /// Button release and the module selection highlight.
        static let release = SwiftUI.Animation.spring(response: 0.22, dampingFraction: 0.82)

        /// A symbol replace: the outgoing glyph is removed and the incoming one
        /// pops in. Never a cross-fade of two glyphs.
        static let symbolReplace = SwiftUI.Animation.spring(response: 0.28, dampingFraction: 0.55)

        /// The scrubber growing under the pointer and shrinking again after.
        static let scrubGrab = SwiftUI.Animation.spring(response: 0.25, dampingFraction: 0.7)

        /// The playhead moving somewhere it did not get to by playing: a seek,
        /// a skip, a track starting over. Springy enough that you can see it
        /// travel and know the press landed instead of having to check.
        static let scrubJump = SwiftUI.Animation.spring(response: 0.42, dampingFraction: 0.8)

        // Content arrives in two groups at fixed points along the opening
        // spring, so the outline is always ahead of what is in it.

        /// Title and artist, arriving early in the morph.
        static let contentEarly = SwiftUI.Animation.easeOut(duration: 0.055).delay(0.053)
        /// The scrubber and transport, arriving once the shape is nearly there.
        static let contentLate = SwiftUI.Animation.easeOut(duration: 0.115).delay(0.220)
    }
}
