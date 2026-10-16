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
        let oldPhase = session.phase
        session.toggle()
        applyFocusSession(session)
        if session.phase != oldPhase { announceFocusTransition(finished: oldPhase) }
        else { focusNotice = nil }
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
        announceFocusTransition(finished: finished)
    }

    private func announceFocusTransition(finished: FocusSession.Phase) {
        let message = focusSession.phase == .complete ? "Focus session complete" :
            (finished == .work ? "Time for a break" : "Ready to focus again")
        focusNotice = message
        if preferences.notifyOnTimerComplete {
            serviceContainer.notices.focusTransition(message, quiet: preferences.quietTimerCompletion)
        }
        if !surfaceState.isOpen { presentHUD(.focusPhase(message: message)) }
    }
}
