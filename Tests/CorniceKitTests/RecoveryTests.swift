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
}
