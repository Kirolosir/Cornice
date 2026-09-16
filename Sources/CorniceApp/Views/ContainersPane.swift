import SwiftUI
import CorniceKit

struct ContainersPane: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    private var containers: [ContainerSummary] { model.containers.value ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneHeader(
                title: "Containers",
                subtitle: subtitle,
                isBusy: model.containers.isBusy && containers.isEmpty
            ) {
                IconButton(symbol: "arrow.clockwise", help: "Refresh") {
                    model.refreshNow(.containers)
                }
            }

            switch model.dockerAvailability {
            case .notInstalled:
                // Not an error. Most developers do not run Docker, and telling
                // them something failed would be wrong.
                EmptyStateView(
                    symbol: "shippingbox",
                    message: "Docker isn't installed.\nThis panel stays out of the way until it is."
                )
            case .daemonNotRunning:
                EmptyStateView(
                    symbol: "shippingbox",
                    message: "Docker is installed but the daemon isn't running.",
                    actionTitle: "Check again"
                ) { model.refreshNow(.containers) }
            case .available:
                if let error = model.containers.error, containers.isEmpty {
                    ErrorStateView(error: error) { model.refreshNow(.containers) }
                } else if containers.isEmpty {
                    EmptyStateView(symbol: "shippingbox", message: "No running containers.")
                } else {
                    PaneList(items: containers) { container in
                        ContainerRow(container: container, model: model)
                    }
                    .cardSurface(padding: 0)
                }
            }
        }
    }

    private var subtitle: String? {
        guard model.dockerAvailability.canQuery else { return nil }
        return containers.isEmpty ? "None running" : "\(containers.count) running"
    }
}

struct ContainerRow: View {
    let container: ContainerSummary
    @Bindable var model: AppModel

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: tint, isPulsing: container.isRestarting)

            Text(container.name)
                .font(Theme.Typeface.body)
                .foregroundStyle(Theme.Palette.primaryText(scheme))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 118, alignment: .leading)

            Text(container.image)
                .font(Theme.Typeface.monoSmall)
                .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            // Only published ports are shown, because those are the only ones a
            // browser on this machine can actually reach.
            ForEach(container.publishedPorts.prefix(3), id: \.self) { port in
                Button {
                    model.openContainerPort(port)
                } label: {
                    Text(verbatim: ":\(port)")
                        .font(Theme.Typeface.monoSmall)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Theme.Palette.accent.opacity(0.16))
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.accent)
                .help("Open http://localhost:\(port)")
            }

            Text(container.status)
                .font(Theme.Typeface.caption)
                .foregroundStyle(container.isUnhealthy ? Theme.Palette.failure : Theme.Palette.tertiaryText(scheme))
                .lineLimit(1)
                .truncationMode(.tail)
                // Wide enough for docker's longest common status string,
                // "Restarting (1) 12 seconds ago", which was being clipped.
                .frame(width: 126, alignment: .trailing)

            HStack(spacing: 1) {
                IconButton(symbol: "doc.on.doc", help: "Copy container name") {
                    model.copyContainerName(container)
                }
                IconButton(symbol: "arrow.clockwise.circle", help: "Restart container") {
                    model.requestContainerAction(container, restart: true)
                }
                IconButton(symbol: "stop.circle", help: "Stop container", tint: Theme.Palette.failure) {
                    model.requestContainerAction(container, restart: false)
                }
            }
            .opacity(isHovering ? 1 : 0.45)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background((scheme == .dark ? Color.white : Color.black).opacity(isHovering ? 0.04 : 0))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Container \(container.name), \(container.status)")
    }

    private var tint: Color {
        if container.isUnhealthy { return Theme.Palette.failure }
        if container.isRestarting { return Theme.Palette.running }
        return Theme.Palette.success
    }
}
