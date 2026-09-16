import XCTest
@testable import CorniceKit

/// The timer stores a deadline rather than a countdown, so every test here
/// drives it with explicit dates instead of waiting in real time.
final class FocusTimerTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testStartsFromIdle() {
        var timer = FocusTimer(duration: 1500)

        timer.start(at: start)

        XCTAssertTrue(timer.state.isRunning)
        XCTAssertEqual(timer.state.remaining(at: start), 1500)
        XCTAssertEqual(timer.state.progress(at: start), 0)
    }

    func testRemainingTracksWallClock() {
        var timer = FocusTimer(duration: 600)
        timer.start(at: start)

        XCTAssertEqual(timer.state.remaining(at: start.addingTimeInterval(150)), 450)
        XCTAssertEqual(timer.state.progress(at: start.addingTimeInterval(150)), 0.25, accuracy: 0.001)
    }

    func testPausePreservesRemainingAcrossArbitraryRealTime() {
        var timer = FocusTimer(duration: 600)
        timer.start(at: start)
        timer.pause(at: start.addingTimeInterval(100))

        // An hour passes while paused; remaining must not move.
        XCTAssertEqual(timer.state.remaining(at: start.addingTimeInterval(3600)), 500)
    }

    func testResumeExtendsDeadlineByTimePaused() {
        var timer = FocusTimer(duration: 600)
        timer.start(at: start)
        timer.pause(at: start.addingTimeInterval(100))
        timer.resume(at: start.addingTimeInterval(3600))

        XCTAssertTrue(timer.state.isRunning)
        XCTAssertEqual(timer.state.remaining(at: start.addingTimeInterval(3600)), 500)
        XCTAssertEqual(timer.state.remaining(at: start.addingTimeInterval(4100)), 0)
    }

    /// The tick that crosses the deadline reports completion exactly once, so
    /// the caller can fire a notification without tracking the edge itself.
    func testTickReportsCompletionOnlyOnce() {
        var timer = FocusTimer(duration: 60)
        timer.start(at: start)

        XCTAssertFalse(timer.tick(at: start.addingTimeInterval(59)))
        XCTAssertTrue(timer.tick(at: start.addingTimeInterval(60)))
        XCTAssertFalse(timer.tick(at: start.addingTimeInterval(61)))
        XCTAssertEqual(timer.state, .finished(total: 60))
    }

    /// A Mac that sleeps through the whole session wakes up past the deadline.
    /// The timer must report finished, not a negative remaining.
    func testSurvivesSleepPastDeadline() {
        var timer = FocusTimer(duration: 300)
        timer.start(at: start)

        let afterSleep = start.addingTimeInterval(86_400)
        XCTAssertEqual(timer.state.remaining(at: afterSleep), 0)
        XCTAssertTrue(timer.tick(at: afterSleep))
    }

    func testResumingATimerPausedAtZeroFinishes() {
        var timer = FocusTimer(duration: 60)
        timer.start(at: start)
        timer.pause(at: start.addingTimeInterval(60))

        timer.resume(at: start.addingTimeInterval(61))

        XCTAssertEqual(timer.state, .finished(total: 60))
    }

    func testToggleCyclesThroughStates() {
        var timer = FocusTimer(duration: 60)

        timer.toggle(at: start)
        XCTAssertTrue(timer.state.isRunning)

        timer.toggle(at: start.addingTimeInterval(10))
        XCTAssertEqual(timer.state, .paused(remaining: 50, total: 60))

        timer.toggle(at: start.addingTimeInterval(20))
        XCTAssertTrue(timer.state.isRunning)
    }

    func testResetReturnsToIdle() {
        var timer = FocusTimer(duration: 60)
        timer.start(at: start)

        timer.reset()

        XCTAssertEqual(timer.state, .idle)
        XCTAssertFalse(timer.state.isActive)
    }

    func testPauseIsIgnoredWhenNotRunning() {
        var timer = FocusTimer(duration: 60)

        timer.pause(at: start)

        XCTAssertEqual(timer.state, .idle)
    }

    /// Changing the duration mid-session must not silently move the deadline
    /// of a session the user is already in.
    func testDurationChangeDoesNotDisturbRunningSession() {
        var timer = FocusTimer(duration: 600)
        timer.start(at: start)

        timer.setDuration(minutes: 5)

        XCTAssertEqual(timer.state.remaining(at: start), 600, "running session keeps its deadline")
        XCTAssertEqual(timer.duration, 300, "but the next session uses the new length")
    }

    func testDurationIsClampedToSaneRange() {
        var timer = FocusTimer()

        timer.setDuration(minutes: 0)
        XCTAssertEqual(timer.duration, 60)

        timer.setDuration(minutes: 10_000)
        XCTAssertEqual(timer.duration, 240 * 60)
    }
}
