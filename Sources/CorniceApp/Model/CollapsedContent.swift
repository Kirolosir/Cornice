import SwiftUI
import CorniceKit

/// What the collapsed surface shows either side of the notch.
///
/// The hard constraint is that this sits in the menu bar, permanently, in a
/// developer's peripheral vision. Anything that moves or changes colour without
/// meaning something is a distraction they will uninstall the app over. So:
///
/// - Nothing is shown when nothing needs saying. An idle surface is exactly
///   notch-sized and completely invisible.
/// - At most one item per side, chosen by priority rather than by cramming
///   everything in.
/// - Colour is used only for genuine status, never for decoration.
struct CollapsedContent: Equatable {

    /// A single compact indicator.
    struct Chip: Equatable {
        var symbol: String
        var text: String?
        var tint: Color
        /// Draws attention with a slow pulse. Reserved for states that are
        /// actively wrong, not merely in progress.
        var isUrgent: Bool = false
    }

    var leading: Chip?
    var trailing: Chip?

    /// Width of each side extension. Zero when there is nothing to show, which
    /// keeps the surface exactly notch-sized and unhoverable-by-accident.
    var wingWidth: CGFloat {
        (leading == nil && trailing == nil) ? 0 : Theme.Metrics.wingWidth
    }

    var isEmpty: Bool { leading == nil && trailing == nil }
}

@MainActor
extension AppModel {

    /// Builds the collapsed indicators from current state.
    ///
    /// Priority order on each side is deliberate: the left is about *where you
    /// are* (which repository, is it dirty), the right about *what needs you*
    /// (a failing build, then a running timer, then a live server). A failing
    /// check outranks everything because it is the one thing worth interrupting
    /// for.
    var collapsedContent: CollapsedContent {
        guard surfaceState == .collapsed else { return CollapsedContent() }

        var content = CollapsedContent()

        // Leading: repository identity.
        if preferences.enabledModules.contains(.repository),
           let snapshot = repository.value {
            let dirty = !snapshot.workingTree.isClean
            content.leading = CollapsedContent.Chip(
                symbol: "arrow.triangle.branch",
                text: snapshot.branchLabel,
                tint: dirty ? Theme.Palette.running : Theme.Palette.neutral
            )
        }

        // Trailing: whatever most needs attention.
        if preferences.enabledModules.contains(.github),
           let failing = github.value?.failedRuns.first {
            content.trailing = CollapsedContent.Chip(
                symbol: "xmark.octagon.fill",
                text: failing.repositorySlug.split(separator: "/").last.map(String.init),
                tint: Theme.Palette.failure,
                isUrgent: true
            )
        } else if preferences.enabledModules.contains(.github),
                  let running = github.value?.workflowRuns.first(where: { $0.status.isActive }) {
            content.trailing = CollapsedContent.Chip(
                symbol: "circle.dotted",
                text: running.branch,
                tint: Theme.Palette.running
            )
        } else if preferences.enabledModules.contains(.focus), focus.state.isRunning {
            content.trailing = CollapsedContent.Chip(
                symbol: "timer",
                text: Format.duration(focus.state.remaining()),
                tint: Theme.Palette.accent
            )
        } else if preferences.enabledModules.contains(.commands),
                  let active = commandRuns.first(where: { !$0.state.isTerminal }) {
            content.trailing = CollapsedContent.Chip(
                symbol: "terminal",
                text: active.name,
                tint: Theme.Palette.running
            )
        } else if preferences.enabledModules.contains(.servers),
                  let live = ports.value?.filter(\.isActive), !live.isEmpty {
            content.trailing = CollapsedContent.Chip(
                symbol: "dot.radiowaves.left.and.right",
                text: live.count == 1 ? ":\(live[0].port)" : "\(live.count) up",
                tint: Theme.Palette.success
            )
        }

        // "Collapse when idle" suppresses the calm states but never the ones
        // that are actually asking for attention.
        if preferences.collapseWhenIdle, content.trailing?.isUrgent != true {
            content.leading = nil
            content.trailing = nil
        }

        return content
    }
}

/// Heights of the expanded panel, per module.
///
/// Fixed per pane rather than measured from content: the window frame has to be
/// set *before* SwiftUI lays out, so a measured height would arrive one frame
/// late and the panel would visibly resize after opening.
enum ExpandedMetrics {

    static func height(for module: ModuleKind) -> CGFloat {
        let content: CGFloat = switch module {
        case .repository: 214
        case .servers: 226
        case .github: 268
        case .telemetry: 214
        case .containers: 226
        case .commands: 238
        case .focus: 196
        }
        return content + Theme.Metrics.tabStripHeight + Theme.Metrics.panelPadding * 2
    }
}
