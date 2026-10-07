import AppKit
import SwiftUI
import CorniceKit

/// Handles system notices without taking over an open panel. Most notices appear when a
/// reading changes, not on every poll.
@MainActor
extension AppModel {

    // MARK: - Presenting

    func presentHUD(_ content: HUDContent) {
        // Never interrupt the panel, and never interrupt a device announcement
        // that is mid-spin.
        guard surfaceState != .expanded, surfaceState != .activity else { return }

        // A HUD already up only yields to something at least as important: an
        // alert waiting on an answer is not interrupted by an announcement.
        if let current = hudContent, surfaceState.hud != nil,
           current.priority > content.priority {
            return
        }

        Log.window.debug("hud: \(content.kind.rawValue, privacy: .public)")
        applyHUD(content)
        present(.hud(content.kind))

        hudDismissTask?.cancel()
        guard let after = content.kind.dismissAfter else { return }
        hudDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(after))
            guard !Task.isCancelled else { return }
            self?.dismissHUD()
        }
    }

    func dismissHUD() {
        hudDismissTask?.cancel()
        hudDismissTask = nil
        guard hudContent != nil else { return }
        if case .timerRunning(let id, _, _, _) = hudContent {
            TimerAlarm.shared.acknowledge(id)
        }

        if surfaceState.hud != nil {
            present(isHovering ? .expanded : .collapsed)
        }

        // Cleared after the retraction rather than with it: dropping the content
        // immediately tears the view out mid-animation, so the surface shrinks
        // around an empty rectangle.
        hudDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            guard self?.surfaceState.hud == nil else { return }
            self?.applyHUD(nil)
        }
    }

    /// Read the countdown from the timer board. The HUD payload doesn't update every
    /// second.
    var hudTimerReading: String {
        guard case .timerRunning(let id, _, _, _) = hudContent,
              let entry = timers.entries.first(where: { $0.id == id })
        else { return "0:00" }
        return Format.duration(entry.remaining())
    }

    // MARK: - Sources

    /// Starts every event source that can raise a HUD.
    func startHUDSources() {
        serviceContainer.reachability.start { [weak self] isOnline in
            Task { @MainActor in
                guard let self, !isOnline else { return }
                self.presentHUD(.noInternet)
            }
        }

        serviceContainer.vpn.start { [weak self] connection in
            Task { @MainActor in
                guard let self, let connection else { return }
                self.presentHUD(.vpn(name: Self.tunnelName(connection.interface), since: connection.since))
            }
        }

        if preferences.downloadHUDEnabled { startDownloadWatching() }
    }

    func stopHUDSources() {
        serviceContainer.reachability.stop()
        serviceContainer.vpn.stop()
        serviceContainer.downloads.stop()
    }

    /// Start watching Downloads only after the user enables it, since folder access can ask
    /// for permission.
    func startDownloadWatching() {
        serviceContainer.downloads.start { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                guard let progress else {
                    if case .download = self.hudContent { self.dismissHUD() }
                    return
                }
                self.presentHUD(.download(
                    name: progress.name,
                    progress: progress.fraction,
                    bytesPerSecond: progress.bytesPerSecond
                ))
            }
        }
    }

    func stopDownloadWatching() {
        serviceContainer.downloads.stop()
        if case .download = hudContent { dismissHUD() }
    }

    /// Check battery changes here so the same reading doesn't keep showing the same notice.
    func handleBatteryChange(from previous: BatteryState?, to current: BatteryState?) {
        guard let current else { return }

        if BatteryAlertPolicy.shouldWarn(previous: previous, current: current) {
            presentHUD(.batteryLow(level: current.level))
            NotificationPresenter.shared.lowBattery(level: current.level)
            return
        }

        guard let previous else { return }

        if current.isCharging && !previous.isCharging {
            presentHUD(.charging(level: current.level))
            return
        }
        if current.level >= 1.0 && previous.level < 1.0 && current.isPluggedIn {
            presentHUD(.fullBattery)
            return
        }
    }

    /// Announces a timer the moment it finishes, so the alarm has a face.
    func presentTimerHUD(for entry: TimerEntry) {
        presentHUD(.timerRunning(
            id: entry.id,
            label: entry.label,
            isRunning: entry.isRunning,
            isFinished: entry.isFinished
        ))
    }

    func openNetworkSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
        dismissHUD()
    }

    /// Show the tunnel interface name. The interface doesn't tell us which VPN app owns it.
    private static func tunnelName(_ interface: String) -> String {
        "VPN · \(interface)"
    }
}
