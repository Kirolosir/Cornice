import Foundation
import Network

/// Watch the network route with NWPathMonitor instead of repeatedly pinging a server.
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
            // Use the first update to set the state. Only show a network notice for later
            // changes.
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
