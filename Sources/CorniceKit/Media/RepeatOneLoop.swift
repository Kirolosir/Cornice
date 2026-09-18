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

    /// How far before the end to seek back, before anything has been learned.
    ///
    /// Long enough to beat the round trip to the player — a command is an Apple
    /// event to another process, measured at roughly 100 ms — and short enough
    /// that the clipped tail is not noticeable. Too late is much worse than too
    /// early: the player has already advanced and the loop is broken.
    public static let baseMargin: TimeInterval = 1.2

    /// How close to the end a track change has to be to read as the player
    /// moving on by itself rather than the user skipping.
    ///
    /// Generous, because crossfade can be set as high as twelve seconds and the
    /// cost of being wrong is small: a deliberate skip made within a few seconds
    /// of the end gets treated as an advance and the track restarts, which is
    /// what repeat-one means anyway.
    public static let advanceWindow: TimeInterval = 20

    /// Whether a track change looks like the player advancing on its own.
    public static func looksAutomatic(
        previousPosition: TimeInterval,
        previousDuration: TimeInterval
    ) -> Bool {
        guard previousDuration > 0 else { return false }
        return previousDuration - previousPosition <= advanceWindow
    }

    /// The margin to use, given how early this player has been seen to move on.
    ///
    /// Spotify can be set to crossfade, which starts the next track seconds
    /// before the current one reaches the length it reports — and that setting
    /// lives on Spotify's servers, so it cannot be asked for. Measured here, a
    /// 230.5 second track was abandoned at about 226. So the margin is learned:
    /// the first loop that gets away sets the distance for the next one, and
    /// after that the loop lands ahead of the crossfade instead of behind it.
    public static func margin(observedEarlyAdvance: TimeInterval) -> TimeInterval {
        max(baseMargin, observedEarlyAdvance + 0.6)
    }

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
