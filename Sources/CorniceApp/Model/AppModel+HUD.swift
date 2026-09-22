import AppKit
import SwiftUI
import CorniceKit

/// Raising, replacing and retracting system HUDs.
///
/// Every one of these is an *announcement*: it appears because the machine did
/// something, not because the user asked, and it gets out of the way by itself.
/// Two rules follow from that and are enforced here rather than at each call
/// site, because each of them was a bug before it was a rule:
///
/// - **A HUD never steals an open panel.** If the user is looking at the player,
///   the machine can wait.
/// - **The first reading of anything is not an event.** Launching with the
///   charger in, or with a VPN already up, is not "the charger was just plugged
///   in", and announcing state at launch is how a notch app becomes something
///   people quit.
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

    /// The live countdown for whichever timer the HUD is showing.
    ///
    /// Read from the board on every frame rather than captured into the HUD's
    /// payload, because the payload is a snapshot and a countdown is not.
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

    /// Watching Downloads is TCC-protected, so it is started only once the user
    /// has asked for it. Otherwise the app springs a folder-access dialog on
    /// somebody who never wanted a download HUD.
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

    /// Reacts to a new telemetry sample's battery reading.
    ///
    /// Edge-triggered throughout: a HUD fires on the sample where something
    /// changed, never on the state persisting.
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

    /// A readable name for a tunnel interface.
    ///
    /// The networking stack knows the interface, not the product, so this says
    /// what is actually true rather than inventing a vendor.
    private static func tunnelName(_ interface: String) -> String {
        "VPN · \(interface)"
    }
}
