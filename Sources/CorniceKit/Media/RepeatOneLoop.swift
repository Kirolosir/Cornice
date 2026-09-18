import Foundation

/// Repeating a single track on a player that cannot be asked to.
///
/// Spotify's scripting interface exposes `repeating` as a boolean and nothing
/// else: it can be told to repeat the album or playlist, and there is no way to
/// ask it for the track. Apple Music's `song repeat` is a real three-way and
/// needs none of this.
///
/// So the app does it: while a track is playing with repeat-one set, it seeks
/// back to the start a moment before the end, and the player never reaches the
/// point where it would move on. Pre-empting the end rather than reacting to it
/// is what keeps the loop seamless — waiting for the track to change means the
/// next one has already started playing, and correcting after the fact is both
/// audible and slower.
public enum RepeatOneLoop {

    /// How far before the end to seek back.
    ///
    /// Long enough to beat the round trip to the player — a command is an Apple
    /// event to another process, and one measured at roughly 100 ms — and short
    /// enough that the clipped tail is not noticeable. Too late is much worse
    /// than too early: the player has already advanced and the loop is broken.
    public static let margin: TimeInterval = 0.4

    /// How long to wait before looping the track, or `nil` when there is nothing
    /// to schedule.
    ///
    /// - Parameters:
    ///   - duration: track length in seconds.
    ///   - position: the playhead now.
    ///   - isPlaying: a paused track is not approaching its end.
    public static func delay(
        duration: TimeInterval,
        position: TimeInterval,
        isPlaying: Bool
    ) -> TimeInterval? {
        guard isPlaying, duration > margin else { return nil }
        // A position past the end is a stale reading, not a reason to wait
        // forever; loop immediately instead.
        let remaining = duration - margin - max(0, position)
        return max(0, remaining)
    }
}
