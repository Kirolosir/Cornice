import AppKit
import Observation
import SwiftUI
import CorniceKit

/// The state the views read, plus the tasks that refresh it. Services handle the player and
/// system calls.
@MainActor
@Observable
final class AppModel {

    // MARK: - Configuration

    private(set) var preferences = Preferences()

    // MARK: - Surface

    private(set) var surfaceState: SurfaceState = .collapsed
    private(set) var isHovering = false
    var activeModule: ModuleKind = .media

    private(set) var notchProfile: NotchProfile?
    private(set) var hardware: HardwareIdentity?

    // MARK: - Media

    private(set) var media: MediaSnapshot?
    private(set) var artwork: NSImage?
    /// Dominant colour of the current artwork, used to tint the surface.
    private(set) var artworkTint: Color?
    /// Several colours from the cover with the corner each belongs to, so the
    /// surface is laid out like the artwork rather than averaged from it.
    private(set) var artworkAccents: [ArtworkAccent] = []
    /// Hold a button's new state while the player catches up. Otherwise an old poll can
    /// briefly undo the click.
    private struct PendingToggle {
        var isShuffling: Bool?
        var repeatMode: RepeatMode?
        var state: PlaybackState?
        var until: Date
    }

    private var pendingToggle: PendingToggle?

    /// Repeat-one handled by Cornice when Spotify isn't connected to the Web API. The
    /// player can't report this mode back to us.
    private(set) var appliesRepeatOne = false

    /// Whether Spotify's Web API can be asked for a repeat mode. Drives Settings.
    var spotifyStatus: SpotifyWebRemote.Status = .unconfigured
    /// What went wrong last, if anything. Held apart from `spotifyStatus` so a
    /// refused command reports itself without also revoking the connection.
    var spotifyError: String?
    /// Spotify's own repeat mode, as the Web API last reported it.
    var spotifyRepeat: RepeatMode?
    /// When that was, so the read stays on its own slow cadence.
    var lastSpotifyRead: Date?

    /// Whether the user has already been told the tap cannot hear. One message
    /// per grant, not one per frame.
    private var warnedTapIsDeaf = false
    private var repeatOneTask: Task<Void, Never>?
    /// The last track seen, so an advance the app did not ask for can be caught.
    private var lastSeenTrack: (identity: String, position: TimeInterval, duration: TimeInterval)?
    /// How early this player has been seen to move on, learned from it doing so.
    private var observedEarlyAdvance: TimeInterval = 0
    /// Set when the user skips deliberately, so their skip is not undone.
    private var expectsTrackChange = false

    /// Records what the user just asked for, so an in-flight poll cannot undo it.
    func holdToggle(
        isShuffling: Bool? = nil,
        repeatMode: RepeatMode? = nil,
        state: PlaybackState? = nil
    ) {
        pendingToggle = PendingToggle(
            isShuffling: isShuffling,
            repeatMode: repeatMode,
            state: state,
            // Generous next to the measured 320 ms: the cost of being wrong is
            // a stale glyph for a moment, and the cost of being too tight is the
            // bug this exists to fix.
            until: Date().addingTimeInterval(1.5)
        )
    }

    /// Applies a freshly-polled snapshot, keeping any toggle the player has not
    /// caught up with yet.
    private func reconcile(_ snapshot: MediaSnapshot?) -> MediaSnapshot? {
        guard var snapshot, let pending = pendingToggle else {
            pendingToggle = nil
            return snapshot
        }
        guard Date() < pending.until else {
            pendingToggle = nil
            return snapshot
        }

        var settled = true
        if let wanted = pending.isShuffling {
            if snapshot.isShuffling != wanted {
                snapshot = snapshot.with(isShuffling: wanted)
                settled = false
            }
        }
        if let wanted = pending.repeatMode {
            if snapshot.repeatMode != wanted {
                snapshot = snapshot.with(repeatMode: wanted)
                settled = false
            }
        }
        if let wanted = pending.state {
            if snapshot.state != wanted {
                snapshot = snapshot.with(state: wanted)
                settled = false
            }
        }
        // Once the player agrees, stop holding: a user who changes it in the
        // player itself should see that immediately.
        if settled { pendingToggle = nil }
        return snapshot
    }

    /// Set when every known player refused automation.
    private(set) var mediaPermissionDenied = false
    private(set) var runningPlayers: [MediaSource] = []

    // MARK: - Output device

    private(set) var outputDevice: AudioOutputDevice?

    /// A transient announcement, such as AirPods connecting.
    struct DeviceActivity: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let symbol: String
        let batteryLevel: Double?
    }

    private(set) var deviceActivity: DeviceActivity?
    private var activityDismissTask: Task<Void, Never>?

    // MARK: - System HUDs

    /// What the current HUD is saying, if one is up.
    private(set) var hudContent: HUDContent?
    var hudDismissTask: Task<Void, Never>?

    // MARK: - Visualiser

    /// Latest analysed audio. Pulled on the UI's own display timer rather than
    /// pushed from the audio thread. See `AudioVisualizerEngine`.
    private(set) var levels: AudioLevels
    private(set) var visualizerStatus: AudioVisualizerEngine.Status = .stopped
    /// When the analyser last started, so "it has never heard anything" can be
    /// told from "it has not been running long enough to say".
    private var visualizerRunningSince: Date?
    /// When the analyser last reported something other than silence.
    private var lastAudioAt: Date?
    /// Read output volume a few times a second. There is no need to query the device on
    /// every frame.
    private(set) var outputVolume: Float = 1
    private var volumeReadAt: Date?

    // MARK: - Other modules

    private(set) var telemetry = TelemetryHistory(capacity: 48)
    private(set) var timers = TimerBoard()

    // MARK: - Dependencies

    let serviceContainer: ServiceContainer
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    /// Track identity the artwork currently belongs to, so it is fetched once
    /// per song rather than once per poll.
    private var artworkTrackIdentity: String?

    init(services: ServiceContainer) {
        self.serviceContainer = services
        self.levels = .silent(bandCount: services.visualizer.bandCount)
    }

    // MARK: - Lifecycle

    func start() async {
        preferences = await serviceContainer.preferences.load()
        // Restored, so the setting survives a relaunch the way a setting should.
        appliesRepeatOne = preferences.appliesRepeatOne
        if appliesRepeatOne { Log.media.notice("repeat one: restored") }
        // Start polling first. Audio setup, system_profiler and Keychain prompts can be
        // slow, so don't make startup wait for them.
        startOutputDeviceMonitoring()
        startHUDSources()
        restartRefreshLoops()

        if preferences.audioVisualizerEnabled {
            startVisualizer()
        }

        // The Keychain may show a prompt after a rebuild. Let the rest of the app start
        // while this waits.
        Task { [weak self] in await self?.configureSpotify() }

        // Cosmetic: it names the Mac in Settings and in the About tab.
        let hardwareProvider = serviceContainer.hardware
        Task.detached(priority: .utility) {
            let identity = await hardwareProvider.identity()
            await MainActor.run { [weak self] in
                self?.applyHardware(identity)
            }
        }
    }

    func stopRefreshLoops() {
        for task in refreshTasks.values { task.cancel() }
        refreshTasks.removeAll()
    }

    func shutDown() {
        stopRefreshLoops()
        activityDismissTask?.cancel()
        hudDismissTask?.cancel()
        stopHUDSources()
        serviceContainer.visualizer.stop()
        serviceContainer.outputDevices.stop()
    }

    // MARK: - Output device

    /// Watch Core Audio's default output for wireless device connections. This doesn't need
    /// Bluetooth permission.
    private func startOutputDeviceMonitoring() {
        outputDevice = serviceContainer.outputDevices.current()
        serviceContainer.outputDevices.start { [weak self] device in
            Task { @MainActor in
                self?.outputDeviceChanged(device)
            }
        }
    }

    private func outputDeviceChanged(_ device: AudioOutputDevice?) {
        let previous = outputDevice
        outputDevice = device

        guard let device, device.isWireless else { return }
        // Only on an actual change, so re-reading the same device (which
        // happens on unrelated audio reconfiguration) does not re-announce it.
        guard previous?.deviceID != device.deviceID else { return }

        Log.audio.notice("output switched to \(device.name, privacy: .public)")
        announce(device)
    }

    private func announce(_ device: AudioOutputDevice) {
        let activity = DeviceActivity(
            name: device.name,
            symbol: device.isAirPods ? "airpods.pro" : device.transport.symbol,
            batteryLevel: WirelessBattery.level(forDeviceNamed: device.name)
        )
        deviceActivity = activity

        // An announcement must never steal a panel the user has open.
        if surfaceState == .collapsed { present(.activity) }

        activityDismissTask?.cancel()
        activityDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, let self else { return }
            self.deviceActivity = nil
            if self.surfaceState == .activity {
                self.present(self.isHovering ? .peek : .collapsed)
            }
        }
    }

    /// Shows the announcement on demand, for previews and for testing the look.
    func showDeviceActivity(_ activity: DeviceActivity) {
        deviceActivity = activity
        if surfaceState == .collapsed { present(.activity) }
    }

    // MARK: - Surface transitions

    func setHovering(_ hovering: Bool) {
        isHovering = hovering
    }

    /// Tell AppKit when the drawn surface changes, so its clickable and hover areas still
    /// match.
    var onSurfaceStateChanged: (() -> Void)?

    func present(_ state: SurfaceState) {
        guard surfaceState != state else { return }
        let wasOpen = surfaceState.isOpen
        surfaceState = state
        onSurfaceStateChanged?()

        // Only restart the loops when the panel's open state changes. Restarting on every
        // animation step sends duplicate player requests.
        if wasOpen != state.isOpen {
            restartLoop("media")
            restartLoop("telemetry")
        } else if state != .collapsed {
            // Anything other than resting means the user is looking at it, so
            // the lazy resting cadence is erased before it can be seen.
            refreshNow("media")
        }
    }

    func toggle() {
        present(surfaceState.isOpen ? .collapsed : .expanded)
    }

    /// Whether audio capture is running. It can hear browser audio too, even without a
    /// track from Music or Spotify.
    var isVisualizerLive: Bool {
        preferences.audioVisualizerEnabled && visualizerStatus == .running
    }

    /// Keep a resting row beside a loaded song; motion is decided separately.
    var showsIndicator: Bool {
        media?.hasTrack == true || indicatorMode != .resting
    }

    var indicatorMode: AudioIndicatorMode {
        .resolve(captureEnabled: preferences.audioVisualizerEnabled,
                 captureRunning: visualizerStatus == .running,
                 hasTrack: media?.hasTrack == true,
                 isPlaying: media?.state.isPlaying == true,
                 hasAudio: !levels.isSilent && outputVolume > 0)
    }

    /// Marks repeat-one as the app's responsibility for this player.
    func setAppliesRepeatOne(_ applies: Bool) {
        guard applies != appliesRepeatOne else { return }
        appliesRepeatOne = applies
        Log.media.notice("repeat one: \(applies ? "on" : "off", privacy: .public)")
        updatePreferences { $0.appliesRepeatOne = applies }
    }

    /// Notes that the user asked for a different track, so the next change is
    /// theirs and must not be undone.
    func expectTrackChange() {
        expectsTrackChange = true
    }

    /// Return to the previous song if Spotify advances early during repeat-one. Remember
    /// the early transition so the next loop can run ahead of the crossfade.
    private func recoverFromAutomaticAdvance() {
        guard let snapshot = media, snapshot.hasTrack else { return }
        defer {
            lastSeenTrack = (
                snapshot.trackIdentity,
                snapshot.extrapolatedPosition(),
                snapshot.duration
            )
        }

        guard appliesRepeatOne, let previous = lastSeenTrack else { return }
        guard previous.identity != snapshot.trackIdentity else { return }

        // A skip the user asked for is theirs: repeat-one then applies to
        // whatever they landed on.
        if expectsTrackChange {
            expectsTrackChange = false
            return
        }
        guard RepeatOneLoop.looksAutomatic(
            previousPosition: previous.position,
            previousDuration: previous.duration
        ) else { return }

        let early = max(0, previous.duration - previous.position)
        observedEarlyAdvance = max(observedEarlyAdvance, early)
        Log.media.notice(
            "repeat one: player moved on \(early, format: .fixed(precision: 1), privacy: .public)s early; going back"
        )
        stepToPreviousTrack()
    }

    /// Recalculate the loop when a snapshot arrives. Seeking, pausing or changing tracks
    /// can invalidate the previous deadline.
    func scheduleRepeatOneLoop() {
        repeatOneTask?.cancel()
        repeatOneTask = nil

        guard appliesRepeatOne, let snapshot = media, snapshot.hasTrack else { return }
        guard let delay = RepeatOneLoop.delay(
            duration: snapshot.duration,
            position: snapshot.extrapolatedPosition(),
            isPlaying: snapshot.state.isPlaying,
            margin: RepeatOneLoop.margin(observedEarlyAdvance: observedEarlyAdvance)
        ) else { return }

        Log.media.info("repeat one: looping in \(delay, format: .fixed(precision: 1), privacy: .public)s")
        repeatOneTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.loopCurrentTrack()
        }
    }

    private func loopCurrentTrack() {
        guard appliesRepeatOne, let snapshot = media, snapshot.state.isPlaying else { return }
        Log.media.info("repeat one: looping \(snapshot.source.rawValue, privacy: .public)")
        seek(toProgress: 0)
        scheduleRepeatOneLoop()
    }

    /// Decide whether the shared artwork view should be visible in this state.
    var showsArtwork: Bool {
        guard let media, media.hasTrack else { return false }
        switch surfaceState {
        // At rest the thumbnail sits in the menu bar, which some people would
        // rather keep empty.
        case .collapsed: return preferences.idleDisplay != .nothing
        // Neither an activity pill nor a system HUD is about a track.
        case .activity, .hud: return false
        case .peek: return true
        case .expanded: return activeModule == .media
        }
    }

    func select(module: ModuleKind) {
        guard activeModule != module else { return }
        activeModule = module
    }

    func updateGeometry(_ profile: NotchProfile?) {
        guard notchProfile != profile else { return }
        notchProfile = profile
        if let profile {
            Log.window.notice("geometry: \(profile.debugSummary, privacy: .public)")
        }
    }

    // MARK: - Refresh scheduling

    func restartRefreshLoops() {
        stopRefreshLoops()
        restartLoop("media")
        restartLoop("telemetry")
    }

    private func restartLoop(_ name: String) {
        refreshTasks[name]?.cancel()
        refreshTasks[name] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(name)
                let interval = self.interval(for: name)
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
    }

    /// Poll faster while the panel is open. Keep checking the battery when it's closed, but
    /// less often.
    private func interval(for name: String) -> Double {
        switch name {
        case "telemetry":
            // Keep checking battery changes in the background. Thirty seconds is enough
            // when the System tab isn't visible.
            return surfaceState.isOpen ? preferences.telemetryRefreshInterval : 30
        default:
            // AppleScript polling isn't free. Use the configured rate when open and a
            // slower rate when closed. Hovering triggers a fresh reading.
            if surfaceState.isOpen { return preferences.mediaRefreshInterval }
            if media?.state.isPlaying != true { return 8 }
            if preferences.idleDisplay == .nothing { return 8 }
            return max(preferences.mediaRefreshInterval, 4)
        }
    }

    private func refresh(_ name: String) async {
        switch name {
        case "media": await refreshMedia()
        case "telemetry":
            let previousBattery = telemetry.latest?.battery
            let sample = await serviceContainer.telemetry.sample()
            guard !Task.isCancelled else { return }
            telemetry.append(sample)
            handleBatteryChange(from: previousBattery, to: sample.battery)
        default: break
        }
    }

    func refreshNow(_ name: String) {
        Task { [weak self] in await self?.refresh(name) }
    }

    // MARK: - Media

    private func refreshMedia() async {
        readOutputVolume()
        let coordinator = serviceContainer.media
        let sources = await coordinator.runningSources()
        let polled = await coordinator.snapshot()
        let unavailable = await coordinator.allSourcesUnavailable()
        // A hover can replace the polling task while an Apple event is still
        // returning. Don't let that cancelled poll restore an old playing state.
        guard !Task.isCancelled else { return }
        runningPlayers = sources
        mediaPermissionDenied = unavailable

        var snapshot = reconcile(polled)
        // Keep our local repeat-one mode until the user changes it. The player's repeat
        // value doesn't describe the loop Cornice is running.
        if appliesRepeatOne, let current = snapshot {
            snapshot = current.with(repeatMode: .one)
        }
        // With a Web API sign-in the player is the authority on its own repeat
        // mode, so what it says replaces anything inferred locally.
        await refreshSpotifyRepeat(for: snapshot)
        if let reported = spotifyReportedRepeat,
           let current = snapshot, current.source == .spotify {
            snapshot = current.with(repeatMode: reported)
        }
        media = snapshot
        recoverFromAutomaticAdvance()
        scheduleRepeatOneLoop()

        guard let snapshot, snapshot.hasTrack else {
            artwork = nil
            artworkTint = nil
            artworkAccents = []
            artworkTrackIdentity = nil
            return
        }

        // Only refetch when the *track* changed, not on every poll.
        guard snapshot.trackIdentity != artworkTrackIdentity else { return }
        let data = await coordinator.artwork(for: snapshot)
        guard !Task.isCancelled, media?.trackIdentity == snapshot.trackIdentity else { return }
        guard let data, let image = NSImage(data: data) else {
            artwork = nil
            artworkTint = nil
            artworkAccents = []
            return
        }
        artworkTrackIdentity = snapshot.trackIdentity
        applyArtwork(image)
    }

    /// Pulls the newest audio frame. Called from the UI's display timer.
    func sampleLevels() {
        guard preferences.audioVisualizerEnabled else { return }
        let now = Date()
        readOutputVolume(at: now)

        let latest = serviceContainer.visualizer.latestLevels()
        levels = latest
        let wasHearing = hasLiveAudio
        if !latest.isSilent { lastAudioAt = .now }
        // Log the first non-silent frame to confirm that capture is receiving audio.
        if !wasHearing, !latest.isSilent {
            Log.audio.notice("visualiser hearing audio")
            // Heard something, so any earlier complaint was wrong or has been
            // fixed. Arm it again for the next time the grant goes.
            warnedTapIsDeaf = false
        }

        // Warn once if the tap can't hear anything. Don't substitute a fake waveform for
        // silence.
        if audioCaptureLooksBlocked, !warnedTapIsDeaf {
            warnedTapIsDeaf = true
            Log.audio.error("visualiser is running but hearing nothing while a player is playing")
            flashToast("Visualiser can't hear audio. See Settings.")
        }
    }

    /// Read output volume from both polling and the frame timer. Otherwise the bars assume
    /// full volume until the panel opens.
    func readOutputVolume(at now: Date = .now) {
        guard volumeReadAt.map({ now.timeIntervalSince($0) > 0.25 }) ?? true else { return }
        volumeReadAt = now
        // No control at all means the device has no fader, which is not the same
        // as silent. Assume it is playing at full.
        let reading = serviceContainer.outputVolume.current()
        let updated = Float(reading ?? 1)
        if abs(updated - outputVolume) > 0.001 {
            Log.audio.notice(
                "output fader: \(reading.map { String(format: "%.3f", $0) } ?? "no control", privacy: .public)"
            )
        }
        outputVolume = updated
    }

    /// Whether audio arrived recently. A tap can be running but still return silence if
    /// macOS hasn't allowed capture.
    var hasLiveAudio: Bool {
        guard visualizerStatus == .running, let lastAudioAt else { return false }
        return Date().timeIntervalSince(lastAudioAt) < 1.0
    }

    /// Silence alone is not proof of a missing permission. Only flag a tap
    /// that has never heard audio, after giving it time to start.
    var audioCaptureLooksBlocked: Bool {
        guard visualizerStatus == .running, media?.state.isPlaying == true else { return false }
        guard lastAudioAt == nil, let since = visualizerRunningSince else { return false }
        return Date().timeIntervalSince(since) > 15
    }

    /// Start capture in a background task. Building the tap and waiting for permission
    /// mustn't freeze the panel.
    func startVisualizer() {
        let engine = serviceContainer.visualizer
        Task.detached(priority: .utility) {
            let status = engine.start()
            // Apply the result on the main actor after the slow setup finishes.
            await MainActor.run { [weak self] in
                self?.applyVisualizerStatus(status)
            }
        }
    }

    func applyHardware(_ identity: HardwareIdentity?) {
        hardware = identity
        Log.app.notice("running on \(identity?.displayName ?? "unknown", privacy: .public)")
    }

    func applyVisualizerStatus(_ status: AudioVisualizerEngine.Status) {
        visualizerStatus = status
        visualizerRunningSince = status == .running ? Date() : nil
        lastAudioAt = nil
        warnedTapIsDeaf = false
        if case .failed(let reason) = status {
            Log.audio.notice("visualiser disabled: \(reason.message, privacy: .public)")
        }
    }

    func stopVisualizer() {
        serviceContainer.visualizer.stop()
        visualizerStatus = .stopped
        levels = .silent(bandCount: serviceContainer.visualizer.bandCount)
    }

    // MARK: - Mutators for the actions extension

    func applyPreferences(_ updated: Preferences) {
        let tintChanged = preferences.tintFromArtwork != updated.tintFromArtwork
        preferences = updated
        if tintChanged { updateArtworkPalette() }
    }

    func applyArtwork(_ image: NSImage?) {
        artwork = image
        updateArtworkPalette()
    }

    private func updateArtworkPalette() {
        artworkAccents = preferences.tintFromArtwork
            ? artwork.map { ArtworkPalette.accents(of: $0) } ?? [] : []
        artworkTint = artworkAccents.first.map { ArtworkPalette.indicatorColor($0.color) }
    }

    func applyTimers(_ updated: TimerBoard) {
        timers = updated
    }

    func applyTelemetry(_ history: TelemetryHistory) {
        telemetry = history
    }

    func mutateTimers(_ mutate: (inout TimerBoard) -> Void) {
        var copy = timers
        mutate(&copy)
        timers = copy
    }

    func applyMedia(_ snapshot: MediaSnapshot?) {
        media = snapshot
    }

    func applyHUD(_ content: HUDContent?) {
        hudContent = content
    }

    private(set) var toast: String?
    private var toastTask: Task<Void, Never>?

    /// Brief feedback after an action, since this panel has no permanent status area.
    func flashToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
