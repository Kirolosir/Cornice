import XCTest
@testable import CorniceKit

final class FocusSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)

    func testWorkAndBreakCompleteOneRoundEach() {
        var session = FocusSession()
        session.start(FocusPlan(workMinutes: 1, breakMinutes: 1, rounds: 2), at: start)
        XCTAssertEqual(session.tick(at: start.addingTimeInterval(60)), .work)
        XCTAssertEqual(session.phase, .rest)
        XCTAssertEqual(session.completedRounds, 1)
        XCTAssertTrue(session.waitingForNext)
        XCTAssertFalse(session.isRunning)
        XCTAssertNil(session.tick(at: start.addingTimeInterval(600)))
        session.toggle(at: start.addingTimeInterval(600))
        XCTAssertEqual(session.tick(at: start.addingTimeInterval(660)), .rest)
        XCTAssertEqual(session.phase, .work)
        session.toggle(at: start.addingTimeInterval(700))
        XCTAssertEqual(session.tick(at: start.addingTimeInterval(760)), .work)
        XCTAssertEqual(session.phase, .complete)
        XCTAssertEqual(session.completedRounds, 2)
        XCTAssertNil(session.tick(at: start.addingTimeInterval(900)))
    }

    func testAutomaticCyclesDoNotBurnThroughSleep() {
        var session = FocusSession()
        session.start(FocusPlan(workMinutes: 1, breakMinutes: 1, rounds: 3, autoContinue: true), at: start)
        XCTAssertEqual(session.tick(at: start.addingTimeInterval(3600)), .work)
        XCTAssertEqual(session.completedRounds, 1)
        XCTAssertEqual(session.timer.state.remaining(at: start.addingTimeInterval(3600)), 60)
        XCTAssertTrue(session.isRunning)
    }

    func testPauseDoesNotConsumeTime() {
        var session = FocusSession()
        session.start(FocusPlan(workMinutes: 1), at: start)
        session.toggle(at: start.addingTimeInterval(10))
        XCTAssertEqual(session.timer.state.remaining(at: start.addingTimeInterval(600)), 50)
        session.toggle(at: start.addingTimeInterval(600))
        XCTAssertEqual(session.tick(at: start.addingTimeInterval(650)), .work)
    }

    func testPauseAtDeadlineDoesNotGetStuck() {
        var session = FocusSession()
        session.start(FocusPlan(workMinutes: 1, rounds: 1), at: start)
        session.toggle(at: start.addingTimeInterval(60))
        XCTAssertEqual(session.phase, .complete)
        XCTAssertFalse(session.isActive)
    }

    func testStopAndRestartClearPreviousRound() {
        var session = FocusSession()
        session.start(FocusPlan(workMinutes: 1), at: start)
        session.tick(at: start.addingTimeInterval(60))
        session.stop()
        XCTAssertEqual(session.phase, .idle)
        session.start(FocusPlan(rounds: 2), at: start)
        XCTAssertEqual(session.completedRounds, 0)
        XCTAssertEqual(session.round, 1)
    }

    func testPlanIsCapturedForCurrentSession() {
        var plan = FocusPlan(workMinutes: 25)
        var session = FocusSession()
        session.start(plan, at: start)
        plan.workMinutes = 50
        XCTAssertEqual(session.plan.workMinutes, 25)
        XCTAssertEqual(session.timer.duration, 1500)
    }
}
