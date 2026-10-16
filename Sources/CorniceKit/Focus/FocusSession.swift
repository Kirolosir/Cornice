import Foundation

public struct FocusPlan: Codable, Equatable, Sendable {
    public var workMinutes: Int
    public var breakMinutes: Int
    public var rounds: Int
    public var autoContinue: Bool

    public init(workMinutes: Int = 25, breakMinutes: Int = 5, rounds: Int = 4, autoContinue: Bool = false) {
        self.workMinutes = workMinutes
        self.breakMinutes = breakMinutes
        self.rounds = rounds
        self.autoContinue = autoContinue
    }

    public var sanitized: FocusPlan {
        FocusPlan(workMinutes: workMinutes.clamped(to: 1...180),
                  breakMinutes: breakMinutes.clamped(to: 1...60),
                  rounds: rounds.clamped(to: 1...12), autoContinue: autoContinue)
    }
}

public struct FocusSession: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Equatable, Sendable { case idle, work, rest, complete }
    public private(set) var plan = FocusPlan()
    public private(set) var phase: Phase = .idle
    public private(set) var completedRounds = 0
    public private(set) var timer = FocusTimer()
    public private(set) var waitingForNext = false
    public var isActive: Bool { phase == .work || phase == .rest }
    public var isRunning: Bool { timer.state.isRunning }
    public var round: Int { min(plan.rounds, completedRounds + (phase == .work ? 1 : 0)) }

    public init() {}

    public mutating func start(_ plan: FocusPlan, at now: Date = .now) {
        self.plan = plan.sanitized
        phase = .work
        completedRounds = 0
        beginPhase(at: now)
    }

    public mutating func toggle(at now: Date = .now) {
        guard isActive else { return }
        if isRunning && timer.state.remaining(at: now) <= 0 { _ = tick(at: now); return }
        if waitingForNext {
            waitingForNext = false
            timer.start(at: now)
        } else {
            timer.toggle(at: now)
        }
    }

    public mutating func stop() { self = FocusSession() }

    /// Finish one phase per tick. Waking late never silently skips a whole work session.
    @discardableResult
    public mutating func tick(at now: Date = .now) -> Phase? {
        guard isActive, !waitingForNext, timer.tick(at: now) else { return nil }
        let finished = phase
        if phase == .work {
            completedRounds += 1
            phase = completedRounds == plan.rounds ? .complete : .rest
        } else {
            phase = .work
        }
        guard phase != .complete else { return finished }
        beginPhase(at: now)
        if !plan.autoContinue {
            timer.pause(at: now)
            waitingForNext = true
        }
        return finished
    }

    public mutating func restore(at now: Date) {
        guard isRunning, timer.state.remaining(at: now) <= 0 else { return }
        _ = tick(at: now)
        if isActive {
            timer.pause(at: now)
            waitingForNext = true
        }
    }

    private mutating func beginPhase(at now: Date) {
        waitingForNext = false
        timer = FocusTimer(duration: TimeInterval((phase == .work ? plan.workMinutes : plan.breakMinutes) * 60))
        timer.start(at: now)
    }
}
