import AppKit
import CorniceKit

/// User-initiated operations.
@MainActor
extension AppModel {

    // MARK: - Preferences

    /// Mutates preferences and persists the result.
    ///
    /// Every settings change funnels through here so there is one place that
    /// writes, one that re-sanitises, and one that decides whether the refresh
    /// loops need rebuilding.
    func updatePreferences(_ mutate: (inout Preferences) -> Void) {
        var updated = preferences
        mutate(&updated)
        let sanitized = updated.sanitized()
        guard sanitized != preferences else { return }

        let schedulingChanged = sanitized.mediaRefreshInterval != preferences.mediaRefreshInterval
            || sanitized.telemetryRefreshInterval != preferences.telemetryRefreshInterval
        let visualizerChanged = sanitized.audioVisualizerEnabled != preferences.audioVisualizerEnabled

        applyPreferences(sanitized)

        Task { [services = self.serviceContainer] in
            do { try await services.preferences.save(sanitized) }
            catch {
                Log.settings.error("could not save preferences: \(error.localizedDescription, privacy: .public)")
            }
        }

        if visualizerChanged {
            sanitized.audioVisualizerEnabled ? startVisualizer() : stopVisualizer()
        }
        if schedulingChanged { restartRefreshLoops() }
    }

    // MARK: - Playback

    func playPause() { send(.playPause) }
    func nextTrack() { send(.next) }
    func previousTrack() { send(.previous) }

    func seek(toProgress progress: Double) {
        guard let snapshot = media, snapshot.duration > 0 else { return }
        let target = (progress.clamped(to: 0...1) * snapshot.duration)
        // Move the local playhead immediately rather than waiting for the next
        // poll to confirm. A scrubber that snaps back to where it was for half
        // a second before jumping forward feels broken, even though the command
        // worked.
        applyMedia(MediaSnapshot(
            source: snapshot.source, state: snapshot.state, title: snapshot.title,
            artist: snapshot.artist, album: snapshot.album, duration: snapshot.duration,
            position: target, artworkURL: snapshot.artworkURL, artworkData: snapshot.artworkData,
            isShuffling: snapshot.isShuffling, repeatMode: snapshot.repeatMode,
            volume: snapshot.volume, capturedAt: .now
        ))
        send(.seek(target))
    }

    func setVolume(_ level: Double) { send(.setVolume(level)) }
    func toggleShuffle() { send(.toggleShuffle) }
    func cycleRepeat() { send(.cycleRepeat) }

    private func send(_ command: MediaCommand) {
        guard let source = media?.source else { return }
        Task { [services = self.serviceContainer] in
            do {
                try await services.media.perform(command, on: source)
                // Re-read promptly so the UI reflects the result rather than
                // waiting out the poll interval.
                try? await Task.sleep(for: .milliseconds(120))
                self.refreshNow("media")
            } catch let error as ServiceError {
                Log.media.error("command failed: \(error.headline, privacy: .public)")
                self.flashToast(error.headline)
            } catch {
                Log.media.error("command failed")
            }
        }
    }

    /// Opens the player that is currently providing the track.
    func activatePlayer() {
        guard let source = media?.source else { return }
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: source.bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Re-asks for automation permission after the user has granted it in
    /// System Settings.
    func retryMediaPermission() {
        Task { [services = self.serviceContainer] in
            await services.media.resetAvailability()
            self.refreshNow("media")
        }
    }

    func openAutomationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens Sound settings, where the output device is chosen.
    func openSoundSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func openAudioRecordingSettings() {
        // There is no dedicated Audio Recording anchor, so this opens the
        // Privacy & Security root, which is one click away from it.
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Timers

    func addTimer(minutes: Int) {
        mutateTimers { board in
            if board.add(minutes: minutes) == nil {
                self.flashToast("Up to \(TimerBoard.maximumTimers) timers")
            }
        }
    }

    func toggleTimer(_ id: UUID) {
        mutateTimers { $0.toggle(id) }
    }

    func removeTimer(_ id: UUID) {
        mutateTimers { $0.remove(id) }
    }

    /// Advances the timers. Driven by the UI's display timer, which is a
    /// repaint trigger — remaining time comes from the wall clock, so a missed
    /// tick changes nothing.
    func tickTimers() {
        guard timers.hasTimers else { return }
        var board = timers
        let completed = board.tick()
        applyTimers(board)
        guard preferences.notifyOnTimerComplete else { return }
        for entry in completed {
            NotificationPresenter.shared.timerComplete(label: entry.label)
        }
    }

    // MARK: - Misc

    func copyTrackInfo() {
        guard let snapshot = media, snapshot.hasTrack else { return }
        let text = "\(snapshot.title) — \(snapshot.artist)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        flashToast("Copied")
    }
}
