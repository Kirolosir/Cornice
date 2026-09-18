import XCTest
@testable import CorniceKit

final class TelemetryHistoryTests: XCTestCase {

    private func sample(cpu: Double) -> TelemetrySample {
        TelemetrySample(
            cpuUsage: cpu,
            memoryUsage: 0.5,
            memoryUsedBytes: 8_000_000_000,
            memoryTotalBytes: 16_000_000_000,
            battery: nil,
            capturedAt: .now
        )
    }

    /// The window is bounded, so a session left running for days cannot grow it.
    func testHistoryIsBoundedByCapacity() {
        var history = TelemetryHistory(capacity: 4)
        for index in 0..<10 { history.append(sample(cpu: Double(index) / 10)) }

        XCTAssertEqual(history.samples.count, 4)
        XCTAssertEqual(history.latest?.cpuUsage ?? 0, 0.9, accuracy: 0.0001)
    }
}
