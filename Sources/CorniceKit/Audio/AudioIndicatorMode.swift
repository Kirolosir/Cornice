import Foundation

public enum AudioIndicatorMode: Equatable, Sendable {
    case resting, spectrum, playback

    public static func resolve(captureEnabled: Bool, captureRunning: Bool,
                               hasTrack: Bool, isPlaying: Bool, hasAudio: Bool) -> Self {
        // A song's indicator belongs to that song, even if another app makes sound.
        if hasTrack && !isPlaying { return .resting }
        if captureEnabled {
            return captureRunning && hasAudio ? .spectrum : .resting
        }
        return isPlaying ? .playback : .resting
    }
}
