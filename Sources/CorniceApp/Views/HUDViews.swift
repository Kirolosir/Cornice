import SwiftUI
import CorniceKit

/// Every system HUD, drawn inside the same surface as everything else.
///
/// Two layouts cover all eleven. A **short pill** is no taller than the notch
/// band, so every scrap of it lives in the two margins either side of the hole.
/// Anything taller reserves that band and starts on the first clear row below
/// it. Colour appears only on a value or a glyph, never on a block of text.
struct HUDView: View {
    let content: HUDContent
    let geometry: SurfaceGeometry
    @Bindable var model: AppModel
    let clock: FrameClock

    private var kind: HUDKind { content.kind }
    private var ink: Theme.Ink { .dark }

    /// Distance from the *surface's* edge: past the cove, then the HUD's own
    /// padding.
    private var sideInset: CGFloat {
        geometry.flareRadius(for: .hud(kind)) + kind.contentPadding
    }

    var body: some View {
        Group {
            switch content {
            case .noInternet: noInternet
            case .filesReceived(let files): filesReceived(files)
            case .timerRunning(let id, let label, let isRunning, let isFinished):
                timerRunning(id: id, label: label, isRunning: isRunning, isFinished: isFinished)
            case .charging(let level): charging(level)
            case .batteryLow(let level): batteryLow(level)
            case .fullBattery: fullBattery
            case .vpn(let name, let since): vpn(name: name, since: since)
            case .volume(let device, let level, let isMuted):
                volume(device: device, level: level, isMuted: isMuted)
            case .download(let name, let progress, let rate):
                download(name: name, progress: progress, bytesPerSecond: rate)
            case .doNotDisturb: doNotDisturb
            case .handoff: handoff
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Layout scaffolding

    /// A pill shorter than the notch: two margins and a hole between them.
    private func shortPill<L: View, T: View>(
        @ViewBuilder leading: () -> L,
        @ViewBuilder trailing: () -> T
    ) -> some View {
        HStack(spacing: 0) {
            leading().padding(.leading, sideInset)
            Spacer(minLength: 0)
            trailing().padding(.trailing, geometry.flareRadius(for: .hud(kind)) + 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// A panel that starts on the first clear row below the band.
    private func panel<Content: View>(
        trailingPadding: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.leading, sideInset)
            .padding(.trailing, trailingPadding.map { geometry.flareRadius(for: .hud(kind)) + $0 } ?? sideInset)
            .padding(.top, kind.contentTop)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - No internet

    private var noInternet: some View {
        panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Theme.Palette.green)
                        .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("No Internet Connection")
                            .font(Theme.Typeface.hudTitle)
                            .tracking(-0.17)
                            .foregroundStyle(ink.primary)
                        Text("Connect to Wi‑Fi, Ethernet, or\nPersonal Hotspot to continue.")
                            .font(Theme.Typeface.status.weight(.regular))
                            .lineSpacing(3)
                            .foregroundStyle(ink.at(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 12) {
                    Button("OK") { model.dismissHUD() }
                        .buttonStyle(SoftButtonStyle(height: 32, cornerRadius: 9, pressedScale: 0.96))
                    Button("Settings") { model.openNetworkSettings() }
                        .buttonStyle(SoftButtonStyle(
                            height: 32, cornerRadius: 9,
                            fill: Theme.Palette.blue, pressedScale: 0.96
                        ))
                }
                .font(Theme.Typeface.body)
            }
        }
    }

    // MARK: - Files received

    private func filesReceived(_ files: [String]) -> some View {
        ZStack(alignment: .topLeading) {
            // The header sits in the band's two margins, because the middle of
            // that row is the hole.
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "tray.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ink.at(0.82))
                    Text(verbatim: "\(files.count)")
                        .font(Theme.Typeface.hudInline)
                        .foregroundStyle(ink.at(0.82))
                }
                .padding(.leading, sideInset)

                Spacer(minLength: 0)

                Button { model.dismissHUD() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .medium))
                        Text("All").font(Theme.Typeface.hudInline)
                    }
                    .foregroundStyle(ink.at(0.82))
                }
                .buttonStyle(PressScaleStyle(pressedScale: 0.9))
                .padding(.trailing, sideInset)
            }
            .frame(height: geometry.bandHeight)

            HStack(alignment: .top, spacing: 12) {
                ForEach(files.prefix(5), id: \.self) { file in
                    ReceivedFileTile(name: file) { model.dismissHUD() }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, sideInset)
            .padding(.trailing, sideInset)
            .padding(.top, kind.contentTop)
        }
    }

    // MARK: - Timer running

    private func timerRunning(id: UUID, label: String, isRunning: Bool, isFinished: Bool) -> some View {
        panel {
            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { model.toggleTimer(id) } label: {
                        Image(systemName: isRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(FilledCircleButtonStyle(
                        fill: Theme.Palette.orangeDark, hoverFill: Theme.Palette.orangeDeep
                    ))
                    .disabled(isFinished)

                    Button { model.removeTimer(id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(FilledCircleButtonStyle(
                        fill: ink.at(0.18), hoverFill: ink.at(0.26)
                    ))
                }

                Spacer(minLength: 0)

                HStack(alignment: .firstTextBaseline, spacing: 11) {
                    Text(label)
                        .font(Theme.Typeface.body)
                        .foregroundStyle(ink.at(0.58))
                        .lineLimit(1)
                    Text(HUDTimerReading.of(model, tick: clock.tick))
                        .font(Theme.Typeface.timerHUD)
                        .tracking(-0.85)
                        .foregroundStyle(isFinished ? Theme.Palette.green : Theme.Palette.orange)
                }
            }
        }
    }

    // MARK: - Power

    private func charging(_ level: Double) -> some View {
        shortPill {
            Text("Charging")
                .font(Theme.Typeface.hudInline)
                .foregroundStyle(ink.primary)
        } trailing: {
            HStack(spacing: 8) {
                Text(verbatim: "\(Int((level * 100).rounded()))%")
                    .font(Theme.Typeface.hudInline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.green)
                BatteryGlyph(level: level, tint: Theme.Palette.green)
            }
        }
    }

    private func batteryLow(_ level: Double) -> some View {
        panel(trailingPadding: 18) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Battery Low")
                            .font(Theme.Typeface.bodyStrong)
                            .tracking(-0.16)
                            .foregroundStyle(ink.primary)
                        Text(verbatim: "\(Int((level * 100).rounded()))%")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.Palette.red)
                    }
                    Text("Turn on Low Power Mode or it\nis recommended to charge it.")
                        .font(Theme.Typeface.hudBody)
                        .lineSpacing(4)
                        .foregroundStyle(ink.at(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                LargeBatteryGlyph(fraction: level, tint: Theme.Palette.red, glowing: true)
            }
        }
    }

    private var fullBattery: some View {
        panel(trailingPadding: 18) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Full Battery")
                            .font(Theme.Typeface.bodyStrong)
                            .tracking(-0.16)
                            .foregroundStyle(ink.primary)
                        Text("100%")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.Palette.green)
                    }
                    Text("Your Mac is fully charged.")
                        .font(Theme.Typeface.hudBody)
                        .lineSpacing(4)
                        .foregroundStyle(ink.at(0.62))
                }

                Spacer(minLength: 0)

                LargeBatteryGlyph(fraction: 0.83, tint: Theme.Palette.green, glowing: false)
            }
        }
    }

    // MARK: - VPN

    private func vpn(name: String, since: Date) -> some View {
        panel {
            HStack(spacing: 14) {
                // A generic shield rather than an app icon: nothing in the
                // networking stack says *which* client raised the tunnel, and
                // guessing at a vendor's logo would be worse than not showing one.
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Color(white: 0.12))
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(white: 0.93))
                    )
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Connected")
                        .font(Theme.Typeface.status)
                        .foregroundStyle(ink.at(0.62))
                    Text(name)
                        .font(Theme.Typeface.deviceName)
                        .tracking(-0.135)
                        .foregroundStyle(ink.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(Format.duration(Date().timeIntervalSince(since)))
                    .font(Theme.Typeface.sessionClock)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.orange)
            }
        }
    }

    // MARK: - Volume

    private func volume(device: String, level: Double, isMuted: Bool) -> some View {
        panel {
            VStack(alignment: .leading, spacing: 12) {
                Text(device)
                    .font(Theme.Typeface.bodyStrong)
                    .tracking(-0.13)
                    .foregroundStyle(ink.primary)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ink.primary)
                        .frame(width: 17, alignment: .leading)

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(ink.at(0.18))
                            Capsule()
                                .fill(Theme.Palette.orangeDeep)
                                .frame(width: max(0, proxy.size.width * (isMuted ? 0 : level)))
                        }
                        .frame(height: 7)
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 14)

                    Text(verbatim: "\(Int((level * 100).rounded()))")
                        .font(Theme.Typeface.hudInline)
                        .monospacedDigit()
                        .foregroundStyle(ink.primary)
                        .frame(width: 26, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Download

    private func download(name: String, progress: Double?, bytesPerSecond: Double) -> some View {
        panel {
            HStack(spacing: 14) {
                DocumentGlyph()

                VStack(alignment: .leading, spacing: 2) {
                    // Truncated from the *head*, so the extension stays readable —
                    // which is the part of a long filename that tells you what
                    // just arrived.
                    Text(name)
                        .font(Theme.Typeface.bodyStrong)
                        .foregroundStyle(ink.primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text("Downloads")
                        .font(Theme.Typeface.status.weight(.regular))
                        .foregroundStyle(ink.at(0.60))
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                        .font(.system(size: 13.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Palette.blueLight)
                    Text(Format.rate(bytesPerSecond: bytesPerSecond))
                        .font(Theme.Typeface.stamp)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Palette.blueLight.opacity(0.75))
                }
            }
        }
    }

    // MARK: - Short toggles

    private var doNotDisturb: some View {
        shortPill {
            Image(systemName: "moon.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Palette.purple)
        } trailing: {
            Text("On")
                .font(Theme.Typeface.hudInline)
                .foregroundStyle(Theme.Palette.purple)
        }
    }

    private var handoff: some View {
        shortPill {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Palette.green)
        } trailing: {
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

// MARK: - Pieces

/// The small battery outline used by the charging pill.
struct BatteryGlyph: View {
    let level: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .strokeBorder(Color(white: 1, opacity: 0.4), lineWidth: 1)
                .frame(width: 24, height: 12)
                .overlay(alignment: .leading) {
                    // The usable width is the shell minus its own 1 pt stroke on
                    // both sides and the 1.5 pt gap inside that, or a full
                    // battery draws over its own outline.
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tint)
                        .frame(width: max(1, 19 * level), height: 9)
                        .padding(.leading, 2.5)
                }
            Capsule()
                .fill(Color(white: 1, opacity: 0.4))
                .frame(width: 2, height: 5)
        }
    }
}

/// The 48 × 24 battery used by the charge notices.
struct LargeBatteryGlyph: View {
    let fraction: Double
    let tint: Color
    let glowing: Bool

    var body: some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(tint.opacity(0.6), lineWidth: 1.6)
                .frame(width: 41, height: 22)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tint)
                        .frame(width: max(4, (41 - 6) * fraction), height: 15)
                        .padding(.leading, 3)
                }
            Capsule()
                .fill(tint.opacity(0.7))
                .frame(width: 3, height: 8)
        }
        .shadow(color: glowing ? tint.opacity(0.45) : .clear, radius: glowing ? 7 : 0)
    }
}

/// A document, for the download and received-file HUDs.
struct DocumentGlyph: View {
    var width: CGFloat = 28
    var height: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color(white: 0.96))
            .frame(width: width, height: height)
            .overlay(alignment: .topTrailing) {
                // The turned corner, drawn as a darker triangle.
                Path { path in
                    path.move(to: CGPoint(x: width * 0.72, y: 0))
                    path.addLine(to: CGPoint(x: width, y: height * 0.22))
                    path.addLine(to: CGPoint(x: width * 0.72, y: height * 0.22))
                    path.closeSubpath()
                }
                .fill(Color(white: 0.72))
                .frame(width: width, height: height)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2.5) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(Color(white: 0.68))
                            .frame(width: index == 2 ? width * 0.4 : width * 0.62, height: 1.5)
                    }
                }
                .padding(.leading, width * 0.18)
                .padding(.bottom, height * 0.22)
            }
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
    }
}

/// One tile in the received-files HUD.
struct ReceivedFileTile: View {
    let name: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            DocumentGlyph(width: 30, height: 38)
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(white: 1, opacity: 0.85))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 6)
        .frame(width: 88, height: 96)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 1, opacity: 0.07))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color(white: 1, opacity: 0.1)).frame(height: 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(Color(red: 0.47, green: 0.47, blue: 0.50, opacity: 0.75)))
            }
            .buttonStyle(PressScaleStyle(pressedScale: 0.86))
            .offset(x: 5, y: -5)
        }
    }
}


/// The countdown inside the timer HUD, read against the frame clock.
enum HUDTimerReading {
    @MainActor
    static func of(_ model: AppModel, tick: Int) -> String {
        _ = tick
        return model.hudTimerReading
    }
}
