import Foundation
import CorniceKit

func battery(_ level: Double, charging: Bool = false) -> BatteryState {
    BatteryState(
        level: level,
        isCharging: charging,
        isPluggedIn: charging,
        minutesRemaining: nil
    )
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    print("PASS: \(message)")
}

check(
    BatteryAlertPolicy.shouldWarn(previous: battery(0.11), current: battery(0.10)),
    "crossing 10 percent warns"
)
check(
    BatteryAlertPolicy.shouldWarn(previous: battery(0.11), current: battery(0.09)),
    "a skipped poll still warns below 10 percent"
)
check(
    BatteryAlertPolicy.shouldWarn(previous: nil, current: battery(0.10)),
    "launching at 10 percent warns"
)
check(
    !BatteryAlertPolicy.shouldWarn(previous: battery(0.10), current: battery(0.09)),
    "remaining below 10 percent does not repeat"
)
check(
    !BatteryAlertPolicy.shouldWarn(previous: battery(0.11), current: battery(0.10, charging: true)),
    "charging does not warn"
)
check(
    !BatteryAlertPolicy.shouldWarn(previous: battery(0.12), current: battery(0.11)),
    "11 percent does not warn"
)
print("Battery checks passed")
