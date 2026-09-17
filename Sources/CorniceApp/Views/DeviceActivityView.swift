import SwiftUI
import CorniceKit

/// The announcement shown when a wireless output device connects.
///
/// Modelled on the Live Activity iOS shows when AirPods connect: the device on
/// one side, its charge on the other, for a few seconds, then gone. It is
/// event-driven and self-dismissing — it is a notification, not a state the
/// user has to close.
struct DeviceActivityView: View {
    @Bindable var model: AppModel
    let geometry: SurfaceGeometry

    /// Drives the entry spin. Kept local so the animation runs from the moment
    /// the view becomes visible rather than from some shared clock.
    @State private var spin = false
    @State private var ringProgress: Double = 0

    private var activity: AppModel.DeviceActivity? { model.deviceActivity }

    private var padding: CGFloat { geometry.contentInset(for: .activity) + 10 }

    var body: some View {
        HStack(spacing: 0) {
            deviceIcon
                .frame(width: geometry.wingWidth(for: .activity, padding: padding), alignment: .leading)

            // The notch itself — a hole in the display, so nothing is drawn here.
            Color.clear.frame(width: geometry.notchSize.width)

            trailing
                .frame(width: geometry.wingWidth(for: .activity, padding: padding), alignment: .trailing)
        }
        .padding(.horizontal, padding)
        .padding(.bottom, SurfaceGeometry.peekDrop)
        .frame(maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
        .onAppear { animateIn() }
        .onChange(of: activity?.id) { _, _ in animateIn() }
    }

    /// The device glyph, rotated in 3D on entry.
    ///
    /// A full turn about the Y axis with a little perspective, easing out so it
    /// settles rather than stopping dead. `rotation3DEffect` is doing real
    /// perspective projection here, which is why it reads as an object turning
    /// rather than an image being squashed horizontally.
    private var deviceIcon: some View {
        // Falls back when the named symbol is missing: SF Symbol availability
        // varies by macOS version, and a missing symbol renders as nothing at
        // all rather than as an obvious placeholder.
        Image(systemName: Self.resolvedSymbol(activity?.symbol))
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(.white)
            .rotation3DEffect(
                .degrees(spin ? 360 : 0),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.6
            )
            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
    }

    @ViewBuilder
    private var trailing: some View {
        if let activity {
            if let level = activity.batteryLevel {
                BatteryRing(level: level, progress: ringProgress)
                    .frame(width: 26, height: 26)
            } else {
                // No battery reading available — show the device name instead of
                // an empty ring, which would look like a failed load.
                Text(activity.name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color(white: 0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
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
        // two animations do not compete for the same frames.
        withAnimation(.easeOut(duration: 1.1).delay(0.12)) { spin = true }
        withAnimation(.easeOut(duration: 0.9).delay(0.24)) { ringProgress = 1 }
    }
}

/// A circular charge indicator.
struct BatteryRing: View {
    /// Charge, 0...1.
    let level: Double
    /// How much of the ring has been drawn, for the entry animation.
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: 3)

            Circle()
                .trim(from: 0, to: level * progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text(verbatim: "\(Int((level * 100).rounded()))")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color(white: 0.9))
                .opacity(progress)
        }
        .accessibilityElement()
        .accessibilityLabel("Battery \(Int(level * 100)) percent")
    }

    /// Green until it is genuinely worth worrying about.
    private var tint: Color {
        switch level {
        case ..<0.15: Theme.Palette.failure
        case ..<0.30: Theme.Palette.running
        default: Theme.Palette.success
        }
    }
}
