import SwiftUI
import CorniceKit

struct RepositoryPane: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let snapshot = model.repository.value {
                details(snapshot)
                Spacer(minLength: 0)
                actions(snapshot)
            } else if let error = model.repository.error {
                ErrorStateView(error: error) { model.refreshNow(.repository) }
            } else if model.preferences.activeRepositoryPath == nil {
                EmptyStateView(
                    symbol: "folder.badge.plus",
                    message: "No repository selected.",
                    actionTitle: "Choose a Repository…"
                ) { model.chooseRepository() }
            } else {
                EmptyStateView(symbol: "arrow.triangle.branch", message: "Reading repository…")
            }
        }
    }

    private var header: some View {
        PaneHeader(
            title: model.repository.value?.name ?? "Repository",
            subtitle: model.repository.value.map { Redaction.path($0.path) },
            isBusy: model.repository.isBusy && model.repository.value == nil
        ) {
            if model.preferences.repositoryPaths.count > 1 {
                repositoryPicker
            }
            IconButton(symbol: "arrow.clockwise", help: "Refresh") {
                model.refreshNow(.repository)
            }
        }
    }

    private var repositoryPicker: some View {
        Menu {
            ForEach(model.preferences.repositoryPaths, id: \.self) { path in
                Button {
                    model.selectRepository(path: path)
                } label: {
                    if path == model.preferences.activeRepositoryPath {
                        Label((path as NSString).lastPathComponent, systemImage: "checkmark")
                    } else {
                        Text((path as NSString).lastPathComponent)
                    }
                }
            }
            Divider()
            Button("Add Repository…") { model.chooseRepository() }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch repository")
    }

    @ViewBuilder
    private func details(_ snapshot: GitRepositorySnapshot) -> some View {
        VStack(spacing: 3) {
            DetailRow(
                label: "Branch",
                value: snapshot.branchLabel,
                tint: snapshot.isDetached ? Theme.Palette.running : nil
            ) {
                IconButton(symbol: "doc.on.doc", help: "Copy branch name") {
                    model.copyBranchName()
                }
                .disabled(snapshot.branch == nil)
            }

            DetailRow(label: "Working tree", value: "") {
                WorkingTreeSummary(tree: snapshot.workingTree)
            }

            if let tracking = snapshot.tracking {
                DetailRow(label: "Remote", value: tracking.upstream, valueFont: Theme.Typeface.mono) {
                    TrackingBadges(tracking: tracking)
                }
            } else {
                DetailRow(
                    label: "Remote",
                    value: "no upstream",
                    tint: Theme.Palette.tertiaryText(scheme)
                )
            }

            if let commit = snapshot.lastCommit {
                DetailRow(label: "Commit", value: commit.subject) {
                    HStack(spacing: 4) {
                        Text(commit.shortHash)
                            .font(Theme.Typeface.monoSmall)
                            .foregroundStyle(Theme.Palette.tertiaryText(scheme))
                        IconButton(symbol: "doc.on.doc", help: "Copy commit hash") {
                            model.copyCommitHash()
                        }
                    }
                }
                DetailRow(
                    label: "Authored",
                    value: "\(commit.authorName) · \(Format.relative(since: commit.authoredAt)) ago",
                    valueFont: Theme.Typeface.caption,
                    tint: Theme.Palette.secondaryText(scheme)
                )
            } else {
                DetailRow(
                    label: "Commit",
                    value: "no commits yet",
                    tint: Theme.Palette.tertiaryText(scheme)
                )
            }
        }
        .cardSurface()
    }

    private func actions(_ snapshot: GitRepositorySnapshot) -> some View {
        HStack(spacing: 6) {
            Button {
                model.revealRepositoryInFinder()
            } label: {
                Label("Finder", systemImage: "folder")
            }

            Button {
                model.openRepositoryInTerminal()
            } label: {
                Label("Terminal", systemImage: "apple.terminal")
            }

            Button {
                model.openRepositoryInEditor()
            } label: {
                Label(model.preferences.editor.title, systemImage: "chevron.left.forwardslash.chevron.right")
            }

            Spacer()

            Text("as of \(Format.relative(since: snapshot.capturedAt))")
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.Palette.tertiaryText(scheme))
        }
        .buttonStyle(PanelButtonStyle())
        .font(Theme.Typeface.caption)
        .labelStyle(.titleAndIcon)
    }
}

/// Clean/dirty summary with per-category counts.
struct WorkingTreeSummary: View {
    let tree: GitWorkingTree
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            if tree.isClean {
                HStack(spacing: 4) {
                    StatusDot(color: Theme.Palette.success)
                    Text("clean")
                        .font(Theme.Typeface.body)
                        .foregroundStyle(Theme.Palette.secondaryText(scheme))
                }
            } else {
                // Each category is labelled rather than lumped into one number,
                // because "3 changes" does not tell you whether you are about
                // to commit something you did not mean to.
                count(tree.staged, symbol: "plus.circle.fill", tint: Theme.Palette.success, help: "staged")
                count(tree.modified, symbol: "pencil.circle.fill", tint: Theme.Palette.running, help: "modified")
                count(tree.untracked, symbol: "questionmark.circle.fill", tint: Theme.Palette.neutral, help: "untracked")
                count(tree.conflicted, symbol: "exclamationmark.triangle.fill", tint: Theme.Palette.failure, help: "conflicted")
            }
        }
    }

    @ViewBuilder
    private func count(_ value: Int, symbol: String, tint: Color, help: String) -> some View {
        if value > 0 {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(tint)
                Text("\(value)")
                    .font(Theme.Typeface.monoSmall)
                    .foregroundStyle(Theme.Palette.secondaryText(scheme))
            }
            .help("\(value) \(help)")
        }
    }
}

struct TrackingBadges: View {
    let tracking: GitTracking
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            if tracking.isSynced {
                Text("in sync")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText(scheme))
            } else {
                if tracking.ahead > 0 {
                    badge("arrow.up", tracking.ahead, Theme.Palette.success, "\(tracking.ahead) ahead")
                }
                if tracking.behind > 0 {
                    badge("arrow.down", tracking.behind, Theme.Palette.running, "\(tracking.behind) behind")
                }
            }
        }
    }

    private func badge(_ symbol: String, _ value: Int, _ tint: Color, _ help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text("\(value)").font(Theme.Typeface.monoSmall)
        }
        .foregroundStyle(tint)
        .help(help)
    }
}
