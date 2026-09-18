import Foundation

/// One countdown.
public struct TimerEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var label: String
    public var timer: FocusTimer

    public init(id: UUID = UUID(), label: String, minutes: Int) {
        self.id = id
        self.label = label
        self.timer = FocusTimer(duration: TimeInterval(minutes.clamped(to: 1...600) * 60))
    }

    public func remaining(at now: Date = .now) -> TimeInterval { timer.state.remaining(at: now) }
    public func progress(at now: Date = .now) -> Double { timer.state.progress(at: now) }
    public var isRunning: Bool { timer.state.isRunning }
    public var isFinished: Bool {
        if case .finished = timer.state { return true }
        return false
    }
}

/// A small collection of concurrent countdowns.
///
/// Each entry is an independent `FocusTimer`, so every one of them inherits the
/// deadline-based model: remaining time is derived from the wall clock rather
/// than decremented on a tick. Four timers running at once therefore cost
/// exactly as much as zero timers. The UI repaints, but nothing is being
/// counted down by anybody.
public struct TimerBoard: Equatable, Sendable {

    /// Cap on concurrent timers. The panel shows them as rows in a fixed-height
    /// pane, and past this they stop being glanceable, which is the only reason
    /// to put a timer in the notch in the first place.
    public static let maximumTimers = 4

    public private(set) var entries: [TimerEntry] = []

    public init(entries: [TimerEntry] = []) {
        self.entries = Array(entries.prefix(Self.maximumTimers))
    }

    public var hasTimers: Bool { !entries.isEmpty }

    /// The running timer closest to finishing. What the collapsed surface shows.
    ///
    /// Takes the reference time rather than reading the clock, like every other
    /// time-dependent call here. Reading `.now` internally made the result
    /// untestable and, worse, inconsistent with a caller that had already
    /// decided which instant it was rendering.
    public func soonest(at now: Date = .now) -> TimerEntry? {
        entries
            .filter(\.isRunning)
            .min { $0.remaining(at: now) < $1.remaining(at: now) }
    }

    public var anyRunning: Bool { entries.contains(where: \.isRunning) }

    /// Adds a timer and starts it immediately.
    ///
    /// Started on creation because every path that adds one is the user asking
    /// for a countdown now; making them press play afterwards would be a second
    /// step with no decision in it.
    @discardableResult
    public mutating func add(minutes: Int, label: String? = nil, at now: Date = .now) -> UUID? {
        guard entries.count < Self.maximumTimers else { return nil }
        var entry = TimerEntry(label: label ?? "\(minutes) min", minutes: minutes)
        entry.timer.start(at: now)
        entries.append(entry)
        return entry.id
    }

    public mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    public mutating func toggle(_ id: UUID, at now: Date = .now) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].timer.toggle(at: now)
    }

    /// Advances every timer. Returns the entries that completed on this tick,
    /// so the caller can notify once per completion rather than repeatedly.
    @discardableResult
    public mutating func tick(at now: Date = .now) -> [TimerEntry] {
        var completed: [TimerEntry] = []
        for index in entries.indices {
            if entries[index].timer.tick(at: now) {
                completed.append(entries[index])
            }
        }
        return completed
    }

    /// Drops timers the user has acknowledged by letting them finish.
    public mutating func clearFinished() {
        entries.removeAll(where: \.isFinished)
    }
}
