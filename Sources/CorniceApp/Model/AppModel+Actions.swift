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

    /// Flipped locally before the command is sent, like the other transport
    /// toggles. Without it the glyph did not change until the next poll came
    /// back — up to a second after the click — so the symbol-replace animation
    /// played long after the press it belonged to, which reads as no animation
    /// at all.
    func playPause() {
        if let snapshot = media {
            let wanted: PlaybackState = snapshot.state.isPlaying ? .paused : .playing
            applyMedia(snapshot.with(state: wanted))
            holdToggle(state: wanted)
        }
        send(.playPause)
    }
    func nextTrack() {
        expectTrackChange()
        send(.next)
    }

    func previousTrack() {
        expectTrackChange()
        send(.previous)
    }

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

    /// Flipped locally before the command is sent, then confirmed by the next
    /// poll — the same trick the scrubber uses.
    ///
    /// Without it the glyph does not change for up to a second, which reads as
    /// the button having done nothing, so people press it again and toggle it
    /// straight back.
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

        // Where the player has no repeat-one of its own, the app provides it by
        // looping the track itself.
        let appProvides = wanted == .one && !snapshot.source.nativelyRepeatsOne
        setAppliesRepeatOne(appProvides)

        applyMedia(snapshot.with(repeatMode: wanted))
        holdToggle(repeatMode: wanted)
        // The player's own repeat stays *on* for repeat-one, even though the
        // loop is what repeats the track.
        //
        // Two reasons. Spotify's window is the thing most people are looking at,
        // and switching its repeat off on the second press makes the button look
        // like it undid itself. And if a loop is ever missed, the track ending
        // lands on the playlist repeating rather than on playback stopping.
        //
        // This is safe now only because the mode is no longer inferred from what
        // the player reports — that inference is what used to make the setting
        // switch itself off.
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

    /// Clears the app's own audio-capture permission and asks again.
    ///
    /// Worth a button because this app is ad-hoc signed, and macOS ties a
    /// permission to the code signature: every rebuild is a different signature
    /// and therefore a different app as far as TCC is concerned, so the grant is
    /// dropped and a fresh prompt appears. A prompt that is missed or dismissed
    /// leaves the tap running and fed silence — macOS reports no error for a
    /// refused tap — and the visualiser simply stops working with no way back
    /// short of knowing the incantation.
    ///
    /// Only ever resets this app's own entry.
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
        mutateTimers { board in
            if board.add(minutes: minutes) == nil {
                self.flashToast("Up to \(TimerBoard.maximumTimers) timers")
            }
        }
    }

    func toggleTimer(_ id: UUID) {
        TimerAlarm.shared.stop()
        mutateTimers { $0.toggle(id) }
    }

    func removeTimer(_ id: UUID) {
        TimerAlarm.shared.stop()
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
        guard !completed.isEmpty else { return }
        guard preferences.notifyOnTimerComplete else { return }
        // The sound is the point: a banner alone is no use for something you set
        // a timer precisely so you could stop watching.
        TimerAlarm.shared.start()
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
