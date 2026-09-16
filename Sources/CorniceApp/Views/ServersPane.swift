import SwiftUI
import CorniceKit

struct ServersPane: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    private var statuses: [PortStatus] { model.ports.value ?? [] }
    private var activeCount: Int { statuses.filter(\.isActive).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneHeader(
                title: "Local Servers",
                subtitle: subtitle,
                isBusy: model.ports.isBusy && model.ports.value == nil
            ) {
                IconButton(symbol: "arrow.clockwise", help: "Rescan ports") {
                    model.refreshNow(.servers)
                }
            }

            if let error = model.ports.error, statuses.isEmpty {
                ErrorStateView(error: error) { model.refreshNow(.servers) }
            } else if statuses.isEmpty {
                EmptyStateView(
                    symbol: "server.rack",
                    message: "No ports are being monitored.\nAdd some in Settings."
                )
            } else {
                PaneList(items: statuses) { status in
                    PortRow(status: status, model: model)
                }
                .cardSurface(padding: 0)
            }
        }
    }

    private var subtitle: String {
        guard !statuses.isEmpty else { return "Nothing configured" }
        return activeCount == 0
            ? "\(statuses.count) watched · none listening"
            : "\(activeCount) of \(statuses.count) listening"
    }
}

struct PortRow: View {
    let status: PortStatus
    @Bindable var model: AppModel

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: status.isActive ? Theme.Palette.success : Theme.Palette.neutral.opacity(0.4))

            Text(verbatim: ":\(status.port)")
                .font(Theme.Typeface.mono)
                .foregroundStyle(Theme.Palette.primaryText(scheme))
                .frame(width: 46, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                Text(status.label ?? "—")
                    .font(Theme.Typeface.body)
                    .foregroundStyle(Theme.Palette.secondaryText(scheme))
                    .lineLimit(1)
            }
            .frame(width: 112, alignment: .leading)

            if let listener = status.listener {
                HStack(spacing: 5) {
                    Text(listener.command)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.primaryText(scheme))
                        .lineLimit(1)
                    Text(verbatim: "pid \(listener.pid)")
                        .font(Theme.Typeface.monoSmall)
                        .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                    if let uptime = listener.uptime {
                        Text(verbatim: "· up \(Format.uptime(uptime))")
                            .font(Theme.Typeface.monoSmall)
                            .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                    }
                    // A dev server bound to every interface is reachable from
                    // the local network, which is rarely intended.
                    if listener.isPubliclyBound {
                        Image(systemName: "network")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.Palette.running)
                            .help("Bound to all interfaces — reachable from your network")
                    }
                }
            } else {
                Text("not listening")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText(scheme))
            }

            Spacer(minLength: 4)

            if status.isActive {
                HStack(spacing: 1) {
                    IconButton(symbol: "arrow.up.forward.square", help: "Open in browser") {
                        model.openPort(status)
                    }
                    IconButton(symbol: "doc.on.doc", help: "Copy localhost URL") {
                        model.copyPortURL(status)
                    }
                    IconButton(
                        symbol: "stop.circle",
                        help: "Stop this server",
                        tint: Theme.Palette.failure
                    ) {
                        model.requestTerminate(status)
                    }
                }
                .opacity(isHovering ? 1 : 0.45)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            (scheme == .dark ? Color.white : Color.black)
                .opacity(isHovering ? 0.04 : 0)
        )
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.contentSwap, value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let listener = status.listener else {
            return "Port \(status.port), \(status.label ?? "unlabelled"), not listening"
        }
        return "Port \(status.port), \(listener.command), process \(listener.pid), listening"
    }
}
