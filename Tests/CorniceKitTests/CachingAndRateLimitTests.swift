import XCTest
@testable import CorniceKit

final class RateLimitTests: XCTestCase {

    /// URLSession does not normalise header casing consistently across macOS
    /// releases, and HTTP header names are case-insensitive by spec.
    func testParsesHeadersRegardlessOfCase() {
        let snapshot = RateLimitSnapshot.parse(headers: [
            "X-RateLimit-Limit": "5000",
            "x-ratelimit-remaining": "4321",
            "X-Ratelimit-Reset": "1800000000",
        ])

        XCTAssertEqual(snapshot?.limit, 5000)
        XCTAssertEqual(snapshot?.remaining, 4321)
        XCTAssertEqual(snapshot?.resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(snapshot?.usedFraction ?? 0, 0.1358, accuracy: 0.001)
    }

    func testReturnsNilWhenHeadersAbsent() {
        XCTAssertNil(RateLimitSnapshot.parse(headers: [:]))
        XCTAssertNil(RateLimitSnapshot.parse(headers: ["x-ratelimit-limit": "5000"]),
                     "a partial set is not usable")
    }

    /// The reserve is the whole point of the gate: background refreshes stop
    /// early so an explicit user action still has quota to spend.
    func testReserveIsHeldForUserInitiatedRequests() {
        let reset = Date().addingTimeInterval(600)
        let gate = RateLimitGate(snapshot: .init(limit: 5000, remaining: 20, resetsAt: reset))

        XCTAssertEqual(gate.decide(userInitiated: false), .deny(until: reset))
        XCTAssertEqual(gate.decide(userInitiated: true), .allow)
    }

    func testExhaustedQuotaDeniesEveryone() {
        let reset = Date().addingTimeInterval(600)
        let gate = RateLimitGate(snapshot: .init(limit: 5000, remaining: 0, resetsAt: reset))

        XCTAssertEqual(gate.decide(userInitiated: true), .deny(until: reset))
    }

    /// Once the window has rolled over, the stale snapshot must not keep
    /// blocking requests.
    func testExpiredWindowAllowsAgain() {
        let gate = RateLimitGate(snapshot: .init(
            limit: 5000, remaining: 0, resetsAt: Date().addingTimeInterval(-10)
        ))

        XCTAssertEqual(gate.decide(userInitiated: false), .allow)
    }

    func testNoSnapshotAllows() {
        XCTAssertEqual(RateLimitGate().decide(userInitiated: false), .allow)
    }
}

final class ResponseCacheTests: XCTestCase {

    func testFreshEntryIsServedWithoutNetwork() async {
        let cache = ResponseCache(freshnessWindow: 60)
        await cache.store(Data("payload".utf8), etag: "\"abc\"", rateLimit: nil, for: "key")

        let fresh = await cache.fresh(for: "key")

        XCTAssertEqual(fresh, Data("payload".utf8))
    }

    func testEntryOutsideFreshnessWindowIsNotServedDirectly() async {
        let cache = ResponseCache(freshnessWindow: 60)
        await cache.store(Data("payload".utf8), etag: "\"abc\"", rateLimit: nil, for: "key")

        let stale = await cache.fresh(for: "key", now: Date().addingTimeInterval(120))

        XCTAssertNil(stale, "past the window it must be revalidated, not reused blindly")
        let stored = await cache.stored(for: "key")
        XCTAssertNotNil(stored, "but the body is kept for a 304 and for offline use")
        let etag = await cache.etag(for: "key")
        XCTAssertEqual(etag, "\"abc\"")
    }

    /// A 304 restarts the freshness window, so a burst of refreshes does not
    /// issue a conditional request every single time.
    func testTouchRestartsFreshnessWindow() async {
        let cache = ResponseCache(freshnessWindow: 60)
        await cache.store(Data("payload".utf8), etag: "\"abc\"", rateLimit: nil, for: "key")
        _ = await cache.fresh(for: "key", now: Date().addingTimeInterval(120))

        await cache.touch("key")

        XCTAssertNotNil(await cache.fresh(for: "key"))
        let stats = await cache.statistics()
        XCTAssertEqual(stats.conditionalHits, 1)
    }

    func testCapacityEvictsOldestEntry() async {
        let cache = ResponseCache(freshnessWindow: 60, capacity: 2)

        await cache.store(Data("1".utf8), etag: nil, rateLimit: nil, for: "a")
        try? await Task.sleep(for: .milliseconds(10))
        await cache.store(Data("2".utf8), etag: nil, rateLimit: nil, for: "b")
        try? await Task.sleep(for: .milliseconds(10))
        await cache.store(Data("3".utf8), etag: nil, rateLimit: nil, for: "c")

        XCTAssertNil(await cache.stored(for: "a"), "oldest evicted")
        XCTAssertNotNil(await cache.stored(for: "c"))
    }

    func testStatisticsTrackSavedFraction() async {
        let cache = ResponseCache(freshnessWindow: 60)

        await cache.store(Data("p".utf8), etag: nil, rateLimit: nil, for: "k")  // miss
        _ = await cache.fresh(for: "k")                                          // hit
        _ = await cache.fresh(for: "k")                                          // hit
        _ = await cache.fresh(for: "k")                                          // hit

        let stats = await cache.statistics()
        XCTAssertEqual(stats.misses, 1)
        XCTAssertEqual(stats.hits, 3)
        XCTAssertEqual(stats.savedFraction, 0.75, accuracy: 0.001)
    }

    func testEmptyCacheReportsZeroSaved() async {
        let stats = await ResponseCache().statistics()

        XCTAssertEqual(stats.savedFraction, 0, "no division by zero on a cold cache")
    }

    func testRemoveAllClearsEntries() async {
        let cache = ResponseCache()
        await cache.store(Data("p".utf8), etag: nil, rateLimit: nil, for: "k")

        await cache.removeAll()

        XCTAssertNil(await cache.stored(for: "k"))
    }
}
