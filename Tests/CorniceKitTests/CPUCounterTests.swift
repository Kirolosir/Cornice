import XCTest
@testable import CorniceKit

final class CPUCounterTests: XCTestCase {
    func testIndividualCounterRollover() {
        let previous = CPUCounterReading(user: UInt32.max - 14, system: 50, idle: 200, nice: 10)
        let current = CPUCounterReading(user: 5, system: 60, idle: 270, nice: 10)
        XCTAssertEqual(current.usage(since: previous)!, 0.3, accuracy: 0.00001)
    }

    func testCounterResetAndEmptyIntervalAreUnavailable() {
        let previous = CPUCounterReading(user: 120, system: 60, idle: 270, nice: 10)
        let current = CPUCounterReading(user: 100, system: 50, idle: 200, nice: 10)
        XCTAssertNil(current.usage(since: previous))
        XCTAssertNil(current.usage(since: current))
    }
}
