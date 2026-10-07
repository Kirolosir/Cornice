import Foundation

/// One instant of machine telemetry.
///
/// Deliberately small. This is context you glance at while a build runs ("is
/// the machine pegged, is memory about to swap, is the network actually doing
/// anything") not a replacement for Activity Monitor. Anything requiring a
/// per-process table or historical storage is out of scope on purpose.
public struct TelemetrySample: Equatable, Sendable {
    /// Fraction of total CPU capacity in use across all cores, 0...1.
    public let cpuUsage: Double
    /// Fraction of physical memory in use, 0...1.
    public let memoryUsage: Double
    /// Bytes of physical memory in use, by the same definition Activity
    /// Monitor's "Memory Used" uses.
    public let memoryUsedBytes: UInt64
    public let memoryTotalBytes: UInt64
    public let battery: BatteryState?
    public let capturedAt: Date
    public let cpuAvailable: Bool
    public let memoryAvailable: Bool

    public init(
        cpuUsage: Double,
        memoryUsage: Double,
        memoryUsedBytes: UInt64,
        memoryTotalBytes: UInt64,
        battery: BatteryState?,
        capturedAt: Date,
        cpuAvailable: Bool = true,
        memoryAvailable: Bool = true
    ) {
        self.cpuUsage = cpuUsage
        self.memoryUsage = memoryUsage
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.battery = battery
        self.capturedAt = capturedAt
        self.cpuAvailable = cpuAvailable
        self.memoryAvailable = memoryAvailable
    }

    /// Before sampling, values are placeholders and both metrics are unavailable.
    public static let empty = TelemetrySample(
        cpuUsage: 0, memoryUsage: 0, memoryUsedBytes: 0, memoryTotalBytes: 0,
        battery: nil, capturedAt: .distantPast, cpuAvailable: false, memoryAvailable: false
    )
}

/// The kernel exposes four separate 32-bit counters. Difference each one
/// before adding them, so one wrapping counter cannot spoil the whole reading.
public struct CPUCounterReading: Sendable {
    public let user: UInt32
    public let system: UInt32
    public let idle: UInt32
    public let nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }

    public func usage(since previous: Self) -> Double? {
        let deltas = [user &- previous.user, system &- previous.system,
                      idle &- previous.idle, nice &- previous.nice]
        // A reset after waking looks like an implausibly large interval.
        guard deltas.allSatisfy({ $0 < UInt32.max / 2 }) else { return nil }
        let total = deltas.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard total > 0 else { return nil }
        return 1 - Double(deltas[2]) / Double(total)
    }
}

public struct BatteryState: Equatable, Sendable {
    /// Charge remaining, 0...1.
    public let level: Double
    public let isCharging: Bool
    public let isPluggedIn: Bool
    /// Minutes remaining, when the system is confident enough to estimate.
    /// `nil` right after plugging or unplugging, while it recalculates.
    public let minutesRemaining: Int?

    public init(level: Double, isCharging: Bool, isPluggedIn: Bool, minutesRemaining: Int?) {
        self.level = level
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.minutesRemaining = minutesRemaining
    }
}

/// The one edge that should raise a low-battery warning.
public enum BatteryAlertPolicy {
    public static let lowLevel = 0.10

    public static func shouldWarn(previous: BatteryState?, current: BatteryState) -> Bool {
        guard !current.isCharging, current.level <= lowLevel else { return false }
        guard let previous else { return true }
        return previous.isCharging || previous.level > lowLevel
    }
}

/// A bounded ring of recent samples, for the sparklines.
///
/// Fixed capacity so a session left running for days cannot grow this without
/// bound. The panel only ever draws the last `capacity` points anyway.
public struct TelemetryHistory: Equatable, Sendable {
    public private(set) var samples: [TelemetrySample] = []
    public let capacity: Int

    public init(capacity: Int = 60) {
        self.capacity = max(1, capacity)
        samples.reserveCapacity(self.capacity)
    }

    public mutating func append(_ sample: TelemetrySample) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    public mutating func clear() { samples.removeAll(keepingCapacity: true) }

    public var latest: TelemetrySample? { samples.last }

    /// Normalised 0...1 series for a metric, ready to feed a sparkline.
    public func series(_ metric: (TelemetrySample) -> Double) -> [Double] {
        samples.map(metric)
    }
}
