import XCTest
@testable import CorniceKit

/// Looping one track on a player that has no such setting.
final class RepeatOneLoopTests: XCTestCase {

    func testWaitsUntilShortlyBeforeTheEnd() {
        let delay = RepeatOneLoop.delay(duration: 200, position: 30, isPlaying: true)
        XCTAssertEqual(delay ?? 0, 200 - 30 - RepeatOneLoop.margin, accuracy: 0.001)
    }

    /// The margin has to beat the round trip to the player: a command is an
    /// Apple event to another process. Seeking late means the player has already
    /// moved on and the loop is simply broken.
    func testTheMarginBeatsACommandRoundTrip() {
        XCTAssertGreaterThan(RepeatOneLoop.margin, 0.2)
        XCTAssertLessThan(RepeatOneLoop.margin, 1.0, "a noticeably clipped tail")
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

    func testAFreshTrackWaitsAlmostItsWholeLength() {
        let delay = RepeatOneLoop.delay(duration: 180, position: 0, isPlaying: true) ?? 0
        XCTAssertGreaterThan(delay, 179)
        XCTAssertLessThan(delay, 180)
    }
}
