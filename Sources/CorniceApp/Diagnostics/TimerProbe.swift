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

        // Fixed dates check elapsed time and the next session without waiting.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var board = TimerBoard()
        let combinedID = board.addTime(minutes: 25, at: start)!
        board.addTime(minutes: 25, at: start.addingTimeInterval(10))
        check(board.entries[0].remaining(at: start.addingTimeInterval(10)) == 2990,
              "adding time preserves elapsed seconds")
        board.toggle(combinedID, at: start.addingTimeInterval(10))
        board.addTime(minutes: 5, at: start.addingTimeInterval(3600))
        check(board.entries[0].remaining(at: start.addingTimeInterval(3600)) == 3290,
              "an hour paused does not consume added time")
        board.toggle(combinedID, at: start.addingTimeInterval(3600))
        let end = start.addingTimeInterval(6890)
        check(board.tick(at: end).count == 1, "extended timer finishes at its new deadline")
        board.repeatTimer(combinedID, at: end)
        board.repeatTimer(combinedID, at: end.addingTimeInterval(1))
        check(board.entries[0].isRunning && board.entries[0].remaining(at: end.addingTimeInterval(1)) == 3299,
              "duplicate repeat preserves the extended session")
        board.tick(at: end.addingTimeInterval(3300))
        board.addTime(minutes: 5, at: end.addingTimeInterval(3300))
        check(board.entries.count == 1 && board.entries[0].timer.duration == 300,
              "a preset after completion starts a fresh timer")

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
        model.present(.collapsed)
        let repeated = expiredTimer("Repeat")
        model.applyTimers(TimerBoard(entries: [repeated]))
        model.tickTimers()
        model.repeatTimer(repeated.id)
        model.repeatTimer(repeated.id)
        check(!TimerAlarm.shared.isRinging, "repeating a finished timer stops its alarm")
        check(model.timers.entries.count == 1, "repeat reuses the existing timer")
        check(model.timers.entries.first?.id == repeated.id, "repeat keeps the timer identity")
        check(model.timers.entries.first?.isRunning == true, "repeat starts counting down")
        check((model.timers.entries.first?.remaining() ?? 0) > 59, "repeat uses the original duration")
        if case .timerRunning(let id, _, let running, let finished) = model.hudContent {
            check(id == repeated.id && running && !finished, "repeat updates the alert controls")
        } else {
            check(false, "repeated timer HUD is present")
        }
        model.removeTimer(repeated.id)

        // Adding presets extends one countdown, including while paused.
        model.present(.expanded)
        model.addTimer(minutes: 25)
        let extendedID = model.timers.entries[0].id
        model.addTimer(minutes: 25)
        check(model.timers.entries.count == 1, "25 + 25 keeps one timer")
        check(model.timers.entries[0].id == extendedID, "adding time keeps the timer identity")
        check(model.timers.entries[0].label == "50 min", "adding time updates the label")
        check(model.timers.entries[0].remaining() > 2998, "25 + 25 makes 50 minutes")
        model.toggleTimer(extendedID)
        model.addTimer(minutes: 5)
        check(!model.timers.entries[0].isRunning, "adding time keeps a paused timer paused")
        check(model.timers.entries[0].remaining() > 3298, "paused timer gains the full five minutes")
        model.toggleTimer(extendedID)
        check(model.timers.entries[0].isRunning, "extended timer resumes")
        model.removeTimer(extendedID)

        // Repeat from the panel must refresh a retained HUD without reopening it.
        model.present(.collapsed)
        let panelRepeat = expiredTimer("Panel repeat")
        model.applyTimers(TimerBoard(entries: [panelRepeat]))
        model.tickTimers()
        model.present(.expanded)
        model.repeatTimer(panelRepeat.id)
        check(model.surfaceState == .expanded, "repeat keeps the panel open")
        if case .timerRunning(_, _, let running, let finished) = model.hudContent {
            check(running && !finished, "repeat updates the retained HUD")
        } else {
            check(false, "retained timer HUD is present")
        }
        check(!TimerAlarm.shared.isRinging, "panel repeat stops its alarm")
        model.removeTimer(panelRepeat.id)

        // A pending retraction cannot clear a newer timer completion.
        model.present(.collapsed)
        let dismissing = expiredTimer("Dismissing")
        model.applyTimers(TimerBoard(entries: [dismissing]))
        model.tickTimers()
        model.dismissHUD()
        model.repeatTimer(dismissing.id)
        check(model.surfaceState == .collapsed, "repeat does not reopen a retracting HUD")
        try? await Task.sleep(for: .milliseconds(400))
        check(model.hudContent == nil, "retraction still clears the old HUD")
        model.removeTimer(dismissing.id)

        print("Timer probe passed")
        NSApp.terminate(nil)
    }
}
