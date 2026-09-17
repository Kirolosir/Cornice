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

    // MARK: - Visualiser

    /// Latest analysed audio. Pulled on the UI's own display timer rather than
    /// pushed from the audio thread — see `AudioVisualizerEngine`.
    private(set) var levels: AudioLevels
    private(set) var visualizerStatus: AudioVisualizerEngine.Status = .stopped

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
        hardware = await serviceContainer.hardware.identity()
        Log.app.notice("running on \(self.hardware?.displayName ?? "unknown", privacy: .public)")

        if preferences.audioVisualizerEnabled {
            startVisualizer()
        }
        startOutputDeviceMonitoring()
        restartRefreshLoops()
    }

    func stopRefreshLoops() {
        for task in refreshTasks.values { task.cancel() }
        refreshTasks.removeAll()
    }

    func shutDown() {
        stopRefreshLoops()
        activityDismissTask?.cancel()
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

    func present(_ state: SurfaceState) {
        guard surfaceState != state else { return }
        surfaceState = state
        // Both loops change cadence with the surface state, so both are
        // rebuilt. Any state other than resting means the user is looking at
        // it, which forces an immediate read — this is what makes the lazy
        // collapsed cadence invisible: by the time the peek has finished
        // animating, the data behind it is current.
        if state != .collapsed { refreshNow("media") }
        restartLoop("media")
        restartLoop("telemetry")
    }

    func toggle() {
        present(surfaceState.isOpen ? .collapsed : .expanded)
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
            // Only drawn when open.
            return surfaceState.isOpen ? preferences.telemetryRefreshInterval : 15
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
        case "telemetry": telemetry.append(await serviceContainer.telemetry.sample())
        default: break
        }
    }

    func refreshNow(_ name: String) {
        Task { [weak self] in await self?.refresh(name) }
    }

    // MARK: - Media

    private func refreshMedia() async {
        let coordinator = serviceContainer.media
        runningPlayers = await coordinator.runningSources()
        let snapshot = await coordinator.snapshot()
        mediaPermissionDenied = await coordinator.allSourcesUnavailable()

        media = snapshot

        guard let snapshot, snapshot.hasTrack else {
            artwork = nil
            artworkTint = nil
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
            return
        }
        artwork = image
        artworkTint = preferences.tintFromArtwork ? ArtworkPalette.dominantColor(of: image) : nil
    }

    /// Pulls the newest audio frame. Called from the UI's display timer.
    func sampleLevels() {
        guard preferences.audioVisualizerEnabled else { return }
        levels = serviceContainer.visualizer.latestLevels()
    }

    func startVisualizer() {
        visualizerStatus = serviceContainer.visualizer.start()
        if case .failed(let reason) = visualizerStatus {
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
