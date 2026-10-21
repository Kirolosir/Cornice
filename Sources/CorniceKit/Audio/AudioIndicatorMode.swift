import Foundation

public enum AudioIndicatorMode: Equatable, Sendable {
    case resting, spectrum, playback

    public static func resolve(captureEnabled: Bool, captureRunning: Bool,
                               hasTrack: Bool, isPlaying: Bool, hasAudio: Bool,
                               playbackIsReliable: Bool = true) -> Self {
        // A song's indicator belongs to that song, even if another app makes sound.
        if hasTrack && !isPlaying { return .resting }
        if captureEnabled {
            return captureRunning && hasAudio ? .spectrum : .resting
        }
        // A stuck player can still produce real audio. Only the fallback animation
        // needs a reliable playback report.
        return isPlaying && playbackIsReliable ? .playback : .resting
    }
}
