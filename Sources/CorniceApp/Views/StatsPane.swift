import SwiftUI
import CorniceKit

/// The System module: two live cards, one exact series each.
///
/// Deliberately charts rather than rows of numbers. A number alone answers "what
/// is it now", which is the less useful question. The reason to glance at this
/// is to see whether something has *changed*, and that only exists in the shape
/// of the last minute. Rows of text here would be a failure state.
struct StatsPane: View {
    @Bindable var model: AppModel

    private var latest: TelemetrySample { model.telemetry.latest ?? .empty }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.cardGap) {
            MetricCard(
                name: "CPU",
                sub: "\(ProcessInfo.processInfo.activeProcessorCount) logical CPUs",
                value: String(Int((latest.cpuUsage * 100).rounded())),
                unit: "%",
                detail: "system load",
                series: [Series(values: model.telemetry.series(\.cpuUsage), color: Theme.Palette.cpu)]
            )

            MetricCard(
                name: "Memory",
                sub: Format.bytes(latest.memoryTotalBytes),
                value: gigabytes(latest.memoryUsedBytes),
                unit: "GB",
                detail: "\(Int((latest.memoryUsage * 100).rounded()))% used",
                series: [Series(values: model.telemetry.series(\.memoryUsage), color: Theme.Palette.memory)]
            )

        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }

}

/// One charted series.
struct Series: Equatable {
    var values: [Double]
    var color: Color
}

/// One entry in a card's legend.
struct Legend: Equatable {
    var text: String
    var color: Color
}

/// A card: header, current value, and the window that value came from.
struct MetricCard: View {
    let name: String
    let sub: String
    let value: String
    let unit: String
    let detail: String
    let series: [Series]
    var legend: [Legend] = []

    @Environment(\.colorScheme) private var scheme
    private var ink: Theme.Ink { .of(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name.uppercased())
                    .font(Theme.Typeface.cardHeader)
                    .tracking(1)
                    .foregroundStyle(ink.tertiary)
                Spacer(minLength: 0)
                Text(sub)
                    .font(Theme.Typeface.cardSub)
                    .foregroundStyle(ink.at(0.40))
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Theme.Typeface.cardValue)
                    .tracking(-0.42)
                    .foregroundStyle(ink.primary)
                    .contentTransition(.numericText())
                    .animation(Theme.Motion.telemetry, value: value)
                Text(unit)
                    .font(Theme.Typeface.status)
                    .foregroundStyle(ink.at(0.45))
                Spacer(minLength: 4)
                Text(detail)
                    .font(Theme.Typeface.cardSub.weight(.medium))
                    .foregroundStyle(ink.at(0.50))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(ink.at(0.055), in: Capsule())
            }
            .monospacedDigit()
            .padding(.top, 6)

            Spacer(minLength: 6)

            Sparkline(series: series)
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            if !legend.isEmpty {
                HStack(spacing: 10) {
                    ForEach(legend.indices, id: \.self) { index in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(legend[index].color)
                                .frame(width: 6, height: 6)
                            Text(legend[index].text)
                                .font(Theme.Typeface.monoSmall)
                                .foregroundStyle(ink.at(0.55))
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Theme.Metrics.cardHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardCornerRadius, style: .continuous)
                .fill(Theme.Palette.card(scheme))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Theme.Palette.cardHighlight(scheme))
                        .frame(height: 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardCornerRadius, style: .continuous))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) \(value) \(unit)")
    }
}

/// A filled line chart of the last 48 samples.
///
/// Drawn with `Canvas` rather than a stack of shapes: this repaints whenever a
/// sample lands, and a view per point would have SwiftUI diffing a tree for what
/// is ultimately two paths. The window *slides* (a new sample shifts the series
/// left rather than rescaling the x-axis), so the chart reads as time passing
/// rather than as a graph being redrawn.
struct Sparkline: View {
    let series: [Series]
    var capacity: Int = 48

    var body: some View {
        Canvas { context, size in
            drawGuides(in: &context, size: size)
            for entry in series {
                draw(entry, in: &context, size: size)
            }
        }
        .drawingGroup()
        .accessibilityHidden(true)
    }

    private func drawGuides(in context: inout GraphicsContext, size: CGSize) {
        for fraction in [0.25, 0.5, 0.75] {
            let y = size.height * fraction
            var guide = Path()
            guide.move(to: CGPoint(x: 0, y: y))
            guide.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(
                guide,
                with: .color(Color.primary.opacity(fraction == 0.5 ? 0.08 : 0.045)),
                style: StrokeStyle(lineWidth: 0.5, dash: [2, 3])
            )
        }
    }

    private func draw(_ entry: Series, in context: inout GraphicsContext, size: CGSize) {
        let values = entry.values.map { $0.isFinite ? $0.clamped(to: 0...1) : 0 }
        guard !values.isEmpty else { return }

        let step = size.width / CGFloat(max(capacity - 1, 1))
        // Right-aligned, so the newest sample is always against the right edge
        // and a partly-filled window fills from the right as it accumulates.
        let offset = size.width - step * CGFloat(values.count - 1)

        func point(_ index: Int) -> CGPoint {
            let value = values[index]
            return CGPoint(
                x: offset + step * CGFloat(index),
                // Inset by a point so a value pinned at 0 or 1 still shows a
                // stroke rather than being clipped against the edge.
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
                Gradient(colors: [entry.color.opacity(0.35), entry.color.opacity(0.02)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
        context.stroke(line, with: .color(entry.color), lineWidth: 1.5)

        let latest = point(values.count - 1)
        context.fill(
            Path(ellipseIn: CGRect(x: latest.x - 3, y: latest.y - 3, width: 6, height: 6)),
            with: .color(entry.color.opacity(0.22))
        )
        context.fill(
            Path(ellipseIn: CGRect(x: latest.x - 1.5, y: latest.y - 1.5, width: 3, height: 3)),
            with: .color(entry.color)
        )
    }
}
