import SwiftUI
import CorniceKit

struct TimersPane: View {
    @Bindable var model: AppModel
    let tick: Int

    private var tint: Color { model.artworkTint ?? Theme.Palette.accent }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(model.preferences.timerPresetsMinutes, id: \.self) { minutes in
                    Button {
                        model.addTimer(minutes: minutes)
                    } label: {
                        Text(verbatim: "+\(minutes)m")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(SurfaceCapsuleButtonStyle(tint: tint))
                }
                Spacer()
            }

            if model.timers.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Color(white: 0.4))
                    Text("No timers running")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(white: 0.55))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.timers.entries) { entry in
                        TimerRow(entry: entry, tint: tint, model: model)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct TimerRow: View {
    let entry: TimerEntry
    let tint: Color
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(white: 0.7))
                    Spacer()
                    Text(Format.duration(entry.remaining()))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(entry.isFinished ? Theme.Palette.success : .white)
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule()
                            .fill(entry.isFinished ? Theme.Palette.success : tint)
                            .frame(width: proxy.size.width * entry.progress())
                    }
                }
                .frame(height: 4)
            }

            Button {
                model.toggleTimer(entry.id)
            } label: {
                Image(systemName: entry.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(SurfaceIconButtonStyle(diameter: 24))
            .disabled(entry.isFinished)

            Button {
                model.removeTimer(entry.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(SurfaceIconButtonStyle(diameter: 24))
            .foregroundStyle(Theme.Palette.failure)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.label), \(Format.duration(entry.remaining())) remaining")
    }
}
