import Foundation
import CorniceKit

func check(_ value: Bool, _ message: String) {
    guard value else { fatalError(message) }
    print("PASS: \(message)")
}
let start = Date(timeIntervalSince1970: 1000)
var focus = FocusSession()
focus.start(FocusPlan(workMinutes: 1, breakMinutes: 1, rounds: 2), at: start)
check(focus.tick(at: start.addingTimeInterval(60)) == .work, "work ends once")
check(focus.waitingForNext && focus.phase == .rest, "a break waits for the user by default")
check(focus.tick(at: start.addingTimeInterval(600)) == nil, "waiting does not consume the next phase")
focus.toggle(at: start.addingTimeInterval(600))
check(focus.tick(at: start.addingTimeInterval(660)) == .rest, "break moves to the next work period")
focus.toggle(at: start.addingTimeInterval(700))
focus.tick(at: start.addingTimeInterval(760))
check(focus.phase == .complete && focus.completedRounds == 2, "the requested rounds complete")
focus.start(FocusPlan(workMinutes: 1, rounds: 1), at: start)
focus.toggle(at: start.addingTimeInterval(60))
check(focus.phase == .complete, "pausing exactly at the deadline does not get stuck")
focus.start(FocusPlan(workMinutes: 1, breakMinutes: 1, rounds: 2, autoContinue: true), at: start)
focus.restore(at: start.addingTimeInterval(600))
check(focus.phase == .rest && focus.waitingForNext && !focus.isRunning, "restored overdue focus waits instead of skipping sessions")

let song = MediaSnapshot(source: .spotify, state: .playing, title: "Test", artist: "Test", duration: 180, position: 10)
var freshness = PlaybackFreshness()
check(!freshness.needsRecovery(song, at: start), "a new track is not stale")
check(freshness.needsRecovery(song, at: start.addingTimeInterval(12)), "a stuck player requests recovery")
check(!freshness.needsRecovery(song, at: start.addingTimeInterval(13)) && freshness.isStale, "recovery is throttled without hiding the warning")
check(!freshness.needsRecovery(song.with(position: 20), at: start.addingTimeInterval(14)) && !freshness.isStale, "progress clears the stale state")
check(!freshness.needsRecovery(song.with(state: .paused), at: start.addingTimeInterval(100)), "a pause is not a connection failure")

actor FlakyPlayer: MediaControlling {
    nonisolated let source: MediaSource = .spotify
    private var reads = 0
    private(set) var resets = 0
    func isRunning() async -> Bool { true }
    func snapshot() async throws -> MediaSnapshot? {
        reads += 1
        if reads <= 3 { throw ServiceError.commandFailed(tool: "Test", exitCode: -609, stderr: "test interruption") }
        return MediaSnapshot(source: source, state: .playing, title: "Recovered", artist: "Test", duration: 100, position: 10)
    }
    func perform(_ command: MediaCommand) async throws {}
    func resetAuthorization() async { resets += 1 }
}
let player = FlakyPlayer()
let media = MediaCoordinator(controllers: [player])
for _ in 0..<3 { _ = await media.snapshot() }
check(await player.resets == 1, "repeated transient failures reconnect automatically")
check(await media.snapshot()?.title == "Recovered", "the next read can recover without a relaunch")
let health = await media.connectionHealth()[.spotify]!
check(health.failures == 0 && health.recoveries == 1, "successful recovery resets the failure count")
var denied = MediaConnectionHealth(); denied.failures = 10; denied.permissionDenied = true
check(!denied.shouldRecover(at: start), "denied permissions never auto-prompt")

check(!Preferences().mediaAccessEnabled, "fresh installs wait for music consent")
let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"schemaVersion":3}"#.utf8))
check(old.mediaAccessEnabled, "existing installs keep their music setting")
let corruptPlan = FocusPlan(workMinutes: -10, breakMinutes: 999, rounds: 0).sanitized
check(corruptPlan.workMinutes == 1 && corruptPlan.breakMinutes == 60 && corruptPlan.rounds == 1, "invalid plan settings are bounded")
check(BatteryCondition.resolve(health: "Good", condition: nil) == .normal, "reported normal battery health is preserved")
check(BatteryCondition.resolve(health: "Good", condition: "Check Battery") == .serviceRecommended, "a service condition takes priority")
check(BatteryCondition.resolve(health: nil, condition: nil) == .unavailable, "missing battery health is not guessed")
check(MemoryPressure(rawValue: 2) == .warning && MemoryPressure(rawValue: 999) == nil, "memory pressure uses reported levels")
let desktop = BatteryState(level: 0.8, isCharging: false, isPluggedIn: true, minutesRemaining: 120)
check(desktop.powerDescription == "On power · not charging", "plugged-in batteries do not show a discharge estimate")

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cornice-session-check-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: folder) }
let url = folder.appendingPathComponent("sessions.json")
let store = SessionStore(url: url)
var board = TimerBoard()
let id = board.add(minutes: 25, at: .now)!
try await store.save(SessionSnapshot(timers: board, revision: 2))
try await store.save(SessionSnapshot(revision: 1))
let loaded = await SessionStore(url: url).load()
check(loaded.timers.entries.first?.id == id && loaded.timers.anyRunning, "relaunch restores the running timer and ignores stale saves")
let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
check(permissions.intValue == 0o600, "saved timer state is owner-only")
try Data("not valid JSON".utf8).write(to: url)
check(await SessionStore(url: url).load().timers.entries.isEmpty, "corrupt session files do not prevent launch")
print("Feature checks passed")
