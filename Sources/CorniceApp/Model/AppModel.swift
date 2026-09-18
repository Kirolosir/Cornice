import AppKit
import Observation
import SwiftUI
import CorniceKit

/// All observable application state.
///
/// A coordinator, not a worker: every operation is delegated to a service, so
/// this type holds scheduling and state transitions and nothing else.
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
    /// A toggle the user has just pressed, held until the player confirms it.
    ///
    /// Players do not apply a command synchronously. Measured against Spotify, a
    /// shuffle change was still being reported the old way 154 ms after the
    /// command and had landed by 320 ms — so a poll fired in between reads the
    /// stale value and overwrites the button's own state, which looks exactly
    /// like a button that does nothing.
    private struct PendingToggle {
        var isShuffling: Bool?
        var repeatMode: RepeatMode?
        var state: PlaybackState?
        var until: Date
    }

    private var pendingToggle: PendingToggle?

    /// Repeat-one the app is providing itself, for a player that cannot be asked
    /// for it. Held here because the player has no way to report it back.
    private(set) var appliesRepeatOne = false
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
    /// pushed from the audio thread — see `AudioVisualizerEngine`.
    private(set) var levels: AudioLevels
    private(set) var visualizerStatus: AudioVisualizerEngine.Status = .stopped
    /// When the analyser last started, so "it has never heard anything" can be
    /// told from "it has not been running long enough to say".
    private var visualizerRunningSince: Date?
    /// When the analyser last reported something other than silence.
    private var lastAudioAt: Date?
    /// How far the output fader is up, 0...1. Re-read a few times a second
    /// rather than every frame: it is cheap, but it is not free, and nobody
    /// moves a volume slider at sixty hertz.
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
        // Order matters here, and it has taken a stopwatch to see why more than
        // once. Nothing the app actually *does* may sit behind something slow.
        //
        // The two offenders were the audio tap — building a process tap, an
        // aggregate device and an IO proc, measured at 5.2 s — and the machine's
        // marketing name, which shells out to `system_profiler` and can take
        // longer still. Both used to run before the polling loop started, so the
        // app read nothing at all until they finished: no track, no artwork, and
        // no repeat-one timer, which is a long time for a thing whose whole job
        // is to show what is playing.
        //
        // The cheap event sources and the polling loop go first. Everything slow
        // runs on its own task and reports back when it is ready.
        startOutputDeviceMonitoring()
        startHUDSources()
        restartRefreshLoops()

        if preferences.audioVisualizerEnabled {
            startVisualizer()
        }

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

    /// Watches the default output and announces wireless devices as they connect.
    ///
    /// Event-driven through Core Audio rather than polled, and deliberately not
    /// via CoreBluetooth: connecting AirPods changes the default output device,
    /// which is both the moment worth reacting to and a signal that needs no
    /// Bluetooth permission to observe.
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
        // Only on an actual change, so re-reading the same device — which
        // happens on unrelated audio reconfiguration — does not re-announce it.
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

    /// Called whenever the drawn surface changes size, so AppKit's hit-testing
    /// and hover regions can be brought back into step with it.
    ///
    /// SwiftUI knows what it drew; AppKit does not. Any state change that skips
    /// this leaves a surface that is visible but not clickable.
    var onSurfaceStateChanged: (() -> Void)?

    func present(_ state: SurfaceState) {
        guard surfaceState != state else { return }
        let wasOpen = surfaceState.isOpen
        surfaceState = state
        onSurfaceStateChanged?()

        // Both loops poll faster while the panel is open, so they are rebuilt
        // when that changes — and `restartLoop` reads immediately, so opening
        // already refreshes. Rebuilding on *every* transition instead, with a
        // separate forced read on top, meant one hover fired four Apple events
        // in a millisecond: peek and expanded, twice each. At roughly 100 ms of
        // CPU per round trip that is most of a frame budget spent re-reading
        // what had just been read.
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

    /// Whether the spectrum analyser is running and its output can be trusted.
    ///
    /// Deliberately not "is a player playing": the tap hears everything the Mac
    /// outputs, including a browser tab that no scriptable player knows about.
    /// Tying the indicator to Spotify's reported state meant it sat still
    /// through music the app could plainly hear.
    var isVisualizerLive: Bool {
        preferences.audioVisualizerEnabled && visualizerStatus == .running
    }

    /// Whether the playing indicator has anything to report.
    ///
    /// Either the analyser is live — in which case it draws real audio, whatever
    /// is producing it — or a player says it is playing, in which case the bars
    /// report that and nothing more.
    var showsIndicator: Bool {
        isVisualizerLive || media?.state.isPlaying == true
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

    /// Puts the track back when the player moved on by itself.
    ///
    /// The pre-emptive loop is the seamless path, but it can be beaten: Spotify
    /// can be set to crossfade, which starts the next track seconds before the
    /// current one reaches the length it reports, and that setting lives on
    /// Spotify's servers where it cannot be read. So the app also watches for a
    /// track changing on its own near the end and goes back — and remembers how
    /// early it happened, so the next loop lands ahead of the crossfade rather
    /// than behind it and no second recovery is needed.
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
        previousTrack()
    }

    /// Arranges for the track to loop before the player can move on.
    ///
    /// Rescheduled on every snapshot rather than left to run: the playhead moves
    /// when the user scrubs, the track changes, and playback pauses, and each of
    /// those makes the previous plan wrong.
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

    /// Whether the travelling artwork is on screen at all.
    ///
    /// It is one view across every state, so this is asked once rather than
    /// being decided independently by each layout — which is how it ended up
    /// visible in one state and missing in the next.
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
                let interval = await self.interval(for: name)
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
    }

    /// Refresh cadence, adjusted for whether the panel is actually on screen.
    ///
    /// Telemetry is only drawn when expanded, so it backs right off otherwise.
    /// Media keeps its cadence regardless, because the collapsed surface shows
    /// the current track and a stale title there is the most visible possible
    /// bug.
    private func interval(for name: String) -> Double {
        switch name {
        case "telemetry":
            // Drawn in the System module when the panel is open, but also the
            // only source of battery transitions, which have to be noticed
            // whether anyone is looking or not. Thirty seconds closed is a
            // compromise: fast enough that a charge notice is not stale, slow
            // enough to be free.
            return surfaceState.isOpen ? preferences.telemetryRefreshInterval : 30
        default:
            // Each media poll is several Apple events to another process, and
            // profiling puts one Spotify round-trip at roughly 100 ms of CPU —
            // its scripting handler is not cheap. That cost is unavoidable on
            // the supported API, so the cadence follows what is on screen
            // rather than a fixed rate.
            //
            // Open: the scrubber and playhead are visible, so use the
            // configured rate. Collapsed: the surface shows album art and a
            // title that only change between tracks, so poll lazily — and any
            // staleness is erased by the immediate refresh on hover, before
            // the user can see it.
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
        runningPlayers = await coordinator.runningSources()
        let polled = await coordinator.snapshot()
        mediaPermissionDenied = await coordinator.allSourcesUnavailable()

        var snapshot = reconcile(polled)
        // The player cannot report a mode it does not have, so a repeat-one the
        // app is providing is layered back on.
        //
        // Held purely locally, and never cleared from a reading. Deciding it was
        // off whenever the player reported repeat off made the feature
        // self-destructing: the app sets the player's own repeat *off* for this
        // mode — the loop is what does the repeating — so an honest poll saying
        // "repeat is off" is the normal case, not a reason to give up. Any
        // dropped command or race did the same thing. It now ends only when the
        // button is pressed again.
        if appliesRepeatOne, let current = snapshot {
            snapshot = current.with(repeatMode: .one)
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
        artworkTrackIdentity = snapshot.trackIdentity

        guard let data = await coordinator.artwork(for: snapshot),
              let image = NSImage(data: data) else {
            artwork = nil
            artworkTint = nil
            artworkAccents = []
            return
        }
        artwork = image
        // Extracted once per track, not once per poll: this walks the cover.
        let accents = preferences.tintFromArtwork ? ArtworkPalette.accents(of: image) : []
        artworkAccents = accents
        artworkTint = accents.first?.color
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
        // Logged on the edge only. "Is the visualiser working?" is otherwise
        // unanswerable from outside the app, because macOS reports a tap it has
        // denied as running and simply feeds it silence.
        if !wasHearing, !latest.isSilent {
            Log.audio.notice("visualiser hearing audio")
        }
    }

    /// Re-reads the output fader, at most a few times a second.
    ///
    /// Called from the frame timer while the surface is visible *and* from the
    /// polling loop, which always runs. Reading it only from the frame timer
    /// meant the value stayed at its initial full-volume assumption until the
    /// panel was first opened — and the bars are sized by it.
    func readOutputVolume(at now: Date = .now) {
        guard volumeReadAt.map({ now.timeIntervalSince($0) > 0.25 }) ?? true else { return }
        volumeReadAt = now
        // No control at all means the device has no fader, which is not the same
        // as silent — assume it is playing at full.
        let reading = serviceContainer.outputVolume.current()
        let updated = Float(reading ?? 1)
        if abs(updated - outputVolume) > 0.001 {
            Log.audio.notice(
                "output fader: \(reading.map { String(format: "%.3f", $0) } ?? "no control", privacy: .public)"
            )
        }
        outputVolume = updated
    }

    /// Whether the analyser has heard anything recently.
    ///
    /// macOS hands a process tap silence — not an error — when audio capture has
    /// not been granted, so "the tap is running" says nothing about whether it
    /// can hear. This is the question the interface actually needs answered.
    var hasLiveAudio: Bool {
        guard visualizerStatus == .running, let lastAudioAt else { return false }
        return Date().timeIntervalSince(lastAudioAt) < 1.0
    }

    /// Whether the bars should follow the analyser rather than the standard bob.
    ///
    /// Deliberately slow to change, and separate from `hasLiveAudio` for that
    /// reason. Driven by whether audio arrived in the *last second* — which is
    /// what the indicator used to use — the bars swapped between two quite
    /// different motions at every gap between tracks and in any quiet passage.
    /// That swap is the glitch: one moment they are following the music, the
    /// next they are doing a synthetic wave, and back again a second later.
    ///
    /// Whether there is sound right now is already carried by the band values,
    /// which fall to zero on their own. This answers only whether the analyser
    /// can hear *at all*, which changes about once a session.
    var barsFollowAudio: Bool {
        guard preferences.audioVisualizerEnabled, visualizerStatus == .running else { return false }
        guard let lastAudioAt else {
            // Nothing heard yet. macOS feeds a tap it has refused silence rather
            // than an error, so after long enough this is the shape of a denied
            // permission — fall back to the bob rather than leaving a dead row.
            guard let since = visualizerRunningSince else { return true }
            return Date().timeIntervalSince(since) < 15
        }
        // Long enough to cover a gap between tracks, a quiet intro, or a pause.
        return Date().timeIntervalSince(lastAudioAt) < 8
    }

    /// The tap is running, the music is playing, and it has heard nothing.
    ///
    /// The one combination that means the permission is missing rather than the
    /// room being quiet.
    var audioCaptureLooksBlocked: Bool {
        guard visualizerStatus == .running, media?.state.isPlaying == true else { return false }
        guard let lastAudioAt else { return true }
        return Date().timeIntervalSince(lastAudioAt) > 4
    }

    /// Starts audio capture off the main actor.
    ///
    /// `start()` builds a Core Audio process tap, an aggregate device and an IO
    /// proc, and can additionally block on a TCC prompt. Run on the main actor —
    /// which is where it used to run — that is five seconds in which the surface
    /// does not respond to the pointer and no other event source has been
    /// attached yet. The engine is its own lock-guarded object, so there is no
    /// reason for any of it to happen here.
    func startVisualizer() {
        let engine = serviceContainer.visualizer
        Task.detached(priority: .utility) {
            let status = engine.start()
            // Hopped back rather than captured: `self` is main-actor isolated,
            // and the whole point of this detour is that the slow part happens
            // somewhere else.
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
        preferences = updated
    }

    func applyTimers(_ updated: TimerBoard) {
        timers = updated
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

    /// Brief acknowledgement of an action.
    ///
    /// The panel does not take focus and there is no status area to write to,
    /// so without this a control gives no feedback and people press it twice.
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
