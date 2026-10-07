import Observation

/// Only views that read this clock redraw each frame. Keeping the tick off RootView avoids
/// rebuilding the whole panel to move the scrubber.
@Observable
final class FrameClock {
    private(set) var tick: Int = 0

    func advance() { tick &+= 1 }
}
