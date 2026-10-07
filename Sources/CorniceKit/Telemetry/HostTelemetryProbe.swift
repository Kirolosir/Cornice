import Foundation
import Darwin
import IOKit.ps

public protocol TelemetryProbing: Sendable {
    func sample() async -> TelemetrySample
}

/// Read CPU, memory and battery with system APIs. Keep previous CPU counters in this actor
/// so concurrent samples can't mix them up.
public actor HostTelemetryProbe: TelemetryProbing {

    /// Cumulative CPU tick counters from the previous sample.
    private var previousCPUTicks: CPUCounterReading?

    private let totalMemory: UInt64
    /// Read the page size once through host_page_size. The mutable C global cannot be used
    /// under strict concurrency.
    private let pageSize: UInt64

    public init() {
        var size = MemoryLayout<UInt64>.size
        var bytes: UInt64 = 0
        sysctlbyname("hw.memsize", &bytes, &size, nil, 0)
        totalMemory = bytes

        var page: vm_size_t = 0
        pageSize = host_page_size(mach_host_self(), &page) == KERN_SUCCESS ? UInt64(page) : 4096
    }

    public func sample() async -> TelemetrySample {
        // Reuse one memory reading for both the byte count and percentage.
        let used = memoryUsed()
        let cpu = cpuUsage()
        return TelemetrySample(
            cpuUsage: cpu ?? 0,
            memoryUsage: totalMemory > 0 ? Double(used ?? 0) / Double(totalMemory) : 0,
            memoryUsedBytes: used ?? 0,
            memoryTotalBytes: totalMemory,
            battery: Self.batteryState(),
            capturedAt: Date(),
            cpuAvailable: cpu != nil,
            memoryAvailable: used != nil && totalMemory > 0
        )
    }

    // MARK: - CPU

    /// CPU usage is 1 - Δidle/Δtotal across two readings. The first sample needs a second
    /// set of counters before it can show a load.
    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            Log.telemetry.error("host_statistics(HOST_CPU_LOAD_INFO) failed: \(status)")
            previousCPUTicks = nil
            return nil
        }

        let current = CPUCounterReading(user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                                        idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { previousCPUTicks = current }
        guard let previous = previousCPUTicks else { return nil }
        return current.usage(since: previous)
    }

    // MARK: - Memory

    /// Follow Activity Monitor's memory categories, excluding reclaimable file cache.
    ///
    /// Memory Used = App Memory + Wired + Compressed
    /// App Memory = internal pages - purgeable pages
    private func memoryUsed() -> UInt64? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            Log.telemetry.error("host_statistics64(HOST_VM_INFO64) failed: \(status)")
            return nil
        }
        let appMemory = UInt64(stats.internal_page_count)
            .subtractingReportingOverflow(UInt64(stats.purgeable_count))
        let wired = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)
        return ((appMemory.overflow ? 0 : appMemory.partialValue) + wired + compressed) * pageSize
    }

    // MARK: - Battery

    /// Battery state via IOKit power sources, or `nil` on a desktop Mac.
    static func batteryState() -> BatteryState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let powerSource = description[kIOPSPowerSourceStateKey] as? String
            let isPluggedIn = powerSource == kIOPSACPowerValue

            // IOKit reports -1 while it is still working out an estimate,
            // typically for a minute or two after the power source changes.
            let rawMinutes = description[kIOPSTimeToEmptyKey] as? Int ?? -1
            let chargeMinutes = description[kIOPSTimeToFullChargeKey] as? Int ?? -1
            let minutes = isCharging ? chargeMinutes : rawMinutes

            return BatteryState(
                level: maximum > 0 ? Double(current) / Double(maximum) : 0,
                isCharging: isCharging,
                isPluggedIn: isPluggedIn,
                minutesRemaining: minutes > 0 ? minutes : nil
            )
        }
        return nil
    }
}
