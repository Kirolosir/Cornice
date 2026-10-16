import Foundation
import CorniceKit

func check(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
    FileHandle.standardOutput.write(Data("PASS: \(message)\n".utf8))
}

actor CheckPlayer: MediaControlling {
    nonisolated let source: MediaSource
    private let running: Bool
    private var denied: Bool
    private var title = "First song"
    private var reads = 0

    init(_ source: MediaSource, running: Bool = true, denied: Bool = false) {
        self.source = source
        self.running = running
        self.denied = denied
    }

    func isRunning() async -> Bool { running }
    func snapshot() async throws -> MediaSnapshot? {
        reads += 1
        if denied { throw ServiceError.unauthorized(detail: "test denial") }
        return MediaSnapshot(source: source, state: .playing, title: title,
                             artist: "Test artist", duration: 180, position: 20)
    }
    func perform(_ command: MediaCommand) async throws {}
    func resetAuthorization() async { denied = false }
    func setTitle(_ value: String) { title = value }
    func readCount() -> Int { reads }
}

check(Preferences().idleDisplay == .artworkAndSpectrum, "fresh installs show bars beside the notch")
let savedTitle = try JSONDecoder().decode(Preferences.self, from: Data("{\"idleDisplay\":\"artworkAndTitle\"}".utf8))
check(savedTitle.idleDisplay == .artworkAndTitle, "an existing title preference is kept")
let missingField = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
check(missingField.idleDisplay == .artworkAndSpectrum, "older settings without a display choice get bars")

let spotify = CheckPlayer(.spotify, denied: true)
let music = CheckPlayer(.appleMusic, running: false)
let coordinator = MediaCoordinator(controllers: [spotify, music])
check(await coordinator.snapshot() == nil, "a denied player has no snapshot")
check(await coordinator.allSourcesUnavailable(), "closed Music does not hide Spotify's denial")
check(await coordinator.deniedRunningSources() == [.spotify], "the denied player is identified")
check(await coordinator.runningSources() == [.spotify], "a denied player is still shown as open")
_ = await coordinator.snapshot()
check(await spotify.readCount() == 1, "denied players are not prompted on every poll")
await coordinator.resetAvailability()
check(await coordinator.snapshot()?.title == "First song", "retry restores polling without restarting Cornice")
await spotify.setTitle("Next song")
check(await coordinator.snapshot()?.title == "Next song", "the following song replaces the previous reading")
check(await coordinator.deniedRunningSources().isEmpty, "a recovered player clears the warning")

let mixed = MediaCoordinator(controllers: [CheckPlayer(.spotify, denied: true), CheckPlayer(.appleMusic)])
check(await mixed.snapshot()?.source == .appleMusic, "a denied Spotify does not hide working Music")
check(await mixed.deniedRunningSources() == [.spotify], "partial denials remain visible in Settings")
check(await mixed.allSourcesUnavailable() == false, "one working player is not reported as blocked")

// Use a script error to exercise the real denial cache without changing macOS permissions.
let runner = AppleScriptRunner()
do {
    _ = try await runner.run("error \"test denial\" number -1743", target: "Spotify")
} catch {}
check(await runner.isDenied("Spotify"), "the real script runner records an Automation denial")
let realController = ScriptedMediaController(source: .spotify, runner: runner)
let realCoordinator = MediaCoordinator(controllers: [realController])
await realCoordinator.resetAvailability()
check(await runner.isDenied("Spotify") == false, "retry also clears the real script runner's denial")
let result = try await runner.run("return \"ready\"", target: "Spotify")
check(result.string == "ready", "scripts execute again after retry")
let failedScript = """
property attempts : 0
set attempts to attempts + 1
if attempts is 1 then error "temporary player error" number -609
return "reused a failed script"
"""
for _ in 0..<2 {
    var failed = false
    do { _ = try await runner.run(failedScript, target: "Test player") }
    catch { failed = true }
    check(failed, "failed scripts are recompiled before retrying")
}

let cancelledRead = Task {
    try? await Task.sleep(for: .milliseconds(100))
    return try await runner.run("return \"should not run\"", target: "Test player")
}
cancelledRead.cancel()
var cancelled = false
do { _ = try await cancelledRead.value }
catch is CancellationError { cancelled = true }
check(cancelled, "cancelled polls stop before running a script")
check(try await runner.run("return \"ready\"", target: "Test player").string == "ready",
      "the queue keeps working after a cancelled read")
print("Media checks passed")
