import XCTest
@testable import CorniceKit

final class HUDTests: XCTestCase {

    /// The design's measured table. These are the numbers the whole HUD system
    /// is, so they are asserted rather than trusted: a wing is half the width
    /// past a 209 pt notch, and a drop is the height below the 38 pt band.
    func testEveryHUDMatchesTheMeasuredTable() {
        let expected: [HUDKind: (width: CGFloat, height: CGFloat, bottom: CGFloat, flare: CGFloat)] = [
            .noInternet: (604, 152, 28, 24),
            .filesReceived: (604, 196, 28, 24),
            .timerRunning: (480, 92, 24, 20),
            .charging: (425, 44, 14, 12),
            .batteryLow: (352, 126, 24, 20),
            .fullBattery: (352, 104, 24, 20),
            .vpn: (560, 92, 24, 20),
            .download: (560, 104, 24, 20),
            .doNotDisturb: (425, 42, 14, 12),
            .handoff: (300, 40, 13, 11),
        ]

        for kind in HUDKind.allCases {
            guard let want = expected[kind] else {
                XCTFail("no expectation for \(kind.rawValue)")
                continue
            }
            XCTAssertEqual(209 + kind.wing * 2, want.width, "\(kind.rawValue) width")
            XCTAssertEqual(38 + kind.drop, want.height, "\(kind.rawValue) height")
            XCTAssertEqual(kind.bottomRadius, want.bottom, "\(kind.rawValue) bottom radius")
            XCTAssertEqual(kind.flareRadius, want.flare, "\(kind.rawValue) flare")
        }
    }

    /// Anything no taller than the notch can only use the margins either side of
    /// the hole, so it must not claim a content row below the band.
    func testShortPillsClaimNoRowBelowTheBand() {
        for kind in HUDKind.allCases {
            let isShort = 38 + kind.drop <= 48
            XCTAssertEqual(kind.isShortPill, isShort, "\(kind.rawValue)")
            if isShort { XCTAssertEqual(kind.contentTop, 0, "\(kind.rawValue)") }
        }
    }

    /// A HUD that retracts on its own must not be one that needs an answer, and
    /// one that needs an answer must not retract out from under the pointer.
    func testOnlyInteractiveHUDsWaitToBeDismissed() {
        for kind in HUDKind.allCases {
            let waits = kind.dismissAfter == nil
            switch kind {
            case .noInternet, .filesReceived, .timerRunning:
                XCTAssertTrue(waits, "\(kind.rawValue) has buttons and must wait")
            default:
                XCTAssertFalse(waits, "\(kind.rawValue) is an announcement and must retract")
                XCTAssertGreaterThan(kind.dismissAfter ?? 0, 1, "\(kind.rawValue) too brief to read")
                XCTAssertLessThanOrEqual(kind.dismissAfter ?? 0, 6, "\(kind.rawValue) outstays its welcome")
            }
        }
    }

    func testContentReportsItsOwnKind() {
        XCTAssertEqual(HUDContent.noInternet.kind, .noInternet)
        XCTAssertEqual(HUDContent.charging(level: 0.5).kind, .charging)
        XCTAssertEqual(HUDContent.fullBattery.kind, .fullBattery)
        XCTAssertEqual(HUDContent.handoff.kind, .handoff)
    }

    /// An alert waiting on an answer outranks a passing announcement.
    func testAlertsOutrankAnnouncements() {
        for other in [HUDContent.charging(level: 0.8), .fullBattery, .doNotDisturb, .handoff, .vpn(name: "v", since: .now)] {
            XCTAssertGreaterThan(HUDContent.noInternet.priority, other.priority, "vs \(other.kind.rawValue)")
        }
    }

    func testInteractiveHUDsAreTheOnesWithSomethingToAnswer() {
        XCTAssertTrue(HUDContent.noInternet.isInteractive)
        XCTAssertTrue(HUDContent.timerRunning(id: UUID(), label: "x", isRunning: true, isFinished: false).isInteractive)
        XCTAssertFalse(HUDContent.charging(level: 0.3).isInteractive)
    }
}
