import Foundation

/// Local repeat-one fallback for Spotify's scripting interface. Seek back just before the
/// end so the next track doesn't start. Music and connected Spotify can use their own
/// repeat-one settings.
public enum RepeatOneLoop {

    /// Leave time for the seek command to reach the player before the song ends.
    public static let baseMargin: TimeInterval = 1.2

    /// Treat track changes near the end as possible automatic advances. Leave room for
    /// Spotify's crossfade.
    public static let advanceWindow: TimeInterval = 20

    /// Whether a track change looks like the player advancing on its own.
    public static func looksAutomatic(
        previousPosition: TimeInterval,
        previousDuration: TimeInterval
    ) -> Bool {
        guard previousDuration > 0 else { return false }
        return previousDuration - previousPosition <= advanceWindow
    }

    /// Increase the seek margin if the player has advanced early before. That lets the next
    /// loop get ahead of the crossfade.
    public static func margin(observedEarlyAdvance: TimeInterval) -> TimeInterval {
        max(baseMargin, observedEarlyAdvance + 0.6)
    }

    /// Delay before looping, or nil if no loop is needed.
    ///
    /// - Parameters:
    ///   - duration: Track length in seconds.
    ///   - position: Current playhead position.
    ///   - isPlaying: A paused track doesn't need a scheduled seek.
    public static func delay(
        duration: TimeInterval,
        position: TimeInterval,
        isPlaying: Bool,
        margin: TimeInterval = baseMargin
    ) -> TimeInterval? {
        guard isPlaying, duration > margin else { return nil }
        // A position past the end is a stale reading, not a reason to wait
        // forever; loop immediately instead.
        let remaining = duration - margin - max(0, position)
        return max(0, remaining)
    }
}
