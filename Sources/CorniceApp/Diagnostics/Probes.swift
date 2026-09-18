import AppKit
import CorniceKit

/// Command-line diagnostics.
///
/// Several of the harder bugs in this app lived where a debugger cannot follow:
/// what the player reports between polls, what the audio tap delivers once the
/// system fader has been applied, whether a repeat setting survives a track
/// change. Each probe below drives the real code path, from inside the app
/// bundle (which matters, because automation and audio-capture permission are
/// granted to a bundle and not to a terminal), logs what it saw, and exits.
///
/// Nothing here runs unless a `--probe-…` argument is passed.
@MainActor
enum Probes {

    /// Probes that need no interface. Returns `true` when one has started, in
    /// which case launch should go no further.
    static func runDetached(_ arguments: [String]) -> Bool {
        // What the media layer can actually see: which players are running,
        // and what each one reports.
        if arguments.contains("--probe-media") {
            Task { await probeMedia() }
            return true
        }

        // The same for audio capture. macOS reports a tap it has denied as
        // running and simply feeds it silence, so "did it start" answers
        // nothing. Only measuring what arrives does.
        if arguments.contains("--probe-audio") {
            Task { await probeAudio() }
            return true
        }

        // Sends the transport commands and reads the player back, so "the
        // button does nothing" can be told apart from "the player refused" and
        // from "the player has no such setting".
        if arguments.contains("--probe-transport") {
            Task { await probeTransport() }
            return true
        }

        return false
    }

    /// Probes that drive the live model. These let the app finish launching, so
    /// that what they measure is the running app rather than a rehearsal of it.
    static func runAttached(
        _ arguments: [String],
        model: AppModel,
        controller: NotchWindowController
    ) {
        // A real double-click, at the speed a person actually clicks. Every
        // probe so far has pressed with most of a second between, which is not
        // how the button gets used.
        if arguments.contains("--probe-double-press") {
            Task { @MainActor in
                // Wait for the first read rather than assuming it has happened.
                var before: MediaSnapshot?
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if let snapshot = model.media, snapshot.hasTrack { before = snapshot; break }
                }
                guard let before else {
                    Log.media.notice("double press: no track after 20s")
                    exit(0)
                }
                Log.media.notice("double press: starting from \(before.repeatMode.rawValue, privacy: .public)")

                // Get to a known 'off' first, one press at a time.
                for _ in 0..<3 where model.media?.repeatMode != .off {
                    model.cycleRepeat()
                    try? await Task.sleep(for: .milliseconds(900))
                }
                Log.media.notice("double press: reset to \(model.media?.repeatMode.rawValue ?? "?", privacy: .public)")

                // Now the double-click.
                model.cycleRepeat()
                try? await Task.sleep(for: .milliseconds(150))
                model.cycleRepeat()

                var trace: [String] = []
                for _ in 0..<12 {
                    try? await Task.sleep(for: .milliseconds(500))
                    trace.append("\(model.media?.repeatMode.rawValue ?? "?")/\(model.appliesRepeatOne ? "app" : "-")")
                }
                Log.media.notice("double press: \(trace.joined(separator: " "), privacy: .public)")
                exit(0)
            }
        }

        // Skip while repeat-one is holding: it should start the song again
        // rather than leave it. Verified against the player, because the whole
        // question is what the *player* does with the command.
        if arguments.contains("--probe-repeat-skip") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                guard let before = model.media, before.duration > 40 else {
                    Log.media.notice("skip probe: no track long enough to test")
                    exit(0)
                }
                if !before.state.isPlaying { model.playPause() }
                try? await Task.sleep(for: .seconds(1))

                for _ in 0..<3 where model.media?.repeatMode != .one {
                    model.cycleRepeat()
                    try? await Task.sleep(for: .milliseconds(800))
                }
                guard model.media?.repeatMode == .one else {
                    Log.media.notice("skip probe: could not reach repeat one")
                    exit(0)
                }

                // Somewhere clearly into the track, so a restart is unambiguous.
                model.seek(toProgress: 0.4)
                try? await Task.sleep(for: .seconds(2))
                guard let armed = model.media else { exit(0) }
                let identity = armed.trackIdentity
                Log.media.notice(
                    "skip probe: holding at \(armed.extrapolatedPosition(), format: .fixed(precision: 1), privacy: .public)s"
                )

                model.nextTrack()
                try? await Task.sleep(for: .seconds(3))
                guard let held = model.media else { exit(0) }
                let sameTrack = held.trackIdentity == identity
                Log.media.notice(
                    "skip probe: held=\(sameTrack, privacy: .public) at \(held.extrapolatedPosition(), format: .fixed(precision: 1), privacy: .public)s"
                )

                // Released, the same button has to move again. A skip that
                // never skips would be the worse bug of the two.
                model.cycleRepeat()
                try? await Task.sleep(for: .seconds(1))
                model.nextTrack()
                try? await Task.sleep(for: .seconds(3))
                let moved = model.media?.trackIdentity != identity
                Log.media.notice("skip probe: released, moved=\(moved, privacy: .public)")
                exit(0)
            }
        }

        // Drives repeat-one against the real player: seeks to just before the
        // end, waits, and reports whether the track looped instead of moving on.
        // Restores playback state afterwards.
        if arguments.contains("--probe-repeat-one") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))

                guard let before = model.media, before.duration > 20 else {
                    Log.media.notice("repeat-one probe: need a loaded track")
                    exit(0)
                }
                let wasPlaying = before.state.isPlaying
                let wasAt = before.extrapolatedPosition()
                Log.media.notice(
                    "repeat-one probe: \(before.title.isEmpty ? "track" : "track", privacy: .public) duration=\(before.duration, format: .fixed(precision: 1), privacy: .public) wasPlaying=\(wasPlaying, privacy: .public)"
                )

                // Drive to repeat-one explicitly rather than assuming where the
                // cycle starts.
                let startedAt = before.repeatMode
                for _ in 0..<3 where model.media?.repeatMode != .one {
                    model.cycleRepeat()
                    try? await Task.sleep(for: .milliseconds(700))
                }
                Log.media.notice("repeat-one probe: started from \(startedAt.rawValue, privacy: .public)")
                Log.media.notice("repeat-one probe: mode=\(model.media?.repeatMode.rawValue ?? "?", privacy: .public) appApplies=\(model.appliesRepeatOne, privacy: .public)")

                if !wasPlaying { model.playPause() }
                try? await Task.sleep(for: .milliseconds(800))

                // Soak: the mode has to survive a stretch of ordinary polling.
                // Clearing it from a reading made the feature die quietly a few
                // seconds after it was switched on.
                var soak: [String] = []
                for _ in 0..<6 {
                    try? await Task.sleep(for: .seconds(2))
                    let m = model.media
                    soak.append(String(
                        format: "%@/%@/%.0f",
                        m?.repeatMode.rawValue ?? "?",
                        m?.state.rawValue ?? "?",
                        m?.extrapolatedPosition() ?? -1
                    ))
                }
                Log.media.notice("repeat-one probe: soak \(soak.joined(separator: " "), privacy: .public)")

                model.seek(toProgress: (before.duration - 6) / before.duration)
                try? await Task.sleep(for: .seconds(1))

                var trace: [String] = []
                for _ in 0..<16 {
                    try? await Task.sleep(for: .milliseconds(750))
                    let m = model.media
                    trace.append(String(
                        format: "%.1f%@", m?.extrapolatedPosition() ?? -1,
                        m?.state.isPlaying == true ? "" : "(paused)"
                    ))
                }
                Log.media.notice("repeat-one probe: positions \(trace.joined(separator: " "), privacy: .public)")

                // Put things back.
                for _ in 0..<3 where model.media?.repeatMode != startedAt {
                    model.cycleRepeat()
                    try? await Task.sleep(for: .milliseconds(700))
                }
                model.seek(toProgress: wasAt / before.duration)
                try? await Task.sleep(for: .milliseconds(500))
                if !wasPlaying { model.playPause() }
                try? await Task.sleep(for: .milliseconds(800))
                Log.media.notice("repeat-one probe: restored")
                exit(0)
            }
        }

        // Opens the panel and reports what the indicator is actually being fed,
        // which is otherwise only observable by hovering the notch by hand.
        if arguments.contains("--probe-indicator") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                controller.toggle()
                for _ in 0..<12 {
                    try? await Task.sleep(for: .seconds(1))
                    let bars = model.levels.barHeights(count: 3, outputVolume: model.outputVolume)
                    let bandText = model.levels.bands.map { String(format: "%.2f", $0) }
                        .joined(separator: ",")
                    let barText = bars.map { String(format: "%.2f", $0) }.joined(separator: ",")
                    let numbers = String(
                        format: "level=%.3f fader=%.3f",
                        model.levels.level, model.outputVolume
                    )
                    var summary = "state=\(model.surfaceState) live=\(model.hasLiveAudio)"
                    summary += " shows=\(model.showsIndicator) " + numbers
                    summary += " bands=" + bandText + " bars=" + barText
                    Log.audio.notice("indicator: \(summary, privacy: .public)")
                }
                exit(0)
            }
        }
    }

    // MARK: - Implementations

    /// Prints live player state, for verifying the scripting path.
    private static func probeAudio() async {
        let reader = OutputVolumeReader()
        Log.audio.notice(
            "probe: outputVolume=\(reader.current().map { String(format: "%.3f", $0) } ?? "nil", privacy: .public)"
        )

        let engine = AudioVisualizerEngine(bandCount: 8)
        let status = engine.start()
        Log.audio.notice("probe: status \(String(describing: status), privacy: .public)")

        guard status == .running else {
            Log.audio.notice("probe: tap did not start")
            exit(0)
        }

        var peakLevel: Float = 0
        var peakBands = [Float](repeating: 0, count: 8)
        var samples = 0
        var barTrace: [[Float]] = []
        for _ in 0..<160 {
            try? await Task.sleep(for: .milliseconds(50))
            let levels = engine.latestLevels()
            // Through the same path the interface uses, fader and all.
            if !levels.isSilent {
                barTrace.append(levels.barHeights(
                    count: 3, outputVolume: Float(reader.current() ?? 1)
                ))
            }
            peakLevel = max(peakLevel, levels.level)
            for (index, value) in levels.bands.enumerated() where index < peakBands.count {
                peakBands[index] = max(peakBands[index], value)
            }
            if !levels.isSilent { samples += 1 }
        }
        engine.stop()

        let perBand = peakBands.map { String(format: "%.3f", $0) }.joined(separator: " ")
        Log.audio.notice(
            "probe: peakLevel=\(peakLevel, format: .fixed(precision: 4), privacy: .public) nonSilent=\(samples, privacy: .public)/160 bands=[\(perBand, privacy: .public)]"
        )

        // How much each drawn bar actually moves, which is what "lively" means.
        let summary = (0..<3).map { bar -> String in
            let series = barTrace.map { $0[bar] }
            let lowest = series.min() ?? 0
            let highest = series.max() ?? 0
            let mean = series.reduce(0, +) / Float(max(1, series.count))
            let variance = series.reduce(0) { $0 + pow($1 - mean, 2) } / Float(max(1, series.count))
            return String(format: "bar%d %.2f-%.2f mean %.2f sd %.3f", bar, lowest, highest, mean, variance.squareRoot())
        }
        Log.audio.notice("probe: \(summary.joined(separator: "  "), privacy: .public)")
        exit(0)
    }

    private static func probeTransport() async {
        // Driven through AppModel, because that is what the buttons call: the
        // optimistic flip, the hold that stops a stale poll undoing it, and the
        // refresh afterwards. Probing the coordinator underneath it answers a
        // different question from "does the button work".
        let model = AppModel(services: ServiceContainer.live())
        await model.start()
        try? await Task.sleep(for: .seconds(2))

        guard let before = model.media else {
            Log.media.notice("transport probe: no player with a track")
            exit(0)
        }
        Log.media.notice(
            "transport probe: \(before.source.rawValue, privacy: .public) repeat=\(before.repeatMode.rawValue, privacy: .public) shuffle=\(before.isShuffling, privacy: .public) state=\(before.state.rawValue, privacy: .public)"
        )

        for round in 1...3 {
            model.cycleRepeat()
            var trace: [String] = []
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(200))
                let mode = model.media?.repeatMode.rawValue ?? "?"
                trace.append(mode)
            }
            Log.media.notice(
                "transport probe: cycleRepeat \(round, privacy: .public) → \(trace.joined(separator: " "), privacy: .public)"
            )
        }
        exit(0)
    }

    private static func probeMedia() async {
        let coordinator = MediaCoordinator.live()
        let running = await coordinator.runningSources()
        print("running players:", running.map(\.displayName).joined(separator: ", "))

        guard let snapshot = await coordinator.snapshot() else {
            let denied = await coordinator.allSourcesUnavailable()
            print(denied
                  ? "automation refused. Grant Cornice in Privacy & Security › Automation"
                  : "no track loaded")
            exit(0)
        }

        print("""
        source:   \(snapshot.source.displayName)
        state:    \(snapshot.state.rawValue)
        title:    \(snapshot.title)
        artist:   \(snapshot.artist)
        album:    \(snapshot.album)
        duration: \(Format.duration(snapshot.duration))  (\(snapshot.duration)s raw)
        position: \(Format.duration(snapshot.position))
        progress: \(String(format: "%.1f%%", snapshot.progress() * 100))
        shuffle:  \(snapshot.isShuffling)  repeat: \(snapshot.repeatMode.rawValue)
        volume:   \(snapshot.volume.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a")
        artwork:  \(snapshot.artworkURL?.absoluteString ?? "none")
        """)

        if let data = await coordinator.artwork(for: snapshot) {
            print("artwork bytes: \(data.count)")
        }
        exit(0)
    }
}
