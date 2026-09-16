import Foundation

/// Caches GitHub responses and their `ETag`s.
///
/// This is the single most valuable thing in the networking layer. GitHub
/// supports conditional requests: send back the `ETag` from the last response
/// as `If-None-Match`, and if nothing changed the server replies `304 Not
/// Modified` with an empty body — **and does not decrement the rate limit**.
/// Since a developer's open pull requests change far less often than the panel
/// refreshes, the overwhelming majority of refreshes cost no quota at all.
///
/// The freshness window is a second, cheaper layer: within it, a repeated
/// request is answered from memory with no network round-trip whatsoever. That
/// is what stops opening and closing the panel repeatedly from issuing a
/// request each time.
public actor ResponseCache {

    struct Entry: Sendable {
        let etag: String?
        let payload: Data
        let storedAt: Date
        let rateLimit: RateLimitSnapshot?
    }

    /// How long a cached body is served without even a conditional request.
    private let freshnessWindow: TimeInterval
    /// Bound on entries; the app queries a handful of endpoints, so this is
    /// only a guard against a pathological number of watched repositories.
    private let capacity: Int
    private var entries: [String: Entry] = [:]

    /// Counters for the effectiveness figures quoted in the README. Measured,
    /// not estimated.
    public private(set) var hits = 0
    public private(set) var conditionalHits = 0
    public private(set) var misses = 0

    public init(freshnessWindow: TimeInterval = 45, capacity: Int = 64) {
        self.freshnessWindow = freshnessWindow
        self.capacity = capacity
    }

    /// A body still inside the freshness window, if any.
    func fresh(for key: String, now: Date = .now) -> Data? {
        guard let entry = entries[key],
              now.timeIntervalSince(entry.storedAt) < freshnessWindow
        else { return nil }
        hits += 1
        return entry.payload
    }

    /// The `ETag` to send as `If-None-Match`, if we have one.
    func etag(for key: String) -> String? {
        entries[key]?.etag
    }

    /// The stored body, regardless of age. Used to answer a `304`, and to serve
    /// stale data when the network is unavailable.
    func stored(for key: String) -> Data? {
        entries[key]?.payload
    }

    func store(_ payload: Data, etag: String?, rateLimit: RateLimitSnapshot?, for key: String) {
        if entries.count >= capacity, entries[key] == nil {
            // Evict the oldest. A strict LRU would need access bookkeeping that
            // is not worth it at this size.
            if let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
                entries.removeValue(forKey: oldest)
            }
        }
        entries[key] = Entry(etag: etag, payload: payload, storedAt: .now, rateLimit: rateLimit)
        misses += 1
    }

    /// Refreshes an entry's timestamp after a `304`, so the freshness window
    /// restarts and we do not immediately re-issue a conditional request.
    func touch(_ key: String) {
        guard let entry = entries[key] else { return }
        entries[key] = Entry(
            etag: entry.etag,
            payload: entry.payload,
            storedAt: .now,
            rateLimit: entry.rateLimit
        )
        conditionalHits += 1
    }

    public func removeAll() {
        entries.removeAll()
    }

    /// Requests served without spending quota, as a fraction of all requests.
    public var savedFraction: Double {
        let total = hits + conditionalHits + misses
        guard total > 0 else { return 0 }
        return Double(hits + conditionalHits) / Double(total)
    }

    public func statistics() -> (hits: Int, conditionalHits: Int, misses: Int, savedFraction: Double) {
        (hits, conditionalHits, misses, savedFraction)
    }
}
