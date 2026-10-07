import Foundation

/// Store deadlines instead of subtracting a second on each tick. Remaining time stays
/// correct after sleep or a delayed redraw.
public enum FocusTimerState: Equatable, Sendable {
    case idle
    /// Running, with the instant the session should end.
    case running(deadline: Date, total: TimeInterval)
    /// Paused, with the time left when it was paused.
    case paused(remaining: TimeInterval, total: TimeInterval)
    /// Elapsed, until acknowledged.
    case finished(total: TimeInterval)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isActive: Bool {
        switch self {
        case .idle: false
        case .running, .paused, .finished: true
        }
    }

    /// Seconds left, evaluated against `now`.
    public func remaining(at now: Date = .now) -> TimeInterval {
        switch self {
        case .idle: 0
        case .running(let deadline, _): max(0, deadline.timeIntervalSince(now))
        case .paused(let remaining, _): remaining
        case .finished: 0
        }
    }

    /// Fraction elapsed, 0...1, for the progress ring.
    public func progress(at now: Date = .now) -> Double {
        switch self {
        case .idle: return 0
        case .finished: return 1
        case .running(_, let total), .paused(_, let total):
            guard total > 0 else { return 0 }
            return ((total - remaining(at: now)) / total).clamped(to: 0...1)
        }
    }

    public var total: TimeInterval {
        switch self {
        case .idle: 0
        case .running(_, let total), .paused(_, let total), .finished(let total): total
        }
    }
}

/// Timer state changes with a supplied time, so tests can check pause and resume without
/// waiting.
public struct FocusTimer: Equatable, Sendable {
    public private(set) var state: FocusTimerState
    /// Configured session length in seconds.
    public var duration: TimeInterval

    public init(duration: TimeInterval = 25 * 60, state: FocusTimerState = .idle) {
        self.duration = duration
        self.state = state
    }

    public mutating func start(at now: Date = .now) {
        state = .running(deadline: now.addingTimeInterval(duration), total: duration)
    }

    public mutating func pause(at now: Date = .now) {
        guard case .running(let deadline, let total) = state else { return }
        state = .paused(remaining: max(0, deadline.timeIntervalSince(now)), total: total)
    }

    public mutating func resume(at now: Date = .now) {
        guard case .paused(let remaining, let total) = state else { return }
        // A timer paused at zero should finish on resume rather than restart.
        guard remaining > 0 else {
            state = .finished(total: total)
            return
        }
        state = .running(deadline: now.addingTimeInterval(remaining), total: total)
    }

    public mutating func reset() {
        state = .idle
    }

    /// Extends the countdown without losing time already spent or paused.
    public mutating func addTime(minutes: Int, at now: Date = .now) {
        let seconds = TimeInterval(minutes.clamped(to: 1...600) * 60)
        switch state {
        case .running(let deadline, let total):
            duration += seconds
            state = .running(deadline: max(now, deadline).addingTimeInterval(seconds), total: total + seconds)
        case .paused(let remaining, let total):
            duration += seconds
            state = .paused(remaining: remaining + seconds, total: total + seconds)
        case .idle, .finished:
            duration = seconds
            start(at: now)
        }
    }

    /// Toggles between running and paused; starts from idle or finished.
    public mutating func toggle(at now: Date = .now) {
        switch state {
        case .idle, .finished: start(at: now)
        case .running: pause(at: now)
        case .paused: resume(at: now)
        }
    }

    /// Return true once when the session finishes so the caller can raise one alert.
    @discardableResult
    public mutating func tick(at now: Date = .now) -> Bool {
        guard case .running(let deadline, let total) = state else { return false }
        guard now >= deadline else { return false }
        state = .finished(total: total)
        return true
    }

    /// Set the duration for the next session. Don't move an active timer's deadline here.
    public mutating func setDuration(minutes: Int) {
        duration = TimeInterval(minutes.clamped(to: 1...240) * 60)
        if case .idle = state { return }
        if case .finished = state { state = .idle }
    }
}
