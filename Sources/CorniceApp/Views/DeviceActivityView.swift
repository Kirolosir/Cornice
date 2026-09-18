import SwiftUI
import CorniceKit

/// The announcement shown when a wireless output device connects.
///
/// Built like the system HUDs rather than like the player: a glyph, then status
/// over device name in the left margin, and a charge ring in the right. All
/// outside the hole. No artwork tint, because this is not about the music.
///
/// It is event-driven and self-dismissing. This is a notification, not a state
/// the user has to close.
struct DeviceActivityView: View {
    @Bindable var model: AppModel
    let geometry: SurfaceGeometry

    /// Drives the entry spin. Kept local so the animation runs from the moment
    /// the view becomes visible rather than from some shared clock.
    @State private var spin = false
    @State private var ringProgress: Double = 0

    private var activity: AppModel.DeviceActivity? { model.deviceActivity }
    private var flare: CGFloat { geometry.flareRadius(for: .activity) }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                deviceIcon
                if let activity {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Connected")
                            .font(Theme.Typeface.stamp)
                            .foregroundStyle(Theme.Ink.dark.at(0.62))
                        Text(activity.name)
                            .font(Theme.Typeface.bodyStrong)
                            .foregroundStyle(Theme.Ink.dark.primary)
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.leading, flare + 14)

            Spacer(minLength: 0)

            if let level = activity?.batteryLevel {
                BatteryRing(level: level, progress: ringProgress)
                    .frame(width: 34, height: 34)
                    .padding(.trailing, flare + 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .onAppear { animateIn() }
        .onChange(of: activity?.id) { _, _ in animateIn() }
    }

    /// The device glyph, turned once about its Y axis on entry.
    ///
    /// `rotation3DEffect` is doing real perspective projection here, which is why
    /// it reads as an object turning rather than as an image being squashed
    /// horizontally. The perspective value matches the design's 220 pt camera at
    /// this glyph size.
    private var deviceIcon: some View {
        // Falls back when the named symbol is missing: SF Symbol availability
        // varies by macOS version, and a missing symbol renders as nothing at
        // all rather than as an obvious placeholder.
        Image(systemName: Self.resolvedSymbol(activity?.symbol))
            .font(.system(size: 26, weight: .regular))
            .foregroundStyle(Color(white: 0.95))
            .frame(width: 30, height: 30)
            .rotation3DEffect(
                .degrees(spin ? 360 : 0),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.68
            )
            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
    }

    /// Uses the requested symbol when the system has it, otherwise a generic one.
    static func resolvedSymbol(_ name: String?) -> String {
        guard let name,
              NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        else { return "headphones" }
        return name
    }

    private func animateIn() {
        spin = false
        ringProgress = 0
        // A beat before spinning, so the surface has finished growing and the
        // two animations are not competing for the same frames.
        withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 1.1).delay(0.12)) { spin = true }
        withAnimation(.easeOut(duration: 0.9).delay(0.24)) { ringProgress = 1 }
    }
}

/// A circular charge indicator: 28 pt circle, 2.8 pt stroke, rounded cap,
/// starting at twelve o'clock, with the number in the middle.
struct BatteryRing: View {
    /// Charge, 0...1.
    let level: Double
    /// How much of the ring has been drawn, for the entry animation.
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(white: 1, opacity: 0.13), lineWidth: 2.8)

            Circle()
                .trim(from: 0, to: level * progress)
                .stroke(Theme.Palette.charge(level), style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text(verbatim: "\(Int((level * 100).rounded()))")
                .font(Theme.Typeface.status)
                .monospacedDigit()
                .foregroundStyle(.white)
                .opacity(progress)
        }
        .padding(3)
        .accessibilityElement()
        .accessibilityLabel("Battery \(Int(level * 100)) percent")
    }
}
