import Observation

/// The one per-frame counter the whole interface shares.
///
/// It exists as an observable object rather than as `@State` on the root view
/// for a reason that cost 13% of a core to find. When the counter lived on the
/// root, every increment invalidated the root's body, and SwiftUI re-laid out
/// the entire tree (all four surface states, the module that is showing and
/// the two that are not), sixty times a second, to move one scrubber.
///
/// Here, only the handful of views that actually read `tick` depend on it. The
/// root never touches it, so the root never re-lays-out.
@Observable
final class FrameClock {
    private(set) var tick: Int = 0

    func advance() { tick &+= 1 }
}
