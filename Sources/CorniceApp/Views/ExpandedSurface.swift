import SwiftUI
import CorniceKit

/// The open panel: a tab strip and one module pane.
struct ExpandedSurface: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            // Reserve the notch's own height. The panel hangs below the notch
            // rather than behind it, so this strip is the physical cut-out.
            Color.clear
                .frame(height: (model.notchProfile?.rect.height ?? 32) + Theme.Metrics.panelDrop)

            VStack(spacing: 10) {
                TabStrip(model: model)
                pane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(Theme.Metrics.panelPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                PanelShape(cornerRadius: Theme.Metrics.panelCornerRadius)
                    .fill(Theme.Palette.panel(scheme))
                    .overlay(
                        PanelShape(cornerRadius: Theme.Metrics.panelCornerRadius)
                            .strokeBorder(Theme.Palette.hairline(scheme), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.22), radius: 24, y: 10)
            )
            .overlay(alignment: .top) {
                if let confirmation = model.pendingConfirmation {
                    ConfirmationOverlay(model: model, confirmation: confirmation)
                }
            }
            .overlay(alignment: .bottom) {
                if let description = model.copyConfirmation {
                    CopyToast(description: description)
                        .padding(.bottom, 10)
                }
            }
        }
        .animation(Theme.Motion.contentSwap, value: model.activeModule)
        .animation(Theme.Motion.contentSwap, value: model.pendingConfirmation?.id)
    }

    @ViewBuilder
    private var pane: some View {
        switch model.activeModule {
        case .repository: RepositoryPane(model: model)
        case .servers: ServersPane(model: model)
        case .github: GitHubPane(model: model)
        case .telemetry: TelemetryPane(model: model)
        case .containers: ContainersPane(model: model)
        case .commands: CommandsPane(model: model)
        case .focus: FocusPane(model: model)
        }
    }
}

/// Module tabs, plus the status cluster on the right.
struct TabStrip: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    /// Tabs in a fixed order, filtered to the enabled set — so a module's
    /// position never shifts when another is toggled, and muscle memory holds.
    private var modules: [ModuleKind] {
        ModuleKind.allCases.filter { model.preferences.enabledModules.contains($0) }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(modules) { module in
                TabButton(
                    module: module,
                    isActive: model.activeModule == module,
                    badge: badge(for: module)
                ) {
                    model.select(module: module)
                }
            }

            Spacer(minLength: 8)

            if let battery = model.telemetry.latest?.battery {
                BatteryIndicator(battery: battery)
            }

            Button {
                model.collapse()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(PanelButtonStyle())
            .help("Collapse (Esc)")
            .accessibilityLabel("Collapse panel")
        }
        .frame(height: Theme.Metrics.tabStripHeight)
    }

    /// A dot on a tab whose module needs attention, so a problem is visible
    /// even while a different pane is open.
    private func badge(for module: ModuleKind) -> Color? {
        switch module {
        case .repository:
            guard let tree = model.repository.value?.workingTree, !tree.isClean else { return nil }
            return Theme.Palette.running
        case .github:
            if model.github.error != nil { return Theme.Palette.failure }
            return (model.github.value?.failedRuns.isEmpty == false) ? Theme.Palette.failure : nil
        case .servers:
            guard let ports = model.ports.value else { return nil }
            return ports.contains(where: \.isActive) ? Theme.Palette.success : nil
        case .commands:
            return model.commandRuns.contains { !$0.state.isTerminal } ? Theme.Palette.running : nil
        case .focus:
            return model.focus.state.isRunning ? Theme.Palette.accent : nil
        case .containers, .telemetry:
            return nil
        }
    }
}

struct TabButton: View {
    let module: ModuleKind
    let isActive: Bool
    let badge: Color?
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: module.symbol)
                    .font(.system(size: 11, weight: .medium))
                if isActive {
                    Text(module.title)
                        .font(Theme.Typeface.caption)
                        .fixedSize()
                }
            }
            .padding(.horizontal, isActive ? 9 : 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background)
            )
            .overlay(alignment: .topTrailing) {
                if let badge, !isActive {
                    Circle()
                        .fill(badge)
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            isActive
                ? Theme.Palette.primaryText(scheme)
                : Theme.Palette.secondaryText(scheme)
        )
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.contentSwap, value: isActive)
        .help(module.title)
        .accessibilityLabel(module.title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private var background: Color {
        let base = scheme == .dark ? Color.white : Color.black
        if isActive { return base.opacity(0.10) }
        if isHovering { return base.opacity(0.06) }
        return .clear
    }
}

struct BatteryIndicator: View {
    let battery: BatteryState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
            Text("\(Int((battery.level * 100).rounded()))%")
                .font(Theme.Typeface.monoSmall)
                .foregroundStyle(Theme.Palette.secondaryText(scheme))
        }
        .help(helpText)
        .accessibilityLabel("Battery \(Int(battery.level * 100)) percent")
    }

    private var symbol: String {
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.level {
        case ..<0.15: return "battery.0"
        case ..<0.45: return "battery.25"
        case ..<0.80: return "battery.75"
        default: return "battery.100"
        }
    }

    /// Red only when genuinely low *and* not charging — a 10% battery on the
    /// charger is not a problem, and colouring it red would train the user to
    /// ignore the indicator.
    private var tint: Color {
        if battery.isCharging { return Theme.Palette.success }
        return battery.level < 0.15 ? Theme.Palette.failure : Theme.Palette.neutral
    }

    private var helpText: String {
        guard let minutes = battery.minutesRemaining else {
            return battery.isCharging ? "Charging" : "On battery"
        }
        let formatted = Format.duration(TimeInterval(minutes * 60))
        return battery.isCharging ? "\(formatted) until full" : "\(formatted) remaining"
    }
}

/// Brief acknowledgement after a copy.
struct CopyToast: View {
    let description: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text("\(description) copied")
            .font(Theme.Typeface.caption)
            .foregroundStyle(Theme.Palette.primaryText(scheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.opacity.combined(with: .offset(y: 6)))
            .animation(Theme.Motion.contentSwap, value: description)
    }
}
