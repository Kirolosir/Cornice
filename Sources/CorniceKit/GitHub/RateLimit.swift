import Foundation

/// GitHub's view of how much quota is left, read from response headers.
public struct RateLimitSnapshot: Equatable, Sendable {
    public let limit: Int
    public let remaining: Int
    public let resetsAt: Date
    public let observedAt: Date

    public init(limit: Int, remaining: Int, resetsAt: Date, observedAt: Date = .now) {
        self.limit = limit
        self.remaining = remaining
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }

    public var isExhausted: Bool { remaining <= 0 && resetsAt > .now }

    public var usedFraction: Double {
        guard limit > 0 else { return 0 }
        return Double(limit - remaining) / Double(limit)
    }

    /// Parses the `x-ratelimit-*` headers. Returns `nil` when they are absent,
    /// which happens on network-level failures and on endpoints that do not
    /// meter (and for responses served from the local cache).
    public static func parse(headers: [AnyHashable: Any], now: Date = .now) -> RateLimitSnapshot? {
        func value(_ name: String) -> String? {
            // HTTP header names are case-insensitive, and URLSession does not
            // normalise them consistently across macOS versions.
            for (key, value) in headers {
                if let key = key as? String, key.lowercased() == name {
                    return value as? String
                }
            }
            return nil
        }
        guard let limit = value("x-ratelimit-limit").flatMap(Int.init),
              let remaining = value("x-ratelimit-remaining").flatMap(Int.init),
              let reset = value("x-ratelimit-reset").flatMap(Double.init)
        else { return nil }
        return RateLimitSnapshot(
            limit: limit,
            remaining: remaining,
            resetsAt: Date(timeIntervalSince1970: reset),
            observedAt: now
        )
    }
}

/// Decides whether a request may be sent.
///
/// Two protections, because GitHub enforces two different limits:
///
/// 1. **Primary quota.** 5,000 requests/hour when authenticated. Once the
///    headers say zero remaining, requests are refused locally until the reset
///    time rather than being sent to be rejected — sending them would achieve
///    nothing and, on the secondary limiter, actively make things worse.
///
/// 2. **A local reserve.** Requests stop at a small remaining threshold rather
///    than at zero, so an interactive action the user explicitly asked for
///    still has quota even after background refreshes have been running all
///    day. Background refreshes yield; user-initiated ones spend the reserve.
public struct RateLimitGate: Sendable {
    /// Quota held back for user-initiated requests.
    public static let reserve = 50

    public enum Decision: Equatable, Sendable {
        case allow
        case deny(until: Date)
    }

    public var snapshot: RateLimitSnapshot?

    public init(snapshot: RateLimitSnapshot? = nil) {
        self.snapshot = snapshot
    }

    /// - Parameter userInitiated: `true` for an explicit refresh, `false` for a
    ///   background tick. Only the latter respects the reserve.
    public func decide(userInitiated: Bool, now: Date = .now) -> Decision {
        guard let snapshot else { return .allow }
        guard snapshot.resetsAt > now else { return .allow }
        let floor = userInitiated ? 0 : Self.reserve
        return snapshot.remaining > floor ? .allow : .deny(until: snapshot.resetsAt)
    }
}
