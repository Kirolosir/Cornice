import SwiftUI
import CorniceKit

struct StatsPane: View {
    @Bindable var model: AppModel
    private var latest: TelemetrySample { model.telemetry.latest ?? .empty }

    var body: some View {
        HStack(spacing: Theme.Metrics.cardGap) {
            SystemMetricCard(
                name: "CPU", symbol: "cpu", color: Theme.Palette.cpu,
                value: latest.cpuAvailable ? String(Int((latest.cpuUsage * 100).rounded())) : "—",
                unit: "%", detail: "Across \(ProcessInfo.processInfo.activeProcessorCount) logical cores",
                samples: model.telemetry.samples, metric: .cpu,
                maximumGap: max(5, model.preferences.telemetryRefreshInterval * 2.5)
            )
            SystemMetricCard(
                name: "Memory", symbol: "memorychip", color: Theme.Palette.memory,
                value: latest.memoryAvailable ? gibibytes(latest.memoryUsedBytes) : "—",
                unit: "GiB",
                detail: latest.memoryAvailable
                    ? "\(Int((latest.memoryUsage * 100).rounded()))% of \(gibibytes(latest.memoryTotalBytes)) GiB"
                    : "Waiting for a reading",
                samples: model.telemetry.samples, metric: .memory,
                maximumGap: max(5, model.preferences.telemetryRefreshInterval * 2.5)
            )
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func gibibytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
}

private enum SystemMetric {
    case cpu, memory
    func reading(_ sample: TelemetrySample) -> Double? {
        let available = self == .cpu ? sample.cpuAvailable : sample.memoryAvailable
        let value = self == .cpu ? sample.cpuUsage : sample.memoryUsage
        return available && value.isFinite ? value.clamped(to: 0...1) : nil
    }
}

private struct SystemMetricCard: View {
    let name: String
    let symbol: String
    let color: Color
    let value: String
    let unit: String
    let detail: String
    let samples: [TelemetrySample]
    let metric: SystemMetric
    let maximumGap: TimeInterval
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var ink: Theme.Ink { .of(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(color)
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ink.secondary)
                Spacer()
                Text("0–100%")
                    .font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundStyle(ink.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 27, weight: .medium, design: .rounded))
                    .tracking(-0.7)
                    .foregroundStyle(ink.primary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : Theme.Motion.telemetry, value: value)
                Text(unit)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ink.secondary)
            }
            .monospacedDigit()
            .padding(.top, 5)
            Text(detail)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(ink.tertiary)
                .lineLimit(1)
                .padding(.top, 1)
            Spacer(minLength: 5)
            SystemHistoryChart(samples: samples, metric: metric, color: color, maximumGap: maximumGap)
                .frame(height: 40)
            HStack {
                Text("−60s")
                Spacer()
                Text(value == "—" ? "Waiting" : "Now")
            }
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(ink.tertiary)
            .padding(.top, 3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Theme.Metrics.cardHeight)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.Palette.card(scheme))
                .overlay {
                    LinearGradient(colors: [color.opacity(0.09), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [ink.at(0.12), ink.at(0.035)],
                                                    startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(value == "—" ? "unavailable" : value + " " + unit), \(detail). Chart shows the last minute, from zero to one hundred percent.")
    }
}

private struct SystemHistoryChart: View {
    let samples: [TelemetrySample]
    let metric: SystemMetric
    let color: Color
    let maximumGap: TimeInterval
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            let ink = Theme.Ink.of(scheme)
            for fraction in [0.0, 0.5, 1.0] {
                let y = plot.maxY - plot.height * fraction
                var guide = Path()
                guide.move(to: CGPoint(x: plot.minX, y: y))
                guide.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(guide, with: .color(ink.at(0.09)),
                               style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            }
            guard let end = samples.last?.capturedAt else { return }
            let start = end.addingTimeInterval(-60)
            var segment: [CGPoint] = []
            var previousTime: Date?
            var latestPoint: CGPoint?

            func drawSegment(_ points: [CGPoint]) {
                guard let first = points.first, let last = points.last else { return }
                var line = Path()
                line.move(to: first)
                for point in points.dropFirst() { line.addLine(to: point) }
                var fill = line
                fill.addLine(to: CGPoint(x: last.x, y: plot.maxY))
                fill.addLine(to: CGPoint(x: first.x, y: plot.maxY))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.28), color.opacity(0.01)]),
                    startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
                context.stroke(line, with: .color(color),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            // Real dates preserve gaps from sleep and the slower closed-panel
            // polling. Never draw a line through missing or failed readings.
            for sample in samples where sample.capturedAt >= start && sample.capturedAt <= end {
                guard let value = metric.reading(sample) else {
                    drawSegment(segment); segment = []; previousTime = nil; latestPoint = nil
                    continue
                }
                if let previousTime, sample.capturedAt.timeIntervalSince(previousTime) > maximumGap {
                    drawSegment(segment); segment = []
                }
                let point = CGPoint(x: plot.minX + plot.width * sample.capturedAt.timeIntervalSince(start) / 60,
                                    y: plot.maxY - plot.height * value)
                segment.append(point)
                previousTime = sample.capturedAt
                latestPoint = point
            }
            drawSegment(segment)
            if let point = latestPoint {
                context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)),
                             with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}
