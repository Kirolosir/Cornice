import Foundation

/// Watch the player's own position, not the locally animated playhead.
public struct PlaybackFreshness: Sendable {
    public private(set) var isStale = false
    private var identity: String?
    private var position: TimeInterval?
    private var lastProgressAt: Date?
    private var lastRecoveryAt: Date?

    public init() {}

    public mutating func needsRecovery(_ snapshot: MediaSnapshot, at now: Date = .now,
                                       threshold: TimeInterval = 12) -> Bool {
        guard snapshot.state.isPlaying, snapshot.duration > 0,
              snapshot.position < snapshot.duration - 1 else {
            identity = nil; position = nil; lastProgressAt = nil; isStale = false
            return false
        }
        if identity != snapshot.trackIdentity || position.map({ abs($0 - snapshot.position) > 0.05 }) != false {
            identity = snapshot.trackIdentity
            position = snapshot.position
            lastProgressAt = now
            isStale = false
            return false
        }
        isStale = lastProgressAt.map { now.timeIntervalSince($0) >= threshold } ?? false
        guard isStale, lastRecoveryAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true else { return false }
        lastRecoveryAt = now
        return true
    }
}

public struct MediaConnectionHealth: Equatable, Sendable {
    public var lastSuccess: Date?
    public var lastAttempt: Date?
    public var failures = 0
    public var recoveries = 0
    public var permissionDenied = false
    public var lastRecovery: Date?
    public init() {}

    public func shouldRecover(at now: Date) -> Bool {
        !permissionDenied && failures >= 3 && (lastRecovery.map { now.timeIntervalSince($0) >= 15 } ?? true)
    }
}
