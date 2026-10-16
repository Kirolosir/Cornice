import Foundation

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var timers: TimerBoard
    public var focus: FocusSession
    public var revision: UInt64
    public init(timers: TimerBoard = TimerBoard(), focus: FocusSession = FocusSession(), revision: UInt64 = 0) {
        self.timers = timers; self.focus = focus; self.revision = revision
    }

    public var isValid: Bool {
        timers.entries.count <= TimerBoard.maximumTimers &&
        Set(timers.entries.map(\.id)).count == timers.entries.count &&
        timers.entries.allSatisfy { $0.label.count <= 256 && Self.valid($0.timer) } &&
        focus.plan == focus.plan.sanitized && (0...focus.plan.rounds).contains(focus.completedRounds) &&
        Self.valid(focus.timer) && (!focus.waitingForNext || (focus.isActive && !focus.isRunning))
    }

    private static func valid(_ timer: FocusTimer) -> Bool {
        guard timer.duration.isFinite, (0...31_536_000).contains(timer.duration) else { return false }
        switch timer.state {
        case .idle: return true
        case .running(let deadline, let total):
            return deadline.timeIntervalSince1970.isFinite && abs(deadline.timeIntervalSince1970) < 100_000_000_000 &&
                total.isFinite && (0...31_536_000).contains(total)
        case .paused(let remaining, let total):
            return remaining.isFinite && total.isFinite && (0...31_536_000).contains(total) && (0...total).contains(remaining)
        case .finished(let total): return total.isFinite && (0...31_536_000).contains(total)
        }
    }

    public func restored(at now: Date = .now) -> Self {
        var restored = self
        _ = restored.timers.tick(at: now)
        restored.focus.restore(at: now)
        return restored
    }
}

public protocol SessionPersisting: Sendable {
    func load() async -> SessionSnapshot
    func save(_ snapshot: SessionSnapshot) async throws
}

public actor SessionStore: SessionPersisting {
    private let url: URL
    private var lastRevision: UInt64 = 0
    public init(url: URL? = nil) {
        self.url = url ?? PreferencesStore.defaultURL().deletingLastPathComponent().appendingPathComponent("sessions.json")
    }
    public func load() -> SessionSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return SessionSnapshot() }
        do {
            let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: url))
            guard snapshot.isValid else { throw CocoaError(.fileReadCorruptFile) }
            lastRevision = snapshot.revision
            return snapshot.restored()
        } catch {
            let backup = url.deletingLastPathComponent().appendingPathComponent("sessions-corrupt-\(UUID().uuidString).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return SessionSnapshot()
        }
    }
    public func save(_ snapshot: SessionSnapshot) throws {
        guard snapshot.revision >= lastRevision, snapshot.isValid else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        lastRevision = snapshot.revision
    }
}

public actor EphemeralSessionStore: SessionPersisting {
    private var snapshot: SessionSnapshot
    public init(_ snapshot: SessionSnapshot = SessionSnapshot()) { self.snapshot = snapshot }
    public func load() -> SessionSnapshot { snapshot.restored() }
    public func save(_ snapshot: SessionSnapshot) {
        if snapshot.revision >= self.snapshot.revision && snapshot.isValid { self.snapshot = snapshot }
    }
}
