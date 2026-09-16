import Foundation
import Darwin
import IOKit.ps

public protocol TelemetryProbing: Sendable {
    func sample() async -> TelemetrySample
}

/// Reads CPU, memory, network, and battery state from the kernel.
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
    /// Cumulative interface byte counters plus when they were read.
    private var previousNetwork: (inBytes: UInt64, outBytes: UInt64, at: Date)?

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
        let now = Date()
        return TelemetrySample(
            cpuUsage: cpuUsage(),
            memoryUsage: totalMemory > 0 ? Double(memoryUsed()) / Double(totalMemory) : 0,
            memoryUsedBytes: memoryUsed(),
            memoryTotalBytes: totalMemory,
            networkInBytesPerSecond: networkRates(at: now).inRate,
            networkOutBytesPerSecond: networkRates(at: now).outRate,
            battery: Self.batteryState(),
            capturedAt: now
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

    /// Bytes of physical memory in use.
    ///
    /// Defined as active + wired + compressed, which is how Activity Monitor
    /// computes "Memory Used". Inactive pages are excluded because macOS keeps
    /// them populated as a cache and reclaims them on demand — counting them
    /// would make every Mac look permanently near capacity, which is exactly
    /// the misleading reading people complain about in other monitors.
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
        let active = UInt64(stats.active_count)
        let wired = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)
        return (active + wired + compressed) * pageSize
    }

    // MARK: - Network

    /// Throughput since the previous sample, in bytes per second.
    ///
    /// Sums `if_data` counters for every link-layer interface except loopback —
    /// loopback carries local dev-server traffic, and counting it would make a
    /// local API call look like network activity.
    private func networkRates(at now: Date) -> (inRate: Double, outRate: Double) {
        var totals: (inBytes: UInt64, outBytes: UInt64) = (0, 0)
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0) }
        defer { freeifaddrs(addresses) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard !name.hasPrefix("lo") else { continue }
            guard let raw = entry.pointee.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            totals.inBytes += UInt64(data.ifi_ibytes)
            totals.outBytes += UInt64(data.ifi_obytes)
        }

        defer { previousNetwork = (totals.inBytes, totals.outBytes, now) }
        guard let previous = previousNetwork else { return (0, 0) }
        let interval = now.timeIntervalSince(previous.at)
        guard interval > 0.01 else { return (0, 0) }

        // Counters are 32-bit in the kernel struct and wrap. A wrap shows up as
        // a decrease; report zero for that interval rather than a huge spike.
        let inDelta = totals.inBytes >= previous.inBytes ? totals.inBytes - previous.inBytes : 0
        let outDelta = totals.outBytes >= previous.outBytes ? totals.outBytes - previous.outBytes : 0
        return (Double(inDelta) / interval, Double(outDelta) / interval)
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
