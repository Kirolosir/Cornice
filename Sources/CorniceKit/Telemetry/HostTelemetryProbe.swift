import Foundation
import Darwin
import IOKit.ps

public protocol TelemetryProbing: Sendable {
    func sample() async -> TelemetrySample
}

/// Reads CPU, memory and battery state from the kernel.
///
/// Everything here is an in-process Mach or sysctl call. No subprocess, no
/// `top`, no `ioreg`: the whole point of a telemetry widget that runs every
/// couple of seconds is that sampling must cost almost nothing, and spawning a
/// process to read a number costs several milliseconds of CPU plus a process
/// launch. These calls are microseconds.
///
/// An actor because CPU and network figures are *rates*, computed by
/// differencing against the previous reading, so the probe carries state that
/// two concurrent samplers must not interleave on.
public actor HostTelemetryProbe: TelemetryProbing {

    /// Cumulative CPU tick counters from the previous sample.
    private var previousCPUTicks: (idle: UInt64, total: UInt64)?

    private let totalMemory: UInt64
    /// VM page size, read once. The global `vm_kernel_page_size` is a mutable
    /// C global and so is off-limits under strict concurrency; `host_page_size`
    /// is the supported call and the value never changes at runtime anyway.
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
        // Read once and reuse. Calling the reader twice for the used figure and
        // the fraction meant two kernel round-trips for one number, and for the
        // rate-based figures it meant the second call differenced against the
        // first call's own reading, over an interval of zero.
        let used = memoryUsed()
        return TelemetrySample(
            cpuUsage: cpuUsage(),
            memoryUsage: totalMemory > 0 ? Double(used) / Double(totalMemory) : 0,
            memoryUsedBytes: used,
            memoryTotalBytes: totalMemory,
            battery: Self.batteryState(),
            capturedAt: Date()
        )
    }

    // MARK: - CPU

    /// System-wide CPU load, as a fraction of total capacity.
    ///
    /// The kernel exposes cumulative tick counters per state, not a percentage,
    /// so usage is `1 - Δidle/Δtotal` between two readings. The first call has
    /// nothing to difference against and correctly reports 0 rather than a
    /// fabricated value.
    private func cpuUsage() -> Double {
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
            return 0
        }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let total = user + system + idle + nice

        defer { previousCPUTicks = (idle: idle, total: total) }
        guard let previous = previousCPUTicks else { return 0 }

        let totalDelta = total &- previous.total
        let idleDelta = idle &- previous.idle
        // Counters can appear to go backwards across a sleep/wake cycle.
        guard totalDelta > 0, idleDelta <= totalDelta else { return 0 }
        return 1 - Double(idleDelta) / Double(totalDelta)
    }

    // MARK: - Memory

    /// Bytes of physical memory in use, by Activity Monitor's definition.
    ///
    ///     Memory Used = App Memory + Wired + Compressed
    ///     App Memory  = internal pages − purgeable pages
    ///
    /// The page classes matter and are easy to get wrong. `active` is not App
    /// Memory: it includes file-backed pages the kernel is caching and excludes
    /// inactive pages an app still owns. Using it read about 250 MB light on
    /// this machine, and drifted differently depending on how much file cache
    /// happened to be warm.
    ///
    /// Counting inactive *file* pages instead — which is what `top` reports as
    /// "used" — goes the other way and makes every Mac look permanently near
    /// capacity, because macOS deliberately keeps that cache full and reclaims
    /// it on demand.
    private func memoryUsed() -> UInt64 {
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
            return 0
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
