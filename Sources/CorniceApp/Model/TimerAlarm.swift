import AppKit
import CorniceKit

/// The sound a finished timer makes.
///
/// A timer that ends silently is not a timer. The whole reason to set one is to
/// stop watching it. A single notification banner is not enough for something
/// you deliberately looked away from, so this repeats, the way the Clock app's
/// alarm does, until it is acknowledged.
///
/// It stops on its own after `maximumDuration` regardless. An alarm that rings
/// forever because nobody was at the desk is worse than one that gives up.
@MainActor
final class TimerAlarm {

    static let shared = TimerAlarm()

    /// How long between chimes. Roughly the cadence of the system's own alarm:
    /// long enough not to be a siren, short enough not to be missed.
    private let interval: TimeInterval = 1.6
    /// Rings for two minutes at most, then stops by itself.
    private let maximumDuration: TimeInterval = 120

    private var repeater: Timer?
    private var startedAt: Date?
    private var sound: NSSound?

    private init() {}

    /// Whether an alarm is currently sounding, so the UI can offer to stop it.
    private(set) var isRinging = false

    func start() {
        guard !isRinging else { return }
        isRinging = true
        startedAt = .now
        chime()

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let startedAt = self.startedAt,
                   Date().timeIntervalSince(startedAt) >= self.maximumDuration {
                    self.stop()
                    return
                }
                self.chime()
            }
        }
        // Common mode, so it keeps ringing while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        repeater = timer
    }

    func stop() {
        repeater?.invalidate()
        repeater = nil
        sound?.stop()
        sound = nil
        startedAt = nil
        isRinging = false
    }

    private func chime() {
        // Loaded fresh each time rather than replayed: `NSSound` will not
        // restart a sound that is still playing, which turns a repeating alarm
        // into a single chime the moment the interval and the sound's own length
        // overlap.
        guard let sound = NSSound(named: "Submarine") ?? NSSound(named: "Glass") else {
            // No system sound available is not worth failing over, but it is
            // worth saying, because the user asked for a noise and got none.
            Log.app.notice("no system alarm sound available")
            NSSound.beep()
            return
        }
        self.sound = sound
        sound.play()
    }
}
