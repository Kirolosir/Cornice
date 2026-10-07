import Foundation

/// Keep the last value while refreshing or after an error. A failed refresh shouldn't erase
/// data the app already has.
public enum Loadable<Value: Sendable>: Sendable {
    case idle
    case loading
    case refreshing(Value)
    case loaded(Value)
    case failed(ServiceError, last: Value?)

    public var value: Value? {
        switch self {
        case .idle, .loading: nil
        case .refreshing(let v), .loaded(let v): v
        case .failed(_, let last): last
        }
    }

    public var error: ServiceError? {
        if case .failed(let error, _) = self { return error }
        return nil
    }

    public var isBusy: Bool {
        switch self {
        case .loading, .refreshing: true
        case .idle, .loaded, .failed: false
        }
    }

    /// Transitions into a busy state while preserving any value we already hold.
    public func beginRefresh() -> Loadable<Value> {
        if let value { return .refreshing(value) }
        return .loading
    }

    /// Keep the last good value on failure. Ignore cancellation so an old task cannot
    /// replace a newer result.
    public func resolve(_ result: Result<Value, ServiceError>) -> Loadable<Value> {
        switch result {
        case .success(let value):
            return .loaded(value)
        case .failure(.cancelled):
            if let value { return .loaded(value) }
            return .idle
        case .failure(let error):
            return .failed(error, last: value)
        }
    }
}

extension Loadable: Equatable where Value: Equatable {}
