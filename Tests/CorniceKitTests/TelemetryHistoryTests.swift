import XCTest
@testable import CorniceKit

final class TelemetryHistoryTests: XCTestCase {

    private func sample(down: Double, up: Double) -> TelemetrySample {
        TelemetrySample(
            cpuUsage: 0.1,
            memoryUsage: 0.5,
            memoryUsedBytes: 8_000_000_000,
            memoryTotalBytes: 16_000_000_000,
            networkInBytesPerSecond: down,
            networkOutBytesPerSecond: up,
            battery: nil,
            capturedAt: .now
        )
    }

    /// The two directions share one chart, so they have to share one ceiling.
    /// Scaling each against its own peak is what makes a 60 KB/s upload draw as
    /// tall as a 6 MB/s download — worse than not charting it at all.
    func testNetworkDirectionsShareOneScale() {
        var history = TelemetryHistory(capacity: 48)
        history.append(sample(down: 1_000_000, up: 100_000))
        history.append(sample(down: 500_000, up: 50_000))

        let pair = history.normalisedNetworkPair()

        XCTAssertEqual(pair.down[0], 1.0, accuracy: 0.0001)
        XCTAssertEqual(pair.up[0], 0.1, accuracy: 0.0001)
        XCTAssertEqual(pair.down[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(pair.up[1], 0.05, accuracy: 0.0001)
    }

    /// An idle machine reports zero in both directions, and dividing by that
    /// peak would put NaN into a chart path.
    func testSilentNetworkNormalisesToZeroRatherThanNaN() {
        var history = TelemetryHistory(capacity: 48)
        history.append(sample(down: 0, up: 0))

        let pair = history.normalisedNetworkPair()

        XCTAssertEqual(pair.down, [0])
        XCTAssertEqual(pair.up, [0])
    }

    /// The window is bounded, so a session left running for days cannot grow it.
    func testHistoryIsBoundedByCapacity() {
        var history = TelemetryHistory(capacity: 4)
        for index in 0..<10 { history.append(sample(down: Double(index), up: 0)) }

        XCTAssertEqual(history.samples.count, 4)
        XCTAssertEqual(history.latest?.networkInBytesPerSecond, 9)
    }
}
