import AppKit
import CorniceKit

@MainActor
extension Probes {
    static func probeFeatures() async {
        func check(_ condition: Bool, _ message: String) {
            guard condition else { print("FAIL: \(message)"); exit(1) }
            print("PASS: \(message)")
        }

        let player = FeatureCheckPlayer()
        var preferences = PreviewServices.previewPreferences()
        preferences.mediaAccessEnabled = false
        preferences.quietTimerCompletion = true
        let preferenceStore = EphemeralPreferencesStore(preferences)
        let sessionStore = EphemeralSessionStore()
        let services = PreviewServices.container(media: MediaCoordinator(controllers: [player]),
                                                  preferences: preferenceStore, sessions: sessionStore)
        let notices = services.notices as! PreviewNotices
        let model = AppModel(services: services)
        await model.start()
        model.stopHUDSources()
        try? await Task.sleep(for: .milliseconds(350))
        check(await player.reads == 0, "setup does not read music before connecting")
        model.finishSetup()
        check(!model.preferences.mediaAccessEnabled, "skipping setup leaves music permission optional")
        model.retryMediaPermission()
        try? await Task.sleep(for: .milliseconds(450))
        check(model.media?.hasTrack == true, "explicit connect loads the player")
        model.refreshNow("media")
        try? await Task.sleep(for: .milliseconds(20))
        model.updatePreferences { $0.mediaAccessEnabled = false }
        try? await Task.sleep(for: .milliseconds(450))
        check(model.media == nil && model.indicatorMode == .resting, "a late player response cannot undo disconnect")

        model.addTimer(minutes: 25)
        model.addTimer(minutes: 25)
        let id = model.timers.entries[0].id
        model.toggleTimer(id)
        try? await Task.sleep(for: .milliseconds(120))
        let saved = await sessionStore.load()
        check(saved.timers == model.timers && !saved.timers.entries[0].isRunning,
              "timer additions and pauses save without quitting")
        var expired = TimerEntry(label: "Quiet", minutes: 1)
        expired.timer.start(at: Date().addingTimeInterval(-61))
        model.applyTimers(TimerBoard(entries: [expired]))
        model.tickTimers()
        check(!TimerAlarm.shared.isRinging && notices.delivered.last?.quiet == true,
              "quiet completion delivers a notice without a looping alarm")
        let delivered = notices.delivered.count
        model.tickTimers()
        check(notices.delivered.count == delivered, "a completed timer only announces once")
        model.repeatTimer(expired.id)
        check(model.timers.entries.first?.isRunning == true, "quiet timers can repeat")
        model.removeTimer(expired.id)

        var focus = FocusSession()
        focus.start(FocusPlan(workMinutes: 1, breakMinutes: 1, rounds: 2),
                    at: Date().addingTimeInterval(-61))
        model.applyFocusSession(focus)
        model.present(.collapsed)
        model.tickTimers()
        check(model.focusSession.phase == .rest && model.focusSession.waitingForNext,
              "a work period finishes into a waiting break")
        check(notices.delivered.last?.title == "Time for a break" && notices.delivered.last?.quiet == true,
              "focus transitions respect quiet completion")
        check(model.hudContent?.kind == .focusPhase, "a focus transition has an actionable notch notice")
        model.toggleFocusSession()
        check(model.focusSession.isRunning, "the next focus phase starts on request")
        model.toggleFocusSession()
        model.updatePreferences { $0.timerPresetsMinutes = [3, 12, 45] }
        await model.persistForRelaunch()
        model.shutDown()

        let restored = AppModel(services: services)
        await restored.start()
        restored.stopHUDSources()
        check(restored.focusSession == model.focusSession, "focus phase and pause survive relaunch")
        check(restored.preferences.timerPresetsMinutes == [3, 12, 45], "the latest settings flush before relaunch")
        check(restored.timers.entries.isEmpty, "removed timers stay removed after relaunch")
        restored.shutDown()
        TimerAlarm.shared.stop()
        print("Feature integration probe passed")
        exit(0)
    }
}

private actor FeatureCheckPlayer: MediaControlling {
    nonisolated let source: MediaSource = .spotify
    private(set) var reads = 0
    func isRunning() async -> Bool { true }
    func snapshot() async throws -> MediaSnapshot? {
        reads += 1
        // Ignore cancellation like an already-running player request can.
        try? await Task.sleep(for: .milliseconds(180))
        return MediaSnapshot(source: source, state: .playing, title: "Test track",
                             artist: "Test artist", duration: 180, position: 20)
    }
    func perform(_ command: MediaCommand) async throws {}
}
