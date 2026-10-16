import SwiftUI
import CorniceKit

struct FocusPane: View {
    @Bindable var model: AppModel
    let clock: FrameClock
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var session: FocusSession { model.focusSession }
    private var ink: Theme.Ink { .of(scheme) }

    var body: some View {
        let _ = clock.tick
        VStack(alignment: .leading, spacing: 12) {
            if session.phase == .idle || session.phase == .complete {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.phase == .complete ? "Session complete" : "A little room to focus")
                            .font(Theme.Typeface.body.weight(.semibold)).foregroundStyle(ink.primary)
                        Text("\(model.preferences.focusPlan.workMinutes)m work · \(model.preferences.focusPlan.breakMinutes)m break · \(model.preferences.focusPlan.rounds) rounds")
                            .font(Theme.Typeface.status).foregroundStyle(ink.secondary)
                    }
                    Spacer()
                    Image(systemName: "leaf.fill").foregroundStyle(Theme.Palette.green).font(.title2)
                }
                HStack(spacing: 10) {
                    Button(session.phase == .complete ? "Start Again" : "Start Focus") { model.startFocusSession() }
                        .buttonStyle(SoftButtonStyle(height: 32))
                    Button("Edit Plan") { SettingsWindow.shared.show(model: model, tab: .timers) }
                        .buttonStyle(SoftButtonStyle(height: 32))
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.phase == .work ? "Focus" : "Break")
                            .font(Theme.Typeface.body.weight(.semibold)).foregroundStyle(ink.primary)
                        Text("Round \(session.round) of \(session.plan.rounds)\(session.waitingForNext ? " · ready when you are" : "")")
                            .font(Theme.Typeface.status).foregroundStyle(ink.secondary)
                    }
                    Spacer()
                    Text(Format.duration(session.timer.state.remaining()))
                        .font(Theme.Typeface.timerValue).monospacedDigit().foregroundStyle(Theme.Palette.green)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: session.timer.state.remaining().rounded())
                }
                ProgressView(value: session.timer.state.progress()).tint(Theme.Palette.green)
                    .accessibilityLabel("\(session.phase == .work ? "Focus" : "Break") progress")
                HStack(spacing: 10) {
                    Button(session.waitingForNext ? "Begin \(session.phase == .work ? "Focus" : "Break")" : (session.isRunning ? "Pause" : "Resume")) {
                        model.toggleFocusSession()
                    }.buttonStyle(SoftButtonStyle(height: 32))
                    Button("End Session") { model.stopFocusSession() }.buttonStyle(SoftButtonStyle(height: 32))
                }
            }
            if let notice = model.focusNotice {
                Text(notice).font(.caption).foregroundStyle(ink.secondary).accessibilityAddTraits(.updatesFrequently)
            }
        }
    }
}
