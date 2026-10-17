import XCTest
@testable import CorniceKit

final class RecoveryTests: XCTestCase {
    func testAStuckPositionRequestsRecoveryAndKeepsTheWarning() {
        let start = Date(timeIntervalSince1970: 1000)
        let song = MediaSnapshot(source: .spotify, state: .playing, title: "Test", artist: "Test", duration: 180, position: 10)
        var monitor = PlaybackFreshness()
        XCTAssertFalse(monitor.needsRecovery(song, at: start))
        XCTAssertTrue(monitor.needsRecovery(song, at: start.addingTimeInterval(12)))
        XCTAssertFalse(monitor.needsRecovery(song, at: start.addingTimeInterval(13)))
        XCTAssertTrue(monitor.isStale)
        XCTAssertFalse(monitor.needsRecovery(song.with(position: 15), at: start.addingTimeInterval(14)))
        XCTAssertFalse(monitor.isStale)
    }

    func testPausingAndTheEndOfASongAreNotStalls() {
        let start = Date(timeIntervalSince1970: 1000)
        let song = MediaSnapshot(source: .spotify, state: .paused, title: "Test", artist: "Test", duration: 180, position: 10)
        var monitor = PlaybackFreshness()
        XCTAssertFalse(monitor.needsRecovery(song, at: start))
        XCTAssertFalse(monitor.needsRecovery(song, at: start.addingTimeInterval(100)))
        XCTAssertFalse(monitor.needsRecovery(song.with(state: .playing, position: 179.5), at: start.addingTimeInterval(200)))
        XCTAssertFalse(monitor.isStale)
    }

    func testRecoveryBackoffRespectsPermissionDenials() {
        var health = MediaConnectionHealth()
        health.failures = 3
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(health.shouldRecover(at: now))
        health.lastRecovery = now
        XCTAssertFalse(health.shouldRecover(at: now.addingTimeInterval(14)))
        XCTAssertTrue(health.shouldRecover(at: now.addingTimeInterval(15)))
        health.permissionDenied = true
        XCTAssertFalse(health.shouldRecover(at: now.addingTimeInterval(600)))
    }

    func testNewInstallsOptInAndOlderSettingsKeepMusicAccess() throws {
        XCTAssertFalse(Preferences().mediaAccessEnabled)
        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"schemaVersion":3}"#.utf8))
        XCTAssertTrue(old.mediaAccessEnabled)
        let fresh = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertFalse(fresh.mediaAccessEnabled)
    }

    func testAnOldDenialCannotUndoReconnect() async {
        let player = HeldRecoveryPlayer(firstReadDenied: true)
        let coordinator = MediaCoordinator(controllers: [player])
        let oldRead = Task { await coordinator.snapshot() }
        await player.waitForRead()
        await coordinator.resetAvailability()
        await player.finishRead()

        let stale = await oldRead.value
        let denied = await coordinator.deniedRunningSources()
        let current = await coordinator.snapshot()
        XCTAssertNil(stale)
        XCTAssertTrue(denied.isEmpty)
        XCTAssertEqual(current?.title, "Current")
    }

    func testAnOldSuccessCannotMarkAResetConnectionHealthy() async {
        let player = HeldRecoveryPlayer()
        let coordinator = MediaCoordinator(controllers: [player])
        let oldRead = Task { await coordinator.snapshot() }
        await player.waitForRead()
        await coordinator.resetAvailability()
        await player.finishRead()

        let stale = await oldRead.value
        let health = await coordinator.connectionHealth()[.spotify]
        XCTAssertNil(stale)
        XCTAssertNil(health?.lastSuccess)
        let current = await coordinator.snapshot()
        XCTAssertEqual(current?.title, "Current")
    }

    func testReadsWaitUntilTheConnectionResetFinishes() async {
        let player = HeldRecoveryPlayer(holdFirstRead: false, holdReset: true)
        let coordinator = MediaCoordinator(controllers: [player])
        let reset = Task { await coordinator.resetAvailability() }
        await player.waitForReset()

        let duringReset = await coordinator.snapshot()
        let reads = await player.reads
        XCTAssertNil(duringReset)
        XCTAssertEqual(reads, 0)
        await player.finishReset()
        await reset.value
        let current = await coordinator.snapshot()
        XCTAssertEqual(current?.title, "Current")
    }

    func testCancelledReadsDoNotReportAConnectionSuccess() async {
        let player = HeldRecoveryPlayer()
        let coordinator = MediaCoordinator(controllers: [player])
        let read = Task { await coordinator.snapshot() }
        await player.waitForRead()
        read.cancel()
        await player.finishRead()

        let cancelled = await read.value
        let health = await coordinator.connectionHealth()[.spotify]
        XCTAssertNil(cancelled)
        XCTAssertNil(health?.lastSuccess)
        XCTAssertEqual(health?.failures, 0)
    }
}

private actor HeldRecoveryPlayer: MediaControlling {
    nonisolated let source: MediaSource = .spotify
    private let firstReadDenied: Bool
    private let holdFirstRead: Bool
    private let holdReset: Bool
    private(set) var reads = 0
    private var pendingRead: CheckedContinuation<Void, Never>?
    private var readStarted: CheckedContinuation<Void, Never>?
    private var pendingReset: CheckedContinuation<Void, Never>?
    private var resetStarted: CheckedContinuation<Void, Never>?

    init(firstReadDenied: Bool = false, holdFirstRead: Bool = true, holdReset: Bool = false) {
        self.firstReadDenied = firstReadDenied
        self.holdFirstRead = holdFirstRead
        self.holdReset = holdReset
    }

    func isRunning() async -> Bool { true }
    func perform(_ command: MediaCommand) async throws {}
    func snapshot() async throws -> MediaSnapshot? {
        reads += 1
        if reads == 1 && holdFirstRead {
            // An already-running player request may finish even after its task is cancelled.
            await withCheckedContinuation { continuation in
                pendingRead = continuation
                readStarted?.resume()
                readStarted = nil
            }
            if firstReadDenied { throw ServiceError.unauthorized(detail: "Old request") }
        }
        return MediaSnapshot(source: source, state: .playing, title: "Current",
                             artist: "Test", duration: 180, position: 20)
    }
    func waitForRead() async {
        if pendingRead != nil { return }
        await withCheckedContinuation { readStarted = $0 }
    }
    func finishRead() { pendingRead?.resume(); pendingRead = nil }
    func resetAuthorization() async {
        guard holdReset else { return }
        await withCheckedContinuation { continuation in
            pendingReset = continuation
            resetStarted?.resume()
            resetStarted = nil
        }
    }
    func waitForReset() async {
        if pendingReset != nil { return }
        await withCheckedContinuation { resetStarted = $0 }
    }
    func finishReset() { pendingReset?.resume(); pendingReset = nil }
}
