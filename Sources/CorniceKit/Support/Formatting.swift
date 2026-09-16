import Foundation

/// Formatting helpers shared by the UI and by tests.
///
/// These live in the kit rather than in views so their edge cases (zero,
/// negative, absurdly large) are unit-testable without a running app.
public enum Format {
    /// Compact byte-rate string, e.g. `1.4 MB/s`. Always two significant-ish
    /// digits so the value does not jitter in width while it updates.
    public static func rate(bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        let units = ["B", "KB", "MB", "GB"]
        var scaled = value
        var index = 0
        while scaled >= 1000, index < units.count - 1 {
            scaled /= 1024
            index += 1
        }
        let digits = scaled < 10 && index > 0 ? 1 : 0
        return String(format: "%.\(digits)f %@/s", scaled, units[index])
    }

    /// Compact byte string, e.g. `12.4 GB`.
    public static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var scaled = Double(value)
        var index = 0
        while scaled >= 1024, index < units.count - 1 {
            scaled /= 1024
            index += 1
        }
        let digits = scaled < 10 && index > 0 ? 1 : 0
        return String(format: "%.\(digits)f %@", scaled, units[index])
    }

    /// `mm:ss`, or `h:mm:ss` past an hour. Used by the focus timer.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Process uptime. Switches to days past 24 hours, because a server that
    /// has been up for three days reads as `3d 6h`, not as `78:12:55`.
    public static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        if total < 3600 { return "\(total / 60)m" }
        if total < 86_400 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        return "\(total / 86_400)d \((total % 86_400) / 3600)h"
    }

    /// Terse elapsed time for list rows: `now`, `4m`, `3h`, `2d`, `6w`.
    public static func relative(since date: Date, now: Date = .now) -> String {
        let interval = now.timeIntervalSince(date)
        guard interval >= 0 else { return "soon" }
        switch interval {
        case ..<45: return "now"
        case ..<3600: return "\(Int(interval / 60))m"
        case ..<86_400: return "\(Int(interval / 3600))h"
        case ..<604_800: return "\(Int(interval / 86_400))d"
        default: return "\(Int(interval / 604_800))w"
        }
    }

    /// Wall-clock duration of a finished job, e.g. `1m 12s`, `840ms`.
    public static func elapsed(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int(seconds * 1000))ms" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        return "\(minutes)m \(rest)s"
    }
}
