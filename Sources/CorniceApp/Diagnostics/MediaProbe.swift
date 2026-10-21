import AppKit
import CorniceKit

@MainActor
extension Probes {
    static func probeMediaRefresh() async {
        func check(_ condition: Bool, _ message: String) {
            guard condition else { print("FAIL: \(message)"); exit(1) }
            print("PASS: \(message)")
        }
        let player = RefreshCheckPlayer()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldArtworkRequest.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let model = AppModel(services: PreviewServices.container(
            media: MediaCoordinator(controllers: [player], session: session)
        ))
        await model.start()
        model.stopHUDSources()
        defer { model.shutDown() }

        func waitFor(_ title: String, state: PlaybackState, timeout: Double) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if model.media?.title == title && model.media?.state == state { return true }
                try? await Task.sleep(for: .milliseconds(40))
            }
            return false
        }

        check(await waitFor("First song", state: .playing, timeout: 2), "first track loads")
        check(model.preferences.idleDisplay == .artworkAndSpectrum, "default resting content is the waveform")
        await player.change(title: "Next song", state: .playing)
        check(await waitFor("Next song", state: .playing, timeout: 1.6), "a stalled cover download does not stop song updates")
        await player.change(title: "Next song", state: .paused)
        check(await waitFor("Next song", state: .paused, timeout: 1.6), "pauses update without hovering")
        check(model.indicatorMode == .resting, "paused bars stop while collapsed")
        await player.change(title: "Next song", state: .playing)
        check(await waitFor("Next song", state: .playing, timeout: 2.6), "resuming updates without hovering")
        check(model.indicatorMode == .playback, "playing bars resume while collapsed")
        check(model.surfaceState == .collapsed && !model.isHovering, "the panel stayed closed throughout")

        // This player deliberately leaves its playhead at 20 seconds. A real tap can
        // still hear music while Spotify's scripting connection is stuck.
        let staleDeadline = Date().addingTimeInterval(15)
        while !model.musicNeedsRecovery && Date() < staleDeadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        check(model.musicNeedsRecovery, "a stuck playhead enters recovery")
        check(model.indicatorMode == .resting, "stale metadata cannot animate the fallback")
        var preferences = model.preferences
        preferences.audioVisualizerEnabled = true
        // Set the status and analyzed frame directly; this probe never starts capture
        // or asks for permission.
        model.applyPreferences(preferences)
        model.applyVisualizerStatus(.running)
        let frame = AudioLevels(bands: [0.096, 0.117, 0.096, 0.151, 0.180, 0.129],
                                level: 0.089, isBeat: false, beatIntensity: 0)
        model.applyAudioLevels(frame)
        let audibleMode: AudioIndicatorMode = model.outputVolume > 0 ? .spectrum : .resting
        check(model.indicatorMode == audibleMode, "player recovery preserves measured audio")
        for state in [SurfaceState.peek, .expanded, .collapsed] {
            model.present(state)
            check(model.indicatorMode == audibleMode, "hover transitions preserve the measured indicator")
        }

        await player.change(title: "Next song", state: .paused)
        check(await waitFor("Next song", state: .paused, timeout: 1.6), "a pause clears the stuck player state")
        model.applyAudioLevels(frame)
        check(model.indicatorMode == .resting, "captured sound cannot animate a confirmed paused song")
        await player.change(title: "Next song", state: .playing)
        check(await waitFor("Next song", state: .playing, timeout: 2.6), "playback resumes after recovery")
        await player.fail()
        let failureDeadline = Date().addingTimeInterval(1.6)
        while !(model.musicNeedsRecovery && model.media == nil) && Date() < failureDeadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        check(model.musicNeedsRecovery && model.media == nil, "a failed read clears unconfirmed song details")
        model.applyAudioLevels(frame)
        check(model.indicatorMode == audibleMode, "missing metadata keeps captured audio visible")
        check(model.showsRestingIndicator == (model.outputVolume > 0), "compact audio visibility does not require a song title")
        model.applyAudioLevels(.silent(bandCount: 6))
        check(!model.showsRestingIndicator, "the compact indicator disappears when both song and sound are gone")
        model.applyAudioLevels(frame)
        check(model.showsRestingIndicator == (model.outputVolume > 0), "new audio restores the compact indicator without metadata")
        preferences.idleDisplay = .nothing
        model.applyPreferences(preferences)
        check(!model.showsRestingIndicator, "hidden resting content stays hidden even with captured audio")
        preferences.idleDisplay = .artworkAndSpectrum
        preferences.audioVisualizerEnabled = false
        model.applyPreferences(preferences)
        model.applyVisualizerStatus(.stopped)
        await player.change(title: "Next song", state: .playing)
        check(await waitFor("Next song", state: .playing, timeout: 2.6), "a successful read restores song details")

        await player.deny()
        let deadline = Date().addingTimeInterval(1.6)
        while !model.mediaPermissionDenied && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        check(model.mediaPermissionDenied && model.media == nil, "a single denied player shows the permission state")
        model.retryMediaPermission()
        check(await waitFor("Next song", state: .playing, timeout: 1), "Try Again restores the player without a relaunch")
        check(!model.mediaPermissionDenied, "a successful retry clears the warning")
        print("Media refresh probe passed")
        exit(0)
    }
}

private actor RefreshCheckPlayer: MediaControlling {
    nonisolated let source: MediaSource = .spotify
    private var title = "First song"
    private var state: PlaybackState = .playing
    private var denied = false
    private var failing = false

    func isRunning() async -> Bool { true }
    func snapshot() async throws -> MediaSnapshot? {
        if denied { throw ServiceError.unauthorized(detail: "test denial") }
        if failing { throw ServiceError.timedOut(tool: "test player", seconds: 1) }
        return MediaSnapshot(source: source, state: state, title: title,
                             artist: "Test artist", duration: 180, position: 20,
                             artworkURL: URL(string: "https://cornice.invalid/cover.png"))
    }
    func perform(_ command: MediaCommand) async throws {}
    func resetAuthorization() async { denied = false }
    func change(title: String, state: PlaybackState) {
        self.title = title
        self.state = state
        failing = false
    }
    func fail() { failing = true }
    func deny() { denied = true }
}

// Hold the image request open to check playback on a slow or broken connection.
private final class HeldArtworkRequest: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
