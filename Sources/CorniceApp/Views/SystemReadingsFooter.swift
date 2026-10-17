import SwiftUI
import CorniceKit

struct SystemReadingsFooter: View {
    @Bindable var model: AppModel
    let sample: TelemetrySample
    @State private var showingDetails = false
    @Environment(\.colorScheme) private var scheme
    private var ink: Theme.Ink { .of(scheme) }
    private var pressureColor: Color {
        switch sample.memoryPressure { case .normal: .green; case .warning: .orange; case .critical: .red; case nil: .secondary }
    }

    var body: some View {
        HStack(spacing: 10) {
            Label("Pressure: \(sample.memoryPressure?.title ?? "—")", systemImage: "memorychip")
                .foregroundStyle(pressureColor)
            Spacer(minLength: 0)
            if let battery = sample.battery {
                Label("\(Int((battery.level * 100).rounded()))% · \(battery.isCharging ? "Charging" : battery.isPluggedIn ? "On power" : "Battery")",
                      systemImage: battery.isCharging ? "battery.100percent.bolt" : batterySymbol(battery.level))
                Text(battery.condition.title).foregroundStyle(ink.tertiary)
            } else {
                Text("Battery unavailable").foregroundStyle(ink.tertiary)
            }
            Button { showingDetails.toggle() } label: { Image(systemName: "info.circle").frame(width: 24, height: 24) }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Explain system readings")
                .popover(isPresented: $showingDetails) { details }
        }
        .font(.system(size: 10, weight: .medium))
        .lineLimit(1)
        .frame(height: 26)
        .onChange(of: showingDetails) { _, visible in
            model.isPresentingPopover = visible
            if !visible { model.onPopoverClosed?() }
        }
        .onDisappear { model.isPresentingPopover = false }
    }

    private func batterySymbol(_ level: Double) -> String {
        switch level {
        case ..<0.125: "battery.0percent"
        case ..<0.375: "battery.25percent"
        case ..<0.625: "battery.50percent"
        case ..<0.875: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About these readings").font(.headline)
            Text("CPU shows the share of total processor capacity in use. The charts cover the last minute.")
            Text("Memory used includes app memory, wired memory and compressed memory. A high percentage alone doesn't mean your Mac is struggling; memory pressure is the better sign.")
            LabeledContent("Memory pressure", value: sample.memoryPressure?.title ?? "Unavailable")
            if let battery = sample.battery {
                Divider()
                LabeledContent("Battery condition", value: battery.condition.title)
                Text(battery.powerDescription)
                Text("Time remaining is a changing estimate. Cornice leaves missing readings unavailable instead of guessing.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(18)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }
}
