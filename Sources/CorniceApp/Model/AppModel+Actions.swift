import AppKit
import CorniceKit

/// User-initiated operations.
@MainActor
extension AppModel {

    // MARK: - Preferences

    /// Update, check and save settings here. Restart the affected services if needed.
    func updatePreferences(_ mutate: (inout Preferences) -> Void) {
        var updated = preferences
        mutate(&updated)
        let sanitized = updated.sanitized()
        guard sanitized != preferences else { return }

        let schedulingChanged = sanitized.mediaRefreshInterval != preferences.mediaRefreshInterval
            || sanitized.telemetryRefreshInterval != preferences.telemetryRefreshInterval
        let visualizerChanged = sanitized.audioVisualizerEnabled != preferences.audioVisualizerEnabled
        let downloadsChanged = sanitized.downloadHUDEnabled != preferences.downloadHUDEnabled

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
        if downloadsChanged {
            sanitized.downloadHUDEnabled ? startDownloadWatching() : stopDownloadWatching()
        }
        if schedulingChanged { restartRefreshLoops() }
    }

    // MARK: - Playback

    /// Change the button immediately, then send the command. Waiting for the next poll
    /// makes the click feel delayed.
    func playPause() {
        if let snapshot = media {
            let wanted: PlaybackState = snapshot.state.isPlaying ? .paused : .playing
            applyMedia(snapshot.with(state: wanted))
            holdToggle(state: wanted)
        }
        send(.playPause)
    }
    /// True when repeat-one is on, whether the player handles it or Cornice does.
    var holdsCurrentTrack: Bool {
        media?.repeatMode == .one
    }

    /// With repeat-one on, Next restarts this song. Turn repeat off to skip to another one.
    func nextTrack() {
        guard !holdsCurrentTrack else { return restartTrack() }
        expectTrackChange()
        send(.next)
    }

    func previousTrack() {
        guard !holdsCurrentTrack else { return restartTrack() }
        stepToPreviousTrack()
    }

    /// Go back a track even when repeat-one is on. Recovery needs this to return to the
    /// song the player just left.
    func stepToPreviousTrack() {
        expectTrackChange()
        send(.previous)
    }

    private func restartTrack() {
        seek(toProgress: 0)
    }

    func seek(toProgress progress: Double) {
        guard let snapshot = media, snapshot.duration > 0 else { return }
        let target = (progress.clamped(to: 0...1) * snapshot.duration)
        // Move the scrubber straight away so it doesn't snap back while the player catches
        // up.
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

    /// Show the new shuffle state immediately and confirm it on the next poll.
    func toggleShuffle() {
        if let snapshot = media {
            let wanted = !snapshot.isShuffling
            applyMedia(snapshot.with(isShuffling: wanted))
            holdToggle(isShuffling: wanted)
        }
        send(.toggleShuffle)
    }

    func cycleRepeat() {
        guard let snapshot = media else { return }
        let wanted = snapshot.repeatMode.next(on: snapshot.source)

        // Use Spotify's own repeat-one setting when the Web API is connected. That also
        // updates the button inside Spotify.
        if snapshot.source == .spotify, spotifyCanSetRepeat {
            applyMedia(snapshot.with(repeatMode: wanted))
            holdToggle(repeatMode: wanted)
            sendSpotifyRepeat(wanted)
            return
        }

        // Where the player has no repeat-one of its own, the app provides it by
        // looping the track itself.
        let appProvides = wanted == .one && !snapshot.source.nativelyRepeatsOne
        setAppliesRepeatOne(appProvides)

        applyMedia(snapshot.with(repeatMode: wanted))
        holdToggle(repeatMode: wanted)
        // Keep the player's repeat on while our loop handles the single track. If the loop
        // misses, playback can keep going. Hold our repeat-one mode locally so a poll
        // doesn't switch it off.
        send(.setRepeat(wanted))
        scheduleRepeatOneLoop()
    }

    private func send(_ command: MediaCommand) {
        guard let source = media?.source else { return }
        Task { [services = self.serviceContainer] in
            do {
                try await services.media.perform(command, on: source)
                // Long enough for the player to have applied it. Measured
                // against Spotify, a change was reported by 320 ms; 120 ms read
                // the old value about as often as the new one.
                try? await Task.sleep(for: .milliseconds(400))
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

    /// Reset only Cornice's audio permission and ask again. Rebuilding an ad-hoc signed app
    /// can cause macOS to stop trusting the old grant.
    func resetAudioPermission() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.cornice.app"
        Task { [weak self] in
            let runner = SubprocessRunner()
            do {
                _ = try await runner.run(Command(
                    executable: "/usr/bin/tccutil",
                    arguments: ["reset", "AudioCapture", bundleIdentifier],
                    timeout: 10
                ))
                Log.audio.notice("audio permission reset; restarting capture")
            } catch {
                Log.audio.error("could not reset audio permission: \(String(describing: error), privacy: .public)")
            }
            await MainActor.run {
                guard let self else { return }
                self.stopVisualizer()
                self.startVisualizer()
            }
        }
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
        var updatedID: UUID?
        mutateTimers { board in
            updatedID = board.addTime(minutes: minutes)
        }
        guard let id = updatedID else { return }
        TimerAlarm.shared.acknowledge(id)
        refreshTimerHUD(id)
    }

    func repeatTimer(_ id: UUID) {
        guard timers.entries.contains(where: { $0.id == id && $0.isFinished }) else { return }
        TimerAlarm.shared.acknowledge(id)
        mutateTimers { $0.repeatTimer(id) }
        refreshTimerHUD(id)
    }

    func toggleTimer(_ id: UUID) {
        TimerAlarm.shared.acknowledge(id)
        mutateTimers { $0.toggle(id) }
        refreshTimerHUD(id)
    }

    private func refreshTimerHUD(_ id: UUID) {
        if case .timerRunning(let shownID, _, _, _) = hudContent, shownID == id,
           let entry = timers.entries.first(where: { $0.id == id }) {
            // Update the existing alert even if the panel is now open.
            applyHUD(.timerRunning(id: id, label: entry.label,
                                   isRunning: entry.isRunning, isFinished: entry.isFinished))
        }
    }

    func removeTimer(_ id: UUID) {
        TimerAlarm.shared.acknowledge(id)
        mutateTimers { $0.remove(id) }
        if case .timerRunning(let shownID, _, _, _) = hudContent, shownID == id {
            if let next = timers.entries.first(where: { TimerAlarm.shared.pendingIDs.contains($0.id) }) {
                presentTimerHUD(for: next)
            } else {
                dismissHUD()
            }
        }
    }

    /// Advances the timers. Driven by the UI's display timer, which is a
    /// repaint trigger. Remaining time comes from the wall clock, so a missed
    /// tick changes nothing.
    func tickTimers() {
        guard timers.hasTimers else { return }
        var board = timers
        let completed = board.tick()
        guard !completed.isEmpty else { return }
        applyTimers(board)
        guard preferences.notifyOnTimerComplete else { return }
        // The sound is the point: a banner alone is no use for something you set
        // a timer precisely so you could stop watching.
        TimerAlarm.shared.start(for: completed.map(\.id))
        for entry in completed {
            NotificationPresenter.shared.timerComplete(label: entry.label)
        }
        // And a face to go with the noise, so it can be silenced from the notch
        // rather than by hunting for the panel.
        if let finished = completed.first {
            presentTimerHUD(for: finished)
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
