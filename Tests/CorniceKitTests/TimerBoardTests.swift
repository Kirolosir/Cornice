import XCTest
@testable import CorniceKit

/// Every timer derives its remaining time from the wall clock rather than being
/// decremented on a tick, so all of this is driven with explicit dates instead
/// of waiting in real time.
final class TimerBoardTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testAddedTimersStartImmediately() {
        var board = TimerBoard()

        let id = board.add(minutes: 5, at: start)

        XCTAssertNotNil(id)
        XCTAssertTrue(board.entries[0].isRunning, "adding a timer is the user asking for a countdown now")
        XCTAssertEqual(board.entries[0].remaining(at: start), 300, accuracy: 0.01)
    }

    /// The pane shows timers as rows in a fixed-height panel; past a handful
    /// they stop being glanceable, which is the only reason to put a timer in
    /// the notch.
    func testTimerCountIsCapped() {
        var board = TimerBoard()

        for _ in 0..<10 { _ = board.add(minutes: 1, at: start) }

        XCTAssertEqual(board.entries.count, TimerBoard.maximumTimers)
        XCTAssertNil(board.add(minutes: 1, at: start))
    }

    func testSoonestIsTheNearestDeadline() {
        var board = TimerBoard()
        _ = board.add(minutes: 10, at: start)
        let short = board.add(minutes: 2, at: start)

        XCTAssertEqual(board.soonest(at: start)?.id, short)
    }

    func testPausePreservesRemainingAcrossRealTime() {
        var board = TimerBoard()
        let id = board.add(minutes: 10, at: start)!

        board.toggle(id, at: start)
        XCTAssertFalse(board.entries[0].isRunning)

        board.toggle(id, at: start.addingTimeInterval(3600))
        XCTAssertTrue(board.entries[0].isRunning)
        XCTAssertEqual(
            board.entries[0].remaining(at: start.addingTimeInterval(3600)), 600, accuracy: 0.01,
            "an hour paused must not count against the countdown"
        )
    }

    /// Completion is reported exactly once, so the caller can notify without
    /// having to detect the edge itself.
    func testCompletionIsReportedOnce() {
        var board = TimerBoard()
        let id = board.add(minutes: 2, at: start)!

        let first = board.tick(at: start.addingTimeInterval(200))
        let second = board.tick(at: start.addingTimeInterval(400))

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.id, id)
        XCTAssertEqual(second.count, 0)
        XCTAssertTrue(board.entries[0].isFinished)
    }

    func testSurvivesSleepPastDeadline() {
        var board = TimerBoard()
        _ = board.add(minutes: 1, at: start)

        let completed = board.tick(at: start.addingTimeInterval(86_400))

        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(board.entries[0].remaining(at: start.addingTimeInterval(86_400)), 0,
                       "remaining is never negative")
    }

    func testRemoveAndClear() {
        var board = TimerBoard()
        let keep = board.add(minutes: 10, at: start)!
        _ = board.add(minutes: 1, at: start)
        _ = board.tick(at: start.addingTimeInterval(120))

        board.clearFinished()

        XCTAssertEqual(board.entries.count, 1)
        board.remove(keep)
        XCTAssertFalse(board.hasTimers)
    }

    func testAnyRunningReflectsState() {
        var board = TimerBoard()
        let id = board.add(minutes: 5, at: start)!

        XCTAssertTrue(board.anyRunning)
        board.toggle(id, at: start)
        XCTAssertFalse(board.anyRunning)
    }
}
