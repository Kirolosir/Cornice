import SwiftUI
import CorniceKit

/// Lightweight machine telemetry.
///
/// Deliberately small: this is context you glance at, not a replacement for
/// Activity Monitor. Anything needing a per-process table is out of scope.
struct StatsPane: View {
    @Bindable var model: AppModel

    private var latest: TelemetrySample { model.telemetry.latest ?? .empty }

    var body: some View {
        VStack(spacing: 8) {
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

            if let profile = model.notchProfile, let hardware = model.hardware {
                HStack(spacing: 6) {
                    Text(hardware.displayName)
                    Text("·")
                    Text(verbatim: "notch \(Int(profile.rect.width))×\(Int(profile.rect.height)) pt")
                    Spacer()
                    Text(profile.source == .measured ? "measured" : profile.source.rawValue)
                }
                .font(Theme.Typeface.monoSmall)
                .foregroundStyle(Color(white: 0.38))
            }

            Spacer(minLength: 0)
        }
    }

    private func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

struct MetricCard: View {
    let title: String
    let symbol: String
    let value: String
    var caption: String?
    let tint: Color
    let series: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5))
                    .foregroundStyle(tint)
                Text(title)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Color(white: 0.6))
                Spacer()
            }

            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(Theme.Motion.telemetry, value: value)

            Sparkline(values: series, tint: tint)
                .frame(height: 26)

            if let caption {
                Text(caption)
                    .font(Theme.Typeface.monoSmall)
                    .foregroundStyle(Color(white: 0.4))
                    .lineLimit(1)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }
}

struct NetworkCard: View {
    let inRate: Double
    let outRate: Double
    let inSeries: [Double]
    let outSeries: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color(white: 0.6))
                Text("Network")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Color(white: 0.6))
                Spacer()
                rate("arrow.down", Format.rate(bytesPerSecond: inRate), Theme.Palette.networkIn)
                rate("arrow.up", Format.rate(bytesPerSecond: outRate), Theme.Palette.networkOut)
            }

            ZStack {
                Sparkline(values: inSeries, tint: Theme.Palette.networkIn)
                Sparkline(values: outSeries, tint: Theme.Palette.networkOut)
            }
            .frame(height: 28)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
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
struct Sparkline: View {
    let values: [Double]
    let tint: Color
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
                    // Inset by a point so a value pinned at 0 or 1 still shows
                    // a stroke rather than being clipped.
                    y: size.height - 1 - (size.height - 2) * value
                )
            }

            var line = Path()
            line.move(to: point(0))
            for index in 1..<values.count { line.addLine(to: point(index)) }

            var fill = line
            fill.addLine(to: CGPoint(x: point(values.count - 1).x, y: size.height))
            fill.addLine(to: CGPoint(x: point(0).x, y: size.height))
            fill.closeSubpath()

            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.34), tint.opacity(0.02)]),
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
