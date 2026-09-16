import SwiftUI
import CorniceKit

struct TelemetryPane: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    private var latest: TelemetrySample { model.telemetry.latest ?? .empty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneHeader(
                title: "System",
                subtitle: model.hardware?.displayName
            ) {
                if let profile = model.notchProfile {
                    GeometryBadge(profile: profile)
                }
            }

            HStack(spacing: 8) {
                MetricCard(
                    title: "CPU",
                    symbol: "cpu",
                    value: percentage(latest.cpuUsage),
                    tint: Theme.Palette.cpu,
                    series: model.telemetry.series(\.cpuUsage)
                )
                MetricCard(
                    title: "Memory",
                    symbol: "memorychip",
                    value: percentage(latest.memoryUsage),
                    caption: "\(Format.bytes(latest.memoryUsedBytes)) of \(Format.bytes(latest.memoryTotalBytes))",
                    tint: Theme.Palette.memory,
                    series: model.telemetry.series(\.memoryUsage)
                )
            }

            NetworkCard(
                inRate: latest.networkInBytesPerSecond,
                outRate: latest.networkOutBytesPerSecond,
                inSeries: model.telemetry.normalisedNetworkSeries(\.networkInBytesPerSecond),
                outSeries: model.telemetry.normalisedNetworkSeries(\.networkOutBytesPerSecond)
            )

            Spacer(minLength: 0)
        }
    }

    private func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// Shows how the notch was measured. Primarily a diagnostic, but it is also
/// the most direct answer to "does this app know what Mac I'm on?".
struct GeometryBadge: View {
    let profile: NotchProfile
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: profile.hasPhysicalNotch ? "macbook" : "display")
                .font(.system(size: 9.5))
            Text("\(Int(profile.rect.width))×\(Int(profile.rect.height))")
                .font(Theme.Typeface.monoSmall)
        }
        .foregroundStyle(Theme.Palette.tertiaryText(scheme))
        .help(helpText)
        .accessibilityLabel("Notch \(Int(profile.rect.width)) by \(Int(profile.rect.height)) points")
    }

    private var helpText: String {
        let source = switch profile.source {
        case .measured: "Measured from the display's menu-bar layout."
        case .catalogFallback: "Derived from the reported safe-area inset."
        case .syntheticCenter: "No notch on this display — centred in the menu bar."
        }
        return """
        \(Int(profile.rect.width))×\(Int(profile.rect.height)) pt \
        (\(String(format: "%.1f", profile.widthFraction * 100))% of a \(Int(profile.screenFrame.width)) pt display)
        \(source)
        """
    }
}

/// One telemetry metric: a value and a sparkline.
struct MetricCard: View {
    let title: String
    let symbol: String
    let value: String
    var caption: String?
    let tint: Color
    let series: [Double]

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5))
                    .foregroundStyle(tint)
                Text(title)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.secondaryText(scheme))
                Spacer()
            }

            Text(value)
                .font(Theme.Typeface.metric)
                .foregroundStyle(Theme.Palette.primaryText(scheme))
                // Only the number animates, and only gently: a value that
                // springs around is harder to read than one that eases.
                .contentTransition(.numericText())
                .animation(Theme.Motion.telemetry, value: value)

            Sparkline(values: series, tint: tint)
                .frame(height: 30)

            if let caption {
                Text(caption)
                    .font(Theme.Typeface.monoSmall)
                    .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }
}

struct NetworkCard: View {
    let inRate: Double
    let outRate: Double
    let inSeries: [Double]
    let outSeries: [Double]

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.Palette.neutral)
                Text("Network")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.secondaryText(scheme))

                Spacer()

                rate("arrow.down", Format.rate(bytesPerSecond: inRate), Theme.Palette.networkIn)
                rate("arrow.up", Format.rate(bytesPerSecond: outRate), Theme.Palette.networkOut)
            }

            ZStack {
                Sparkline(values: inSeries, tint: Theme.Palette.networkIn)
                Sparkline(values: outSeries, tint: Theme.Palette.networkOut)
            }
            .frame(height: 34)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network down \(Format.rate(bytesPerSecond: inRate)), up \(Format.rate(bytesPerSecond: outRate))")
    }

    private func rate(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(text).font(Theme.Typeface.monoSmall)
        }
        .foregroundStyle(tint)
    }
}

/// A filled line chart of recent samples.
///
/// Drawn with `Canvas` rather than a stack of shapes: this repaints on every
/// telemetry tick, and a `Path` per sample would allocate and diff dozens of
/// views a second for something that is ultimately one polyline.
struct Sparkline: View {
    let values: [Double]
    let tint: Color
    /// Points reserved on the x-axis, so a fresh chart draws from the right and
    /// scrolls left rather than stretching two samples across the full width.
    var capacity: Int = 48

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2 else { return }

            let step = size.width / CGFloat(max(capacity - 1, 1))
            let offset = size.width - step * CGFloat(values.count - 1)

            func point(_ index: Int) -> CGPoint {
                let value = values[index].clamped(to: 0...1)
                return CGPoint(
                    x: offset + step * CGFloat(index),
                    // Inset by a point top and bottom so a value pinned at 0 or
                    // 1 still shows a stroke rather than being clipped.
                    y: size.height - 1 - (size.height - 2) * value
                )
            }

            var line = Path()
            line.move(to: point(0))
            for index in 1..<values.count {
                line.addLine(to: point(index))
            }

            var fill = line
            fill.addLine(to: CGPoint(x: point(values.count - 1).x, y: size.height))
            fill.addLine(to: CGPoint(x: point(0).x, y: size.height))
            fill.closeSubpath()

            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.32), tint.opacity(0.02)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(line, with: .color(tint), lineWidth: 1.5)
        }
        .drawingGroup()
        .accessibilityHidden(true)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
