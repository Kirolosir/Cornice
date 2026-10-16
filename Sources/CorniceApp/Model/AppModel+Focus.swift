import AppKit
import CorniceKit

@MainActor
extension AppModel {
    func startFocusSession() {
        var session = focusSession
        session.start(preferences.focusPlan)
        applyFocusSession(session)
        focusNotice = nil
    }

    func toggleFocusSession() {
        var session = focusSession
        session.toggle()
        applyFocusSession(session)
        focusNotice = nil
    }

    func stopFocusSession() {
        applyFocusSession(FocusSession())
        focusNotice = nil
    }

    func tickFocusSession() {
        guard focusSession.isRunning else { return }
        var session = focusSession
        guard let finished = session.tick() else { return }
        applyFocusSession(session)
        let message = session.phase == .complete ? "Focus session complete" :
            (finished == .work ? "Time for a break" : "Ready to focus again")
        focusNotice = message
        if preferences.notifyOnTimerComplete {
            NotificationPresenter.shared.focusTransition(message, quiet: preferences.quietTimerCompletion)
        }
        if !surfaceState.isOpen { presentHUD(.focusPhase(message: message)) }
    }
}
