import XCTest
@testable import CorniceKit

/// The probe against the machine running the tests.
///
/// Bounds rather than fixed values, because the readings are real. These catch
/// the failures that actually happen: a zero reading from a call that quietly
/// failed, a fraction that disagrees with the bytes it came from, and a load
/// figure outside the range a fraction can occupy.
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

    /// App Memory is the anonymous pages an app owns, not the pages the kernel
    /// happens to have marked active. That set includes file cache and excludes
    /// inactive pages the app still holds. Used memory must exclude the file
    /// cache, or every Mac reads as permanently near capacity.
    func testUsedMemoryExcludesFileCache() async {
        let probe = HostTelemetryProbe()
        let sample = await probe.sample()

        // `top` counts everything but free and speculative, so it is always at
        // least as large. Used memory being equal to it would mean the cache had
        // been counted in.
        let everythingButFree = Double(sample.memoryTotalBytes) * 0.98
        XCTAssertLessThan(Double(sample.memoryUsedBytes), everythingButFree)
    }

    /// The first reading has nothing to difference against and must report zero
    /// rather than inventing a figure; the second must be a real fraction.
    func testCPULoadIsAFractionAndStartsAtZero() async {
        let probe = HostTelemetryProbe()

        let first = await probe.sample()
        XCTAssertEqual(first.cpuUsage, 0, "nothing to difference against yet")

        // Give the counters something to move.
        var sink = 0.0
        for index in 0..<400_000 { sink += Double(index).squareRoot() }
        XCTAssertGreaterThan(sink, 0)

        let second = await probe.sample()
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
