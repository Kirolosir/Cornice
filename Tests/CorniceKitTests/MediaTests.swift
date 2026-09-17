import XCTest
@testable import CorniceKit

/// The reply from a player is a delimited string, and every difference between
/// Music and Spotify lives in how it is parsed. Each of these is a case that
/// produces a plausible-looking but wrong UI when it is got wrong.
final class MediaParsingTests: XCTestCase {

    private let separator = "\u{1f}"

    private func row(_ fields: [String]) -> String {
        fields.joined(separator: separator)
    }

    /// Spotify reports duration in **milliseconds**. Treating it as seconds
    /// renders a four-minute track as 272,394 seconds.
    func testSpotifyDurationIsConvertedFromMilliseconds() {
        let raw = row(["playing", "Do I Wanna Know?", "Arctic Monkeys", "AM",
                       "272394", "182.813", "https://i.scdn.co/image/abc",
                       "false", "off", "96"])

        let snapshot = ScriptedMediaController.parse(raw, source: .spotify)

        XCTAssertEqual(snapshot?.duration ?? 0, 272.394, accuracy: 0.001)
        XCTAssertEqual(snapshot?.position ?? 0, 182.813, accuracy: 0.001)
    }

    /// Apple Music reports seconds, and must not be divided.
    func testAppleMusicDurationIsUsedAsSeconds() {
        let raw = row(["playing", "Weightless", "Marconi Union", "Ambient",
                       "485.2", "61.5", "", "true", "one", "50"])

        let snapshot = ScriptedMediaController.parse(raw, source: .appleMusic)

        XCTAssertEqual(snapshot?.duration ?? 0, 485.2, accuracy: 0.01)
        XCTAssertTrue(snapshot?.isShuffling ?? false)
        XCTAssertEqual(snapshot?.repeatMode, .one)
        XCTAssertNil(snapshot?.artworkURL, "Music has no artwork URL; it hands over raw data")
    }

    /// Both players report volume 0–100, not 0–1.
    func testVolumeIsNormalised() {
        let raw = row(["playing", "t", "a", "b", "1000", "0", "", "false", "off", "96"])

        XCTAssertEqual(ScriptedMediaController.parse(raw, source: .spotify)?.volume ?? 0,
                       0.96, accuracy: 0.001)
    }

    func testStoppedPlayerHasNoTrack() {
        let raw = row(["stopped", "", "", "", "0", "0", "", "false", "off", "0"])

        let snapshot = ScriptedMediaController.parse(raw, source: .spotify)

        XCTAssertEqual(snapshot?.state, .stopped)
        XCTAssertFalse(snapshot?.hasTrack ?? true)
    }

    /// Track and album names contain every printable character there is, which
    /// is exactly why the field separator is a non-printable one.
    func testAwkwardTrackNamesSurvive() {
        let title = "A|B\tC — “quoted” 90%"
        let raw = row(["playing", title, "Ar|tist", "Al\tbum", "1000", "0", "", "false", "off", "10"])

        XCTAssertEqual(ScriptedMediaController.parse(raw, source: .spotify)?.title, title)
    }

    func testMalformedRepliesAreRejected() {
        XCTAssertNil(ScriptedMediaController.parse("playing\u{1f}x", source: .spotify))
        XCTAssertNil(ScriptedMediaController.parse("", source: .spotify))
    }

    /// AppleScript renders reals in the *user's* locale, so a machine set to a
    /// comma-decimal locale returns "182,813". Parsing that as zero would make
    /// the playhead sit at the start for a large fraction of the world.
    func testNumbersParseInCommaDecimalLocales() {
        XCTAssertEqual(ScriptedMediaController.number("182,813"), 182.813, accuracy: 0.001)
        XCTAssertEqual(ScriptedMediaController.number("182.813"), 182.813, accuracy: 0.001)
        XCTAssertEqual(ScriptedMediaController.number("nonsense"), 0)
    }

    /// The same problem in reverse: a comma-decimal string is a syntax error
    /// inside the AppleScript we generate for a seek.
    func testSeekValuesAreFormattedForPOSIX() {
        XCTAssertFalse(ScriptedMediaController.format(12.5).contains(","))
        XCTAssertTrue(ScriptedMediaController.format(12.5).hasPrefix("12.5"))
    }

    // MARK: - The cheap poll

    /// Profiling put one Spotify round-trip at ~100 ms of CPU, so the frequent
    /// poll carries only what changes between reads. It still has to get the
    /// millisecond conversion right, because the playhead depends on it.
    func testLightReadParsesLiveValues() {
        let raw = row(["playing", "Do I Wanna Know?", "272394", "182.813", "96"])

        let light = ScriptedMediaController.parseLight(raw, source: .spotify)

        XCTAssertEqual(light?.state, .playing)
        XCTAssertEqual(light?.title, "Do I Wanna Know?")
        XCTAssertEqual(light?.duration ?? 0, 272.394, accuracy: 0.001)
        XCTAssertEqual(light?.position ?? 0, 182.813, accuracy: 0.001)
        XCTAssertEqual(light?.volume ?? 0, 0.96, accuracy: 0.001)
    }

    func testLightReadLeavesAppleMusicDurationInSeconds() {
        let raw = row(["paused", "Weightless", "485.2", "61.5", "50"])

        XCTAssertEqual(
            ScriptedMediaController.parseLight(raw, source: .appleMusic)?.duration ?? 0,
            485.2, accuracy: 0.01
        )
    }

    func testLightReadHandlesStoppedAndMalformed() {
        let stopped = row(["stopped", "", "0", "0", "0"])

        XCTAssertEqual(ScriptedMediaController.parseLight(stopped, source: .spotify)?.state, .stopped)
        XCTAssertNil(ScriptedMediaController.parseLight("playing", source: .spotify))
    }
}

final class MediaSnapshotTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        state: PlaybackState = .playing,
        duration: TimeInterval = 200,
        position: TimeInterval = 50,
        title: String = "t"
    ) -> MediaSnapshot {
        MediaSnapshot(source: .spotify, state: state, title: title, artist: "a",
                      duration: duration, position: position, capturedAt: start)
    }

    /// The player is polled about once a second but the scrubber redraws every
    /// frame, so the playhead is advanced locally between samples. Without
    /// this the bar ticks once a second instead of gliding.
    func testPositionIsExtrapolatedWhilePlaying() {
        let playing = snapshot()

        XCTAssertEqual(playing.extrapolatedPosition(at: start.addingTimeInterval(10)), 60, accuracy: 0.01)
        XCTAssertEqual(playing.progress(at: start.addingTimeInterval(50)), 0.5, accuracy: 0.01)
        XCTAssertEqual(playing.remaining(at: start.addingTimeInterval(50)), 100, accuracy: 0.01)
    }

    func testPausedPositionDoesNotAdvance() {
        let paused = snapshot(state: .paused)

        XCTAssertEqual(paused.extrapolatedPosition(at: start.addingTimeInterval(500)), 50, accuracy: 0.01)
    }

    /// The Mac can sleep for hours between samples.
    func testExtrapolationIsClampedToDuration() {
        XCTAssertEqual(
            snapshot().extrapolatedPosition(at: start.addingTimeInterval(99_999)), 200, accuracy: 0.01
        )
    }

    func testZeroDurationDoesNotDivideByZero() {
        XCTAssertEqual(snapshot(duration: 0, position: 0).progress(at: start), 0)
    }

    /// Artwork is refetched on identity change, so identity must ignore the
    /// playhead — otherwise every poll looks like a new song and the cover
    /// reloads continuously.
    func testTrackIdentityIgnoresPlayhead() {
        let early = snapshot(position: 10)
        let late = MediaSnapshot(source: .spotify, state: .playing, title: "t", artist: "a",
                                 duration: 200, position: 180,
                                 capturedAt: start.addingTimeInterval(170))

        XCTAssertEqual(early.trackIdentity, late.trackIdentity)
        XCTAssertNotEqual(early.trackIdentity, snapshot(title: "other").trackIdentity)
    }
}

/// A player whose behaviour the test dictates.
private actor StubController: MediaControlling {
    nonisolated let source: MediaSource
    private let state: PlaybackState
    private let title: String
    private let running: Bool
    private let error: ServiceError?

    init(source: MediaSource, state: PlaybackState, title: String,
         running: Bool = true, error: ServiceError? = nil) {
        self.source = source
        self.state = state
        self.title = title
        self.running = running
        self.error = error
    }

    nonisolated func isRunning() async -> Bool { running }

    func snapshot() async throws -> MediaSnapshot? {
        if let error { throw error }
        return MediaSnapshot(source: source, state: state, title: title, artist: "a",
                             duration: 100, position: 10)
    }

    func perform(_ command: MediaCommand) async throws {}
}

final class MediaCoordinatorTests: XCTestCase {

    /// Several players open at once is ordinary — Spotify paused in the
    /// background while Music plays. Whichever is playing wins.
    func testPlayingSourceWins() async {
        let coordinator = MediaCoordinator(controllers: [
            StubController(source: .appleMusic, state: .paused, title: "Paused Song"),
            StubController(source: .spotify, state: .playing, title: "Playing Song"),
        ])

        let snapshot = await coordinator.snapshot()

        XCTAssertEqual(snapshot?.title, "Playing Song")
    }

    /// Pausing must not make the panel jump to a different app's stale track.
    func testSelectionIsStableWhileEverythingIsPaused() async {
        let coordinator = MediaCoordinator(controllers: [
            StubController(source: .appleMusic, state: .paused, title: "Music Track"),
            StubController(source: .spotify, state: .paused, title: "Spotify Track"),
        ])

        let first = await coordinator.snapshot()?.source
        let second = await coordinator.snapshot()?.source

        XCTAssertEqual(first, second)
    }

    /// Scripting a stopped application would launch it, so it is skipped.
    func testStoppedPlayersAreIgnored() async {
        let coordinator = MediaCoordinator(controllers: [
            StubController(source: .spotify, state: .playing, title: "X", running: false),
        ])

        let snapshot = await coordinator.snapshot()

        XCTAssertNil(snapshot)
    }

    /// The user said no. Re-prompting every second would be hostile.
    func testRefusedAutomationIsRecordedAndResettable() async {
        let coordinator = MediaCoordinator(controllers: [
            StubController(source: .spotify, state: .playing, title: "X",
                           error: .unauthorized(detail: "denied")),
        ])

        _ = await coordinator.snapshot()
        let denied = await coordinator.allSourcesUnavailable()
        await coordinator.resetAvailability()
        let afterReset = await coordinator.allSourcesUnavailable()

        XCTAssertTrue(denied)
        XCTAssertFalse(afterReset, "the user can retry after granting permission")
    }

    /// A player open with nothing loaded raises rather than returning empty,
    /// and that is a normal state rather than a permission problem.
    func testNonAuthorisationErrorsDoNotDisableTheSource() async {
        let coordinator = MediaCoordinator(controllers: [
            StubController(source: .spotify, state: .playing, title: "X",
                           error: .invalidConfiguration(reason: "nothing loaded")),
        ])

        _ = await coordinator.snapshot()

        let denied = await coordinator.allSourcesUnavailable()
        XCTAssertFalse(denied)
    }
}
