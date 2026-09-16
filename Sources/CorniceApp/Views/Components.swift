import SwiftUI
import CorniceKit

/// Header shown at the top of every pane.
struct PaneHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var isBusy: Bool = false
    @ViewBuilder var trailing: Trailing

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Typeface.title)
                    .foregroundStyle(Theme.Palette.primaryText(scheme))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // A spinner that only appears on a *first* load. A refresh over
            // existing data shows nothing, because flashing a spinner every few
            // seconds over data that is already correct is pure noise.
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }

            Spacer(minLength: 4)
            trailing
        }
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, isBusy: Bool = false) {
        self.init(title: title, subtitle: subtitle, isBusy: isBusy) { EmptyView() }
    }
}

/// Shown when a module has nothing to display yet.
///
/// Always says what to do next rather than just "nothing here" — an empty state
/// that does not offer an action is a dead end.
struct EmptyStateView: View {
    let symbol: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.Palette.tertiaryText(scheme))
            Text(message)
                .font(Theme.Typeface.body)
                .foregroundStyle(Theme.Palette.secondaryText(scheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PanelButtonStyle(tint: Theme.Palette.accent))
                    .font(Theme.Typeface.body)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}

/// Shown when a module failed.
///
/// One failing integration is isolated to its own pane: it renders its error,
/// keeps whatever data it last had, and every other module carries on.
struct ErrorStateView: View {
    let error: ServiceError
    var lastUpdated: Date?
    var retry: (() -> Void)?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(error.headline)
                    .font(Theme.Typeface.body)
                    .foregroundStyle(Theme.Palette.primaryText(scheme))
            }

            Text(error.detail)
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.Palette.secondaryText(scheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)

            HStack(spacing: 8) {
                // Retry is only offered when retrying could actually work.
                // A "Retry" button next to "git is not installed" is a lie.
                if let retry, error.isRetryable {
                    Button("Retry", action: retry)
                        .buttonStyle(PanelButtonStyle(tint: Theme.Palette.accent))
                }
                if let lastUpdated {
                    Text("Last updated \(Format.relative(since: lastUpdated)) ago")
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                }
            }
            .font(Theme.Typeface.body)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    private var symbol: String {
        switch error {
        case .offline: "wifi.slash"
        case .rateLimited: "hourglass"
        case .unauthorized: "lock"
        case .toolUnavailable: "questionmark.folder"
        default: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch error {
        case .offline, .rateLimited: Theme.Palette.running
        default: Theme.Palette.failure
        }
    }
}

/// A key/value row.
struct DetailRow<Accessory: View>: View {
    let label: String
    let value: String
    var valueFont: Font = Theme.Typeface.body
    var tint: Color?
    @ViewBuilder var accessory: Accessory

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                .frame(width: 74, alignment: .leading)

            Text(value)
                .font(valueFont)
                .foregroundStyle(tint ?? Theme.Palette.primaryText(scheme))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 4)
            accessory
        }
        .frame(height: 20)
    }
}

extension DetailRow where Accessory == EmptyView {
    init(label: String, value: String, valueFont: Font = Theme.Typeface.body, tint: Color? = nil) {
        self.init(label: label, value: value, valueFont: valueFont, tint: tint) { EmptyView() }
    }
}

/// A small icon button used in list rows.
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill((scheme == .dark ? Color.white : Color.black).opacity(isHovering ? 0.10 : 0))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? Theme.Palette.secondaryText(scheme))
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A coloured status pip with an optional pulse for in-progress states.
struct StatusDot: View {
    let color: Color
    var isPulsing: Bool = false
    @State private var phase = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(isPulsing && phase ? 0.35 : 1)
            .onAppear {
                guard isPulsing else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    phase = true
                }
            }
    }
}

/// A list of rows with hairline separators.
///
/// Scrolls only when it has to. A short list — which is the usual case for
/// ports, containers, and workflow runs — is laid out as a plain stack, which
/// avoids a scroll view that cannot scroll, keeps the rows reachable by
/// keyboard, and lets the pane be rendered offscreen (`--capture-docs` uses
/// `ImageRenderer`, which does not lay out `ScrollView` content).
struct PaneList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    /// Rows shown before the list starts scrolling.
    var maxVisibleRows: Int = 5
    @ViewBuilder var row: (Item) -> Row

    @Environment(\.colorScheme) private var scheme

    private var needsScrolling: Bool { items.count > maxVisibleRows }

    var body: some View {
        if needsScrolling {
            ScrollView(.vertical) {
                stack
            }
            .scrollIndicators(.automatic)
        } else {
            stack
        }
    }

    private var stack: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.Palette.hairline(scheme))
                        .frame(height: 1)
                }
                row(item)
                    .frame(height: Theme.Metrics.rowHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
