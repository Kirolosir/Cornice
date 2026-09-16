import SwiftUI
import CorniceKit

struct CommandsPane: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneHeader(title: "Commands", subtitle: subtitle) {
                IconButton(symbol: "slider.horizontal.3", help: "Configure commands") {
                    SettingsWindow.shared.show(model: model, tab: .commands)
                }
            }

            if model.preferences.commands.isEmpty {
                EmptyStateView(
                    symbol: "terminal",
                    message: "No commands configured.\nAdd the ones you run most often.",
                    actionTitle: "Configure…"
                ) { SettingsWindow.shared.show(model: model, tab: .commands) }
            } else {
                commandGrid
                if !model.commandRuns.isEmpty {
                    runHistory
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var subtitle: String? {
        guard let running = model.commandRuns.first(where: { !$0.state.isTerminal }) else {
            return model.preferences.activeRepositoryPath.map {
                "in \(($0 as NSString).lastPathComponent)"
            }
        }
        return "Running \(running.name)…"
    }

    private var commandGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140), spacing: 6)],
            spacing: 6
        ) {
            ForEach(model.preferences.commands) { spec in
                CommandButton(spec: spec, model: model)
            }
        }
    }

    private var runHistory: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Recent")
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.Palette.tertiaryText(scheme))

            PaneList(items: Array(model.commandRuns.prefix(3))) { run in
                CommandRunRow(run: run)
            }
            .cardSurface(padding: 0)
            .frame(height: min(CGFloat(model.commandRuns.prefix(3).count), 3) * Theme.Metrics.rowHeight + 2)
        }
    }
}

struct CommandButton: View {
    let spec: CommandSpec
    @Bindable var model: AppModel

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    private var activeRun: CommandRun? {
        model.commandRuns.first { $0.specID == spec.id && !$0.state.isTerminal }
    }

    var body: some View {
        Button {
            model.run(spec)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: activeRun == nil ? "play.fill" : "circle.dotted")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(activeRun == nil ? Theme.Palette.accent : Theme.Palette.running)

                VStack(alignment: .leading, spacing: 0) {
                    Text(spec.name)
                        .font(Theme.Typeface.body)
                        .foregroundStyle(Theme.Palette.primaryText(scheme))
                        .lineLimit(1)
                    // The command itself is always visible, not hidden behind a
                    // tooltip — you should never have to hover to find out what
                    // a button will run.
                    Text(spec.displayCommand)
                        .font(Theme.Typeface.monoSmall)
                        .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                if spec.mode == .shell {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                        .help("Runs through /bin/sh")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((scheme == .dark ? Color.white : Color.black).opacity(isHovering ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline(scheme), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(activeRun != nil)
        .onHover { isHovering = $0 }
        .help(spec.displayCommand)
        .accessibilityLabel("Run \(spec.name)")
        .accessibilityHint(spec.displayCommand)
    }
}

struct CommandRunRow: View {
    let run: CommandRun
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: tint, isPulsing: !run.state.isTerminal)

            Text(run.name)
                .font(Theme.Typeface.body)
                .foregroundStyle(Theme.Palette.primaryText(scheme))
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)

            Text(detail)
                .font(Theme.Typeface.monoSmall)
                .foregroundStyle(Theme.Palette.secondaryText(scheme))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Text(Format.elapsed(run.duration))
                .font(Theme.Typeface.monoSmall)
                .foregroundStyle(Theme.Palette.tertiaryText(scheme))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(run.outputTail.isEmpty ? run.displayCommand : run.outputTail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(run.name), \(detail)")
    }

    private var detail: String {
        switch run.state {
        case .running: "running…"
        case .succeeded: run.outputTail.split(separator: "\n").last.map(String.init) ?? "succeeded"
        case .failed(let code): "exited \(code) — \(run.outputTail.split(separator: "\n").last.map(String.init) ?? "")"
        case .errored(let error): error.headline
        }
    }

    private var tint: Color {
        switch run.state {
        case .running: Theme.Palette.running
        case .succeeded: Theme.Palette.success
        case .failed, .errored: Theme.Palette.failure
        }
    }
}
