import XCTest
@testable import CorniceKit

/// Formatting lives in the kit rather than in views so its edge cases — zero,
/// negative, absurdly large — are testable without a running app. Each of these
/// is a value that has shown up in a panel and looked wrong.
final class FormattingTests: XCTestCase {

    func testDurationFormatting() {
        XCTAssertEqual(Format.duration(0), "0:00")
        XCTAssertEqual(Format.duration(65), "1:05")
        XCTAssertEqual(Format.duration(599), "9:59")
        XCTAssertEqual(Format.duration(3725), "1:02:05")
        XCTAssertEqual(Format.duration(-5), "0:00", "a timer past its deadline must not render negative")
    }

    /// A server up for three days read as `78:12:55` before this existed, which
    /// is technically correct and completely unreadable.
    func testUptimeSwitchesToDaysPastADay() {
        XCTAssertEqual(Format.uptime(120), "2m")
        XCTAssertEqual(Format.uptime(3725), "1h 2m")
        XCTAssertEqual(Format.uptime(3 * 86_400 + 6 * 3600), "3d 6h")
        XCTAssertEqual(Format.uptime(-10), "0m")
    }

    func testByteFormatting() {
        XCTAssertEqual(Format.bytes(0), "0 B")
        XCTAssertEqual(Format.bytes(512), "512 B")
        XCTAssertEqual(Format.bytes(1536), "1.5 KB")
        XCTAssertEqual(Format.bytes(20 * 1024 * 1024 * 1024), "20 GB")
    }

    func testRateFormatting() {
        XCTAssertEqual(Format.rate(bytesPerSecond: 0), "0 B/s")
        XCTAssertEqual(Format.rate(bytesPerSecond: -5), "0 B/s", "a counter wrap must not show a negative rate")
        XCTAssertEqual(Format.rate(bytesPerSecond: 2048), "2.0 KB/s")
    }

    func testRelativeFormatting() {
        let now = Date()
        XCTAssertEqual(Format.relative(since: now.addingTimeInterval(-10), now: now), "now")
        XCTAssertEqual(Format.relative(since: now.addingTimeInterval(-300), now: now), "5m")
        XCTAssertEqual(Format.relative(since: now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(Format.relative(since: now.addingTimeInterval(-3 * 86_400), now: now), "3d")
        // Clock skew between the Mac and a server can yield a future timestamp.
        XCTAssertEqual(Format.relative(since: now.addingTimeInterval(60), now: now), "soon")
    }

    func testElapsedFormatting() {
        XCTAssertEqual(Format.elapsed(0.84), "840ms")
        XCTAssertEqual(Format.elapsed(2.5), "2.5s")
        XCTAssertEqual(Format.elapsed(72), "1m 12s")
    }

    // MARK: - Redaction

    /// Logs must be able to say *which* credential was involved without ever
    /// containing the credential.
    func testFingerprintHidesTheSecretButIsStable() {
        // Deliberately shaped so it cannot match the credential pattern the CI
        // secret scan looks for — a realistic-looking fake in a test file would
        // fail that check, which is the check working correctly.
        let secret = "ghp_EXAMPLE-not-a-real-token-0000-0000"

        let fingerprint = Redaction.fingerprint(secret)

        XCTAssertFalse(fingerprint.contains("EXAMPLE-not-a-real"))
        XCTAssertTrue(fingerprint.contains("len:\(secret.count)"))
        XCTAssertEqual(fingerprint, Redaction.fingerprint(secret), "stable within a session")
        XCTAssertNotEqual(fingerprint, Redaction.fingerprint(secret + "x"))
        XCTAssertEqual(Redaction.fingerprint(""), "<empty>")
    }

    func testPathRedactionStripsTheHomeDirectory() {
        let path = NSHomeDirectory() + "/code/secret-project"

        let redacted = Redaction.path(path)

        XCTAssertTrue(redacted.hasPrefix("~/"))
        XCTAssertFalse(redacted.contains(NSHomeDirectory()))
        XCTAssertEqual(Redaction.path("/usr/local/bin"), "/usr/local/bin", "paths outside home are unchanged")
    }
}
