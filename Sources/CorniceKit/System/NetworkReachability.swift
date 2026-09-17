import Foundation
import Network

/// Whether the Mac has a usable route to the internet.
///
/// `NWPathMonitor` rather than a reachability ping: it is the framework Apple
/// provides for exactly this, it reports the answer the networking stack already
/// knows, and it costs nothing when nothing is changing. Polling a host would
/// mean sending traffic to somebody else's server every few seconds to learn
/// something the kernel could have told us.
public final class NetworkReachability: @unchecked Sendable {

    public typealias ChangeHandler = @Sendable (Bool) -> Void

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.cornice.network", qos: .utility)
    private let lock = NSLock()
    private var handler: ChangeHandler?
    private var lastSatisfied: Bool?
    private var isListening = false

    public init() {}

    /// The most recent answer, or `nil` before the first path update arrives.
    public var isOnline: Bool? {
        lock.lock(); defer { lock.unlock() }
        return lastSatisfied
    }

    public func start(onChange: @escaping ChangeHandler) {
        lock.lock()
        guard !isListening else { lock.unlock(); return }
        isListening = true
        handler = onChange
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied

            self.lock.lock()
            // The first update is the current state, not a change. Reporting it
            // would raise a "no internet" HUD at launch on a machine that has
            // simply not finished associating with Wi-Fi yet.
            let previous = self.lastSatisfied
            self.lastSatisfied = satisfied
            let handler = self.handler
            self.lock.unlock()

            guard let previous, previous != satisfied else { return }
            handler?(satisfied)
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        guard isListening else { lock.unlock(); return }
        isListening = false
        handler = nil
        lock.unlock()
        monitor.cancel()
    }
}
