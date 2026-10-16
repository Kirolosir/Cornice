import AppKit
import SwiftUI
import CorniceKit

struct TimerSettings: View {
    @Bindable var model: AppModel
    @State private var presetText = ""
    private var presets: [Int]? {
        let parts = presetText.split(separator: ",", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.count <= 6, numbers.count == parts.count,
              numbers.allSatisfy({ (1...600).contains($0) }) else { return nil }
        return numbers
    }
    var body: some View {
        Form {
            Section("Saved timer presets") {
                TextField("Minutes, separated by commas", text: $presetText)
                    .onSubmit(savePresets)
                HStack {
                    Text("Up to six presets, from 1 to 600 minutes.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { savePresets() }.disabled(presets == nil)
                }
            }
            Section("Focus plan") {
                Stepper("Work: \(model.preferences.focusPlan.workMinutes) minutes", value: planBinding(\.workMinutes), in: 1...180)
                Stepper("Break: \(model.preferences.focusPlan.breakMinutes) minutes", value: planBinding(\.breakMinutes), in: 1...60)
                Stepper("Rounds: \(model.preferences.focusPlan.rounds)", value: planBinding(\.rounds), in: 1...12)
                Toggle("Start the next phase automatically", isOn: Binding(get: { model.preferences.focusPlan.autoContinue },
                    set: { value in model.updatePreferences { $0.focusPlan.autoContinue = value } }))
                Text("With this off, each break and work period waits for you. Plan edits apply to the next session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Completion") {
                Toggle("Quiet completions", isOn: Binding(get: { model.preferences.quietTimerCompletion },
                    set: { value in model.updatePreferences { $0.quietTimerCompletion = value } }))
                Text("Quiet timers show a notice without a looping alarm. Focus transitions use a notification; quiet mode silences its sound too.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Notify when a timer finishes", isOn: Binding(get: { model.preferences.notifyOnTimerComplete },
                    set: { value in model.updatePreferences { $0.notifyOnTimerComplete = value } }))
            }
        }
        .formStyle(.grouped)
        .onAppear { presetText = model.preferences.timerPresetsMinutes.map(String.init).joined(separator: ", ") }
    }
    private func savePresets() {
        guard let presets else { return }
        model.updatePreferences { $0.timerPresetsMinutes = presets }
        presetText = model.preferences.timerPresetsMinutes.map(String.init).joined(separator: ", ")
    }
    private func planBinding(_ key: WritableKeyPath<FocusPlan, Int>) -> Binding<Int> {
        Binding(get: { model.preferences.focusPlan[keyPath: key] },
                set: { value in model.updatePreferences { $0.focusPlan[keyPath: key] = value } })
    }
}

struct UpdateSettings: View {
    @Bindable private var updater = AppUpdater.shared
    var body: some View {
        Form {
            Section("Cornice") {
                LabeledContent("Installed version", value: AppUpdater.version)
                Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
                if let last = updater.lastCheck {
                    LabeledContent("Last checked") { Text(last, format: .dateTime.month().day().hour().minute()) }
                }
            }
            Section("Automatic checks") {
                Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticChecks },
                    set: { updater.setAutomaticChecks($0) }))
                Text("New versions are offered inside Cornice. You choose when to install and relaunch. Run the app from Applications so the update can replace it.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = updater.error {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
        }.formStyle(.grouped)
    }
}

struct ConnectionSummary: View {
    @Bindable var model: AppModel
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Music connection").font(.headline)
            HStack {
                Text(model.musicNeedsRecovery ? "Reconnecting…" : model.mediaPermissionDenied ? "Permission needed" :
                     model.media?.hasTrack == true ? "Connected" : model.preferences.mediaAccessEnabled ? "Waiting for player" : "Not connected")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Reconnect Players") { model.retryMediaPermission() }
            }
            if let updated = model.lastMediaUpdate {
                HStack(spacing: 4) {
                    Text("Last song update:")
                    Text(updated, style: .relative)
                    Text("ago")
                }.font(.caption).foregroundStyle(.secondary)
            }
            Button(copied ? "Copied" : "Copy Diagnostic Report") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                copied = true
            }
            Text("The report excludes song names, account details and tokens.").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var report: String {
        let health = MediaSource.allCases.map { source in
            let state = model.mediaHealth[source] ?? MediaConnectionHealth()
            return "\(source.displayName): failures=\(state.failures), recoveries=\(state.recoveries), denied=\(state.permissionDenied)"
        }.joined(separator: "\n")
        return """
        Cornice \(AppUpdater.version)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Model: \(model.hardware?.modelIdentifier ?? "Unknown")
        Setup complete: \(model.preferences.hasCompletedSetup)
        Music enabled: \(model.preferences.mediaAccessEnabled)
        Audio capture enabled: \(model.preferences.audioVisualizerEnabled)
        Receiving audio: \(model.hasLiveAudio)
        Reconnecting: \(model.musicNeedsRecovery)
        \(health)
        """
    }
}
