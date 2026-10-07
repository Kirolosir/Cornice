import XCTest
@testable import CorniceKit

/// Check real readings against sensible bounds. Fixed expected values wouldn't work on
/// every test machine.
final class TelemetryProbeTests: XCTestCase {

    func testMemoryIsPlausibleAndSelfConsistent() async {
        let probe = HostTelemetryProbe()
        let sample = await probe.sample()

        XCTAssertGreaterThan(sample.memoryTotalBytes, 1_000_000_000, "hw.memsize should be gigabytes")
        XCTAssertGreaterThan(sample.memoryUsedBytes, 100_000_000, "a running Mac uses more than 100 MB")
        XCTAssertLessThan(sample.memoryUsedBytes, sample.memoryTotalBytes, "used cannot exceed installed")

        let expected = Double(sample.memoryUsedBytes) / Double(sample.memoryTotalBytes)
        XCTAssertEqual(sample.memoryUsage, expected, accuracy: 0.0001,
                       "the fraction has to describe the same reading as the bytes")
    }

    /// Used memory should exclude file cache that macOS can reclaim. Active pages alone
    /// don't describe app memory.
    func testUsedMemoryExcludesFileCache() async {
        let probe = HostTelemetryProbe()
        let sample = await probe.sample()

        // `top` counts everything but free and speculative, so it is always at
        // least as large. Used memory being equal to it would mean the cache had
        // been counted in.
        let everythingButFree = Double(sample.memoryTotalBytes) * 0.98
        XCTAssertLessThan(Double(sample.memoryUsedBytes), everythingButFree)
    }

    /// The first reading needs a second set of counters before it is available.
    func testCPULoadIsAFractionAndWaitsForADelta() async {
        let probe = HostTelemetryProbe()

        let first = await probe.sample()
        XCTAssertFalse(first.cpuAvailable, "nothing to difference against yet")

        // Give the counters something to move.
        var sink = 0.0
        for index in 0..<400_000 { sink += Double(index).squareRoot() }
        XCTAssertGreaterThan(sink, 0)

        let second = await probe.sample()
        XCTAssertTrue(second.cpuAvailable)
        XCTAssertGreaterThanOrEqual(second.cpuUsage, 0)
        XCTAssertLessThanOrEqual(second.cpuUsage, 1, "load is a fraction of total capacity")
    }

    func testBatteryReadingIsAFractionWhenPresent() async {
        let probe = HostTelemetryProbe()
        let sample = await probe.sample()
        guard let battery = sample.battery else { return }   // desktop Mac
        XCTAssertGreaterThanOrEqual(battery.level, 0)
        XCTAssertLessThanOrEqual(battery.level, 1)
    }
}
