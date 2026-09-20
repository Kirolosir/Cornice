import AppKit
import CorniceKit

@MainActor
extension Probes {
    /// Runs the completion and dismissal paths without waiting a full minute.
    static func probeTimers() async {
        let model = AppModel(services: PreviewServices.container())
        let controller = NotchWindowController(model: model)
        // Keep this probe off screen so mouse input cannot dismiss its fixtures.
        defer {
            TimerAlarm.shared.stop()
            model.stopRefreshLoops()
            controller.tearDown()
        }

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else {
                print("FAIL: \(message)")
                exit(1)
            }
            print("PASS: \(message)")
        }

        func expiredTimer(_ label: String) -> TimerEntry {
            var entry = TimerEntry(label: label, minutes: 1)
            entry.timer.start(at: Date().addingTimeInterval(-61))
            return entry
        }

        // Two completions on the same tick must share one alarm.
        let first = expiredTimer("First")
        let second = expiredTimer("Second")
        model.applyTimers(TimerBoard(entries: [first, second]))
        model.tickTimers()
        check(model.timers.entries.allSatisfy(\.isFinished), "both timers finish")
        check(TimerAlarm.shared.pendingIDs.count == 2, "both completions are pending")
        check(model.surfaceState == .hud(.timerRunning), "finished timer opens its HUD")

        // Eight seconds covers several loops of the sound. Each wake also
        // checks that the main actor can still process input after completion.
        for second in 1...8 {
            try? await Task.sleep(for: .seconds(1))
            model.tickTimers()
            check(TimerAlarm.shared.isRinging, "alarm still playing at \(second)s")
        }
        check(TimerAlarm.shared.pendingIDs.count == 2, "later ticks do not duplicate completion")

        model.removeTimer(first.id)
        check(TimerAlarm.shared.isRinging, "dismissing one timer leaves the other ringing")
        if case .timerRunning(let id, _, _, _) = model.hudContent {
            check(id == second.id, "HUD advances to the next finished timer")
        } else {
            check(false, "next timer HUD is present")
        }
        model.setHovering(true)
        model.removeTimer(second.id)
        check(!TimerAlarm.shared.isRinging, "last dismissal stops playback")
        check(model.surfaceState == .expanded, "dismissal returns to a usable panel")
        for _ in 0..<20 where model.hudContent != nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        check(model.hudContent == nil, "dismissed HUD is cleared")

        model.setHovering(false)
        model.present(.collapsed)
        let third = expiredTimer("Again")
        model.applyTimers(TimerBoard(entries: [third]))
        model.tickTimers()
        check(TimerAlarm.shared.isRinging, "another timer can ring after dismissal")
        controller.close()
        check(!TimerAlarm.shared.isRinging, "Escape acknowledges the visible timer")
        check(model.surfaceState == .collapsed, "Escape closes the surface")

        // An unrelated announcement must not stop a timer sounding in the panel.
        model.present(.expanded)
        let fourth = expiredTimer("In panel")
        model.applyTimers(TimerBoard(entries: [fourth]))
        model.tickTimers()
        check(model.surfaceState == .expanded, "completion keeps an open panel open")
        model.present(.collapsed)
        model.presentHUD(.charging(level: 0.5))
        model.dismissHUD()
        check(TimerAlarm.shared.isRinging, "dismissing a charging HUD leaves the alarm alone")
        model.removeTimer(fourth.id)
        check(!TimerAlarm.shared.isRinging, "timer row stops its alarm")
        print("Timer probe passed")
        NSApp.terminate(nil)
    }
}
