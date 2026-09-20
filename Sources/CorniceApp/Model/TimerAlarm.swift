import AVFoundation
import CorniceKit

/// One looping player, shared by timers waiting to be acknowledged.
@MainActor
final class TimerAlarm {
    static let shared = TimerAlarm()

    private var player: AVAudioPlayer?
    private(set) var pendingIDs: Set<UUID> = []
    var isRinging: Bool { player?.isPlaying == true }

    private init() {}

    func start(for ids: [UUID]) {
        pendingIDs.formUnion(ids)
        guard !pendingIDs.isEmpty, !isRinging else { return }

        for name in ["Submarine", "Glass"] {
            let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
            do {
                let sound = try AVAudioPlayer(contentsOf: url)
                sound.numberOfLoops = -1
                sound.prepareToPlay()
                guard sound.play() else { continue }
                player = sound
                return
            } catch {
                Log.app.notice("could not load timer sound: \(error.localizedDescription, privacy: .public)")
            }
        }
        Log.app.error("timer alarm could not start")
    }

    func acknowledge(_ id: UUID) {
        pendingIDs.remove(id)
        if pendingIDs.isEmpty { stop() }
    }

    func stop() {
        player?.stop()
        player = nil
        pendingIDs.removeAll()
    }
}
