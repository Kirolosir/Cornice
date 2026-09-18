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

    /// All the room there is on one side of the hole.
    ///
    /// Everything here is pinned to this width. The name used to be laid out
    /// with `fixedSize`, which let it grow to whatever it wanted and run under
    /// the notch, where it can't be seen because the notch is a hole in the
    /// display rather than something drawn on top.
    private var margin: CGFloat { geometry.marginWidth(for: .activity) }

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
                    .truncationMode(.tail)
                }
            }
            .frame(width: margin, alignment: .leading)
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
    /// Falls back when the named symbol is missing: SF Symbol availability
    /// varies by macOS version, and a missing symbol renders as nothing at all
    /// rather than as an obvious placeholder.
    private var deviceIcon: some View {
        ExtrudedSymbol(
            systemName: Self.resolvedSymbol(activity?.symbol),
            size: 27,
            angle: .degrees(spin ? 360 : 0)
        )
        .frame(width: 34, height: 34)
        .shadow(color: .black.opacity(0.55), radius: 5, y: 2)
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
        // Slower than it was. A flat glyph could spin quickly and still read,
        // but the extruded one has an edge worth looking at as it goes past.
        withAnimation(.timingCurve(0.25, 0.6, 0.2, 1, duration: 1.45).delay(0.12)) { spin = true }
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

/// An SF Symbol with thickness.
///
/// A symbol is a flat shape, so rotating one about its Y axis makes it vanish
/// edge-on at ninety degrees and reads as a picture being squashed rather than
/// as an object turning. This stacks copies of the same glyph at different
/// depths, which is what `anchorZ` controls: each copy rotates about an axis a
/// little further forward or back, so the set separates as it turns and the
/// gaps between them read as the side of a solid object.
///
/// The slices are shaded back to front, dark at the rear and bright at the
/// face, so the edge catches the light the way an extrusion would.
private struct ExtrudedSymbol: View {
    let systemName: String
    let size: CGFloat
    let angle: Angle

    /// Enough slices to read as solid at this size without drawing layers
    /// nobody can distinguish. Nine is where it stopped looking striped.
    private static let slices = 9
    /// Total depth, front face to back face.
    private static let thickness: CGFloat = 7

    var body: some View {
        ZStack {
            ForEach(0..<Self.slices, id: \.self) { index in
                let depth = Double(index) / Double(Self.slices - 1)
                Image(systemName: systemName)
                    .font(.system(size: size, weight: .regular))
                    .foregroundStyle(Self.shade(at: depth))
                    .rotation3DEffect(
                        angle,
                        axis: (x: 0, y: 1, z: 0),
                        anchorZ: CGFloat(depth - 0.5) * Self.thickness,
                        perspective: 0.45
                    )
            }
        }
    }

    /// Rear slices are the shadowed inside of the extrusion; the front face
    /// takes the light. The curve is weighted so the bright band stays narrow,
    /// which is what stops it looking like a grey smear.
    private static func shade(at depth: Double) -> Color {
        Color(white: 0.28 + 0.67 * pow(depth, 1.7))
    }
}
