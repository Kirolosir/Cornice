import SwiftUI
import CorniceKit

/// The Timers module: presets on top, running timers beneath.
///
/// Each running timer is the system timer HUD *wholesale*. The same orange
/// pause, the same grey dismiss, the same oversized count. A timer should look
/// the same whether it is announcing itself from the notch or sitting in a list,
/// because it is the same timer.
struct TimersPane: View {
    @Bindable var model: AppModel
    let clock: FrameClock

    @Environment(\.colorScheme) private var scheme
    private var ink: Theme.Ink { .of(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(model.preferences.timerPresetsMinutes, id: \.self) { minutes in
                    Button {
                        model.addTimer(minutes: minutes)
                    } label: {
                        Text(verbatim: "+\(minutes)m")
                            .font(Theme.Typeface.status)
                    }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(model.timers.entries.count >= TimerBoard.maximumTimers)
                }
            }

            if model.timers.entries.isEmpty {
                Text("No timers running")
                    .font(Theme.Typeface.body)
                    .foregroundStyle(ink.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 22)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.timers.entries) { entry in
                            TimerRow(entry: entry, clock: clock, model: model)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .scrollIndicators(.hidden)
            }

            Spacer(minLength: 0)
        }
    }
}

struct TimerRow: View {
    let entry: TimerEntry
    let clock: FrameClock
    @Bindable var model: AppModel

    private var id: UUID { entry.id }
    private var label: String { entry.label }
    private var isRunning: Bool { entry.isRunning }
    private var isFinished: Bool { entry.isFinished }

    @Environment(\.colorScheme) private var scheme
    private var ink: Theme.Ink { .of(scheme) }

    var body: some View {
        // Remaining time comes from the wall clock, so nothing in the model
        // changes between the second a timer starts and the second it ends.
        // Without a dependency on the frame clock the countdown was correct and
        // simply never redrawn.
        let reading = TimerCountdown.reading(entry, tick: clock.tick)
        return HStack(spacing: 12) {
            Button {
                model.toggleTimer(id)
            } label: {
                Image(systemName: isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(FilledCircleButtonStyle(
                fill: Theme.Palette.orangeDark,
                hoverFill: Theme.Palette.orangeDeep
            ))
            .disabled(isFinished)
            .help(isRunning ? "Pause" : "Resume")

            Button {
                model.removeTimer(id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(FilledCircleButtonStyle(
                fill: ink.at(0.18),
                hoverFill: ink.at(0.26)
            ))
            .help(isFinished ? "Stop the alarm" : "Dismiss")

            Spacer(minLength: 0)

            HStack(alignment: .firstTextBaseline, spacing: 11) {
                Text(isFinished ? "\(label) · done" : label)
                    .font(Theme.Typeface.body)
                    .foregroundStyle(ink.at(0.58))
                    .lineLimit(1)
                Text(reading)
                    .font(Theme.Typeface.timerValue)
                    .tracking(-0.75)
                    // Colour is carried by the value, never by the label beside
                    // it, and finishing is the one state worth a different hue.
                    .foregroundStyle(isFinished ? Theme.Palette.green : Theme.Palette.orange)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeOut(duration: 0.18), value: reading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(reading) remaining")
    }
}

/// Formats a countdown against the frame clock.
enum TimerCountdown {
    static func reading(_ entry: TimerEntry, tick: Int) -> String {
        // `tick` is unused arithmetically and deliberately so: taking it as a
        // parameter is what makes the caller depend on the clock.
        _ = tick
        return Format.duration(entry.remaining())
    }
}
