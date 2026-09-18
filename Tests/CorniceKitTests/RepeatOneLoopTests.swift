import XCTest
@testable import CorniceKit

/// Looping one track on a player that has no such setting.
final class RepeatOneLoopTests: XCTestCase {

    func testWaitsUntilShortlyBeforeTheEnd() {
        let delay = RepeatOneLoop.delay(duration: 200, position: 30, isPlaying: true)
        XCTAssertEqual(delay ?? 0, 200 - 30 - RepeatOneLoop.baseMargin, accuracy: 0.001)
    }

    /// The margin has to beat the round trip to the player: a command is an
    /// Apple event to another process. Seeking late means the player has already
    /// moved on and the loop is simply broken.
    func testTheMarginBeatsACommandRoundTrip() {
        XCTAssertGreaterThan(RepeatOneLoop.baseMargin, 0.2)
        XCTAssertLessThan(RepeatOneLoop.baseMargin, 3.0, "a noticeably clipped tail")
    }

    func testAPausedTrackIsNotScheduled() {
        XCTAssertNil(RepeatOneLoop.delay(duration: 200, position: 30, isPlaying: false))
    }

    func testATrackWithNoLengthIsNotScheduled() {
        XCTAssertNil(RepeatOneLoop.delay(duration: 0, position: 0, isPlaying: true))
    }

    /// A playhead already past the end is a stale reading. Loop now rather than
    /// computing a negative wait and never firing.
    func testAStalePositionLoopsImmediately() {
        XCTAssertEqual(RepeatOneLoop.delay(duration: 200, position: 240, isPlaying: true), 0)
        XCTAssertEqual(RepeatOneLoop.delay(duration: 200, position: 199.9, isPlaying: true), 0)
    }

    /// Expressed against the margin rather than a literal, so tuning the margin
    /// is not also a test failure.
    func testAFreshTrackWaitsAlmostItsWholeLength() {
        let delay = RepeatOneLoop.delay(duration: 180, position: 0, isPlaying: true) ?? 0
        XCTAssertEqual(delay, 180 - RepeatOneLoop.baseMargin, accuracy: 0.001)
        XCTAssertGreaterThan(delay, 170, "the loop must not fire early in a fresh track")
    }
}

/// Recovering when the player moves on before the track's reported end.
final class RepeatOneRecoveryTests: XCTestCase {

    /// Spotify can be set to crossfade, which starts the next track seconds
    /// before the current one reaches the length it reports — and that setting
    /// lives on Spotify's servers, so it cannot be read. Measured here, a 230.5
    /// second track was abandoned at about 226.
    func testATrackChangeNearTheEndReadsAsThePlayerMovingOn() {
        XCTAssertTrue(RepeatOneLoop.looksAutomatic(previousPosition: 226, previousDuration: 230.5))
        XCTAssertTrue(RepeatOneLoop.looksAutomatic(previousPosition: 230.4, previousDuration: 230.5))
    }

    /// A change from the middle of a track is the user skipping, and repeat-one
    /// then applies to whatever they landed on rather than dragging them back.
    func testAChangeFromTheMiddleReadsAsASkip() {
        XCTAssertFalse(RepeatOneLoop.looksAutomatic(previousPosition: 30, previousDuration: 230.5))
        XCTAssertFalse(RepeatOneLoop.looksAutomatic(previousPosition: 0, previousDuration: 230.5))
    }

    func testATrackWithNoLengthNeverReadsAsAnAdvance() {
        XCTAssertFalse(RepeatOneLoop.looksAutomatic(previousPosition: 0, previousDuration: 0))
    }

    /// The margin is learned: the first loop that gets away sets the distance
    /// for the next one.
    func testTheMarginGrowsToBeatTheObservedAdvance() {
        let learned = RepeatOneLoop.margin(observedEarlyAdvance: 4.3)
        XCTAssertGreaterThan(learned, 4.3, "it has to land ahead of the crossfade, not on it")
        XCTAssertEqual(RepeatOneLoop.margin(observedEarlyAdvance: 0), RepeatOneLoop.baseMargin)
    }

    /// And a learned margin actually moves the loop earlier.
    func testALearnedMarginLoopsEarlier() {
        let base = RepeatOneLoop.delay(duration: 200, position: 0, isPlaying: true) ?? 0
        let learned = RepeatOneLoop.delay(
            duration: 200, position: 0, isPlaying: true,
            margin: RepeatOneLoop.margin(observedEarlyAdvance: 6)
        ) ?? 0
        XCTAssertLessThan(learned, base - 5)
    }
}
