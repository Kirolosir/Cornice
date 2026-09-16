import SwiftUI
import CorniceKit

/// A deliberately small focus timer.
///
/// Scope discipline: this is a timer, not a productivity system. No streaks, no
/// history, no statistics, no task list. It exists because a build you are
/// waiting on and a block of time you are protecting are the same kind of
/// glanceable state as everything else in this app — and it stops there.
struct FocusPane: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    /// Repaints once a second while a session is live.
    ///
    /// Purely a repaint trigger: the timer's remaining time is computed from
    /// wall-clock time, so a dropped tick or a suspended app changes nothing
    /// about correctness.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var state: FocusTimerState { model.focus.state }

    var body: some View {
        VStack(spacing: 10) {
            PaneHeader(title: "Focus", subtitle: subtitle)

            HStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(Theme.Palette.hairline(scheme), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: state.progress())
                        .stroke(
                            state.isRunning ? Theme.Palette.accent : Theme.Palette.neutral,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.9), value: state.progress())

                    Text(Format.duration(state.remaining()))
                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.Palette.primaryText(scheme))
                }
                .frame(width: 88, height: 88)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Button {
                            model.toggleFocusTimer()
                        } label: {
                            Label(primaryLabel, systemImage: primarySymbol)
                        }
                        .buttonStyle(PanelButtonStyle(tint: Theme.Palette.accent))

                        Button {
                            model.resetFocusTimer()
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(PanelButtonStyle())
                        .disabled(!state.isActive)
                    }
                    .font(Theme.Typeface.body)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Session length")
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.Palette.tertiaryText(scheme))

                        HStack(spacing: 4) {
                            ForEach([15, 25, 45, 60], id: \.self) { minutes in
                                Button {
                                    model.setFocusDuration(minutes: minutes)
                                } label: {
                                    Text("\(minutes)m")
                                        .font(Theme.Typeface.monoSmall)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill((scheme == .dark ? Color.white : Color.black)
                                                    .opacity(model.preferences.focusDurationMinutes == minutes ? 0.12 : 0.04))
                                        )
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(
                                    model.preferences.focusDurationMinutes == minutes
                                        ? Theme.Palette.accent
                                        : Theme.Palette.secondaryText(scheme)
                                )
                                // Changing length mid-session applies to the
                                // next one, so the control stays available but
                                // says so.
                                .help(state.isActive
                                      ? "Applies to the next session"
                                      : "Set the session length")
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .cardSurface(padding: 14)

            Spacer(minLength: 0)
        }
        .onReceive(tick) { _ in
            guard state.isRunning else { return }
            model.tickFocusTimer()
        }
    }

    private var subtitle: String {
        switch state {
        case .idle: "\(model.preferences.focusDurationMinutes) minute session"
        case .running: "In progress"
        case .paused: "Paused"
        case .finished: "Session complete"
        }
    }

    private var primaryLabel: String {
        switch state {
        case .idle, .finished: "Start"
        case .running: "Pause"
        case .paused: "Resume"
        }
    }

    private var primarySymbol: String {
        state.isRunning ? "pause.fill" : "play.fill"
    }
}
