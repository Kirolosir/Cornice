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

/// Each timer keeps its own deadline. The UI reads remaining time from the clock instead of
/// decrementing counters.
public struct TimerBoard: Equatable, Sendable {

    /// Limit the number of timers so their rows fit in the panel.
    public static let maximumTimers = 4

    public private(set) var entries: [TimerEntry] = []

    public init(entries: [TimerEntry] = []) {
        self.entries = Array(entries.prefix(Self.maximumTimers))
    }

    public var hasTimers: Bool { !entries.isEmpty }

    /// Find the running timer nearest its deadline, using the caller's time so the result
    /// matches the rest of the frame.
    public func soonest(at now: Date = .now) -> TimerEntry? {
        entries
            .filter(\.isRunning)
            .min { $0.remaining(at: now) < $1.remaining(at: now) }
    }

    public var anyRunning: Bool { entries.contains(where: \.isRunning) }

    /// Start a new countdown immediately when the user adds it.
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

    /// Presets add to the current countdown. A finished timer starts fresh.
    @discardableResult
    public mutating func addTime(minutes: Int, at now: Date = .now) -> UUID? {
        guard let index = entries.firstIndex(where: { !$0.isFinished }) ?? entries.indices.first else {
            return add(minutes: minutes, at: now)
        }
        let oldLabel = "\(Int(entries[index].timer.duration / 60)) min"
        entries[index].timer.addTime(minutes: minutes, at: now)
        if entries[index].label == oldLabel {
            entries[index].label = "\(Int(entries[index].timer.duration / 60)) min"
        }
        return entries[index].id
    }

    /// Repeated clicks on Repeat must not pause the newly started countdown.
    public mutating func repeatTimer(_ id: UUID, at now: Date = .now) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isFinished else { return }
        entries[index].timer.start(at: now)
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
