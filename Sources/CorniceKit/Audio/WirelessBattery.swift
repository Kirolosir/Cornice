import Foundation
import IOKit

/// Read wireless-device battery properties from the IO registry. If the device doesn't
/// expose them yet, return nil and omit the ring.
public enum WirelessBattery {

    /// Combined level across both buds and the case, 0...1, or `nil`.
    public static func level(forDeviceNamed name: String) -> Double? {
        let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            guard let product = property(service, "Product") as? String else { continue }
            // Match loosely: Core Audio's device name and the HID product name
            // are usually the same string but not guaranteed to be.
            guard product.caseInsensitiveCompare(name) == .orderedSame
                    || name.localizedCaseInsensitiveContains(product)
                    || product.localizedCaseInsensitiveContains(name)
            else { continue }

            if let combined = property(service, "BatteryPercentCombined") as? Int, combined > 0 {
                return Double(combined) / 100
            }
            // Some models report per-bud levels only.
            let left = property(service, "BatteryPercentLeft") as? Int ?? 0
            let right = property(service, "BatteryPercentRight") as? Int ?? 0
            let reported = [left, right].filter { $0 > 0 }
            if !reported.isEmpty {
                return Double(reported.reduce(0, +)) / Double(reported.count) / 100
            }
        }
        return nil
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
}
