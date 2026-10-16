import XCTest
@testable import CorniceKit

final class SessionStoreTests: XCTestCase {
    func testTimerIdentityAndPausedTimeSurviveRelaunch() throws {
        let start = Date(timeIntervalSince1970: 1000)
        var board = TimerBoard()
        let id = board.add(minutes: 25, at: start)!
        board.toggle(id, at: start.addingTimeInterval(60))
        let snapshot = SessionSnapshot(timers: board, revision: 10)
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: data).restored(at: start.addingTimeInterval(600))
        XCTAssertTrue(restored.isValid)
        XCTAssertEqual(restored.timers.entries.first?.id, id)
        XCTAssertEqual(restored.timers.entries.first?.remaining(at: start.addingTimeInterval(600)), 1440)
    }

    func testOverdueSessionsRestoreWithoutStartingAnotherWorkPeriod() {
        let start = Date(timeIntervalSince1970: 1000)
        var board = TimerBoard()
        board.add(minutes: 1, at: start)
        var focus = FocusSession()
        focus.start(FocusPlan(workMinutes: 1, breakMinutes: 5, rounds: 2, autoContinue: true), at: start)
        let snapshot = SessionSnapshot(timers: board, focus: focus).restored(at: start.addingTimeInterval(3600))
        XCTAssertTrue(snapshot.timers.entries.first!.isFinished)
        XCTAssertEqual(snapshot.focus.phase, .rest)
        XCTAssertTrue(snapshot.focus.waitingForNext)
        XCTAssertFalse(snapshot.focus.isRunning)
    }

    func testOlderSavesCannotOverwriteNewState() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sessions.json")
        let store = SessionStore(url: url)
        var board = TimerBoard()
        let id = board.add(minutes: 25)!
        try await store.save(SessionSnapshot(timers: board, revision: 10))
        try await store.save(SessionSnapshot(revision: 9))
        let loaded = await SessionStore(url: url).load()
        XCTAssertEqual(loaded.timers.entries.first?.id, id)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testCorruptFileIsKeptForInspection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("sessions.json")
        try Data("broken JSON".utf8).write(to: url)
        let loaded = await SessionStore(url: url).load()
        XCTAssertTrue(loaded.timers.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
    }

    func testDuplicateTimerIDsAreRejected() {
        let entry = TimerEntry(label: "Test", minutes: 5)
        XCTAssertFalse(SessionSnapshot(timers: TimerBoard(entries: [entry, entry])).isValid)
    }
}
