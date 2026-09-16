import SwiftUI
import CorniceKit

struct GitHubPane: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    private var digest: GitHubDigest? { model.github.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneHeader(
                title: "GitHub",
                subtitle: subtitle,
                isBusy: model.github.isBusy && digest == nil
            ) {
                if let rateLimit = digest?.rateLimit {
                    RateLimitGauge(snapshot: rateLimit, savedFraction: model.cacheSavings)
                }
                IconButton(symbol: "arrow.clockwise", help: "Refresh") {
                    model.refreshNow(.github)
                }
            }

            if model.preferences.githubLogin == nil {
                EmptyStateView(
                    symbol: "person.badge.key",
                    message: "Connect a GitHub token to see pull requests and CI status.",
                    actionTitle: "Open Settings…"
                ) { SettingsWindow.shared.show(model: model, tab: .github) }
            } else if let error = model.github.error, digest == nil {
                ErrorStateView(error: error) { model.refreshNow(.github) }
            } else if let digest {
                content(digest)
            } else {
                EmptyStateView(symbol: "checkmark.seal", message: "Loading…")
            }
        }
    }

    private var subtitle: String? {
        guard let digest else { return model.preferences.githubLogin }
        var parts: [String] = []
        if let viewer = digest.viewer { parts.append("@\(viewer)") }
        // A stale badge is more honest than silently showing old data as if it
        // were current.
        if model.github.error == .offline { parts.append("offline — showing cached") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func content(_ digest: GitHubDigest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Failing checks come first and are never scrolled out of view:
            // they are the single reason to glance at this pane.
            if !digest.failedRuns.isEmpty {
                ForEach(digest.failedRuns.prefix(2)) { run in
                    WorkflowRow(run: run, prominent: true) { model.openWorkflowRun(run) }
                }
            }

            SectionTabs(digest: digest, model: model)
        }
    }
}

/// Switches between review requests, own PRs, and workflow runs.
private struct SectionTabs: View {
    let digest: GitHubDigest
    @Bindable var model: AppModel
    @State private var section: Section = .reviews
    @Environment(\.colorScheme) private var scheme

    enum Section: String, CaseIterable, Identifiable {
        case reviews = "Review requests"
        case mine = "My PRs"
        case runs = "Workflows"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Section.allCases) { candidate in
                    let count = count(for: candidate)
                    Button {
                        section = candidate
                    } label: {
                        HStack(spacing: 4) {
                            Text(candidate.rawValue)
                            if count > 0 {
                                Text("\(count)")
                                    .font(Theme.Typeface.monoSmall)
                                    .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                            }
                        }
                        .font(Theme.Typeface.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill((scheme == .dark ? Color.white : Color.black)
                                    .opacity(section == candidate ? 0.10 : 0))
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        section == candidate
                            ? Theme.Palette.primaryText(scheme)
                            : Theme.Palette.secondaryText(scheme)
                    )
                }
                Spacer()
            }

            Group {
                switch section {
                case .reviews:
                    list(digest.reviewRequests, empty: "Nothing waiting on your review.")
                case .mine:
                    list(digest.myPullRequests, empty: "No open pull requests.")
                case .runs:
                    runsList(digest.workflowRuns)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func count(for section: Section) -> Int {
        switch section {
        case .reviews: digest.reviewRequests.count
        case .mine: digest.myPullRequests.count
        case .runs: digest.workflowRuns.count
        }
    }

    @ViewBuilder
    private func list(_ pullRequests: [PullRequest], empty: String) -> some View {
        if pullRequests.isEmpty {
            EmptyStateView(symbol: "checkmark.circle", message: empty)
        } else {
            PaneList(items: pullRequests) { pullRequest in
                PullRequestRow(pullRequest: pullRequest) {
                    model.openPullRequest(pullRequest)
                }
            }
            .cardSurface(padding: 0)
        }
    }

    @ViewBuilder
    private func runsList(_ runs: [WorkflowRun]) -> some View {
        if runs.isEmpty {
            EmptyStateView(
                symbol: "play.slash",
                message: "No watched repositories.\nAdd them in Settings.",
                actionTitle: "Open Settings…"
            ) { SettingsWindow.shared.show(model: model, tab: .github) }
        } else {
            PaneList(items: runs) { run in
                WorkflowRow(run: run, prominent: false) { model.openWorkflowRun(run) }
            }
            .cardSurface(padding: 0)
        }
    }
}

struct PullRequestRow: View {
    let pullRequest: PullRequest
    let open: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: pullRequest.isDraft ? "circle.dashed" : "arrow.triangle.pull")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(pullRequest.isDraft ? Theme.Palette.neutral : Theme.Palette.accent)

                Text(verbatim: "#\(pullRequest.number)")
                    .font(Theme.Typeface.monoSmall)
                    .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                    .frame(width: 38, alignment: .leading)

                Text(pullRequest.title)
                    .font(Theme.Typeface.body)
                    .foregroundStyle(Theme.Palette.primaryText(scheme))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(pullRequest.repositorySlug)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                    .lineLimit(1)

                Text(Format.relative(since: pullRequest.updatedAt))
                    .font(Theme.Typeface.monoSmall)
                    .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                    .frame(width: 26, alignment: .trailing)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                    .opacity(isHovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background((scheme == .dark ? Color.white : Color.black).opacity(isHovering ? 0.04 : 0))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open #\(pullRequest.number) on GitHub")
        .accessibilityLabel("Pull request \(pullRequest.number), \(pullRequest.title), in \(pullRequest.repositorySlug)")
    }
}

struct WorkflowRow: View {
    let run: WorkflowRun
    let prominent: Bool
    let open: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 0) {
                    Text(prominent ? "\(run.repositorySlug) · \(run.name)" : run.name)
                        .font(Theme.Typeface.body)
                        .foregroundStyle(Theme.Palette.primaryText(scheme))
                        .lineLimit(1)
                    if prominent {
                        Text(run.commitMessage.isEmpty ? run.shortSHA : run.commitMessage)
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.Palette.secondaryText(scheme))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 5) {
                    Text(run.branch)
                        .font(Theme.Typeface.monoSmall)
                        .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                        .lineLimit(1)
                    Text(run.shortSHA)
                        .font(Theme.Typeface.monoSmall)
                        .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                    Text(run.status.isActive
                         ? Format.elapsed(Date().timeIntervalSince(run.createdAt))
                         : Format.elapsed(run.duration))
                        .font(Theme.Typeface.monoSmall)
                        .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                        .frame(width: 46, alignment: .trailing)
                }

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                    .opacity(isHovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, prominent ? 7 : 0)
            .frame(maxWidth: .infinity, minHeight: prominent ? 0 : Theme.Metrics.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: Theme.Metrics.cardCornerRadius, style: .continuous)
                        .fill(Theme.Palette.failure.opacity(scheme == .dark ? 0.12 : 0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Metrics.cardCornerRadius, style: .continuous)
                                .strokeBorder(Theme.Palette.failure.opacity(0.35), lineWidth: 1)
                        )
                } else {
                    (scheme == .dark ? Color.white : Color.black).opacity(isHovering ? 0.04 : 0)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open this run on GitHub")
        .accessibilityLabel(accessibilityLabel)
    }

    private var symbol: String {
        if run.status.isActive { return "circle.dotted" }
        switch run.conclusion {
        case .success: return "checkmark.circle.fill"
        case .failure, .timedOut: return "xmark.octagon.fill"
        case .actionRequired: return "exclamationmark.triangle.fill"
        case .cancelled, .skipped, .stale: return "minus.circle"
        default: return "circle"
        }
    }

    private var tint: Color {
        if run.status.isActive { return Theme.Palette.running }
        switch run.conclusion {
        case .success: return Theme.Palette.success
        case .failure, .timedOut, .actionRequired: return Theme.Palette.failure
        default: return Theme.Palette.neutral
        }
    }

    private var accessibilityLabel: String {
        let state = run.status.isActive ? "running" : (run.conclusion?.rawValue ?? "unknown")
        return "\(run.name) in \(run.repositorySlug), \(state), branch \(run.branch)"
    }
}

/// Remaining API quota, and how much of it caching is saving.
struct RateLimitGauge: View {
    let snapshot: RateLimitSnapshot
    let savedFraction: Double

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 9.5))
            Text("\(snapshot.remaining)")
                .font(Theme.Typeface.monoSmall)
        }
        .foregroundStyle(tint)
        .help(helpText)
        .accessibilityLabel("\(snapshot.remaining) GitHub API requests remaining")
    }

    private var tint: Color {
        switch snapshot.remaining {
        case ..<RateLimitGate.reserve: Theme.Palette.failure
        case ..<500: Theme.Palette.running
        default: Theme.Palette.tertiaryText(scheme)
        }
    }

    private var helpText: String {
        let reset = Format.duration(max(0, snapshot.resetsAt.timeIntervalSinceNow))
        let saved = Int((savedFraction * 100).rounded())
        return """
        \(snapshot.remaining) of \(snapshot.limit) requests left, resets in \(reset).
        \(saved)% of requests this session were served from cache.
        """
    }
}
