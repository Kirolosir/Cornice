import Foundation

/// The lifecycle of a value that is fetched asynchronously and may fail.
///
/// `.refreshing` deliberately carries the previous value so the UI can keep
/// showing real data (dimmed) while an update is in flight, instead of
/// flashing a spinner every refresh cycle. `.failed` does the same: a failed
/// refresh should not erase a good last-known state.
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

    /// Folds a service result into the next state, preserving the last good
    /// value on failure and ignoring cancellation entirely (a cancelled task
    /// was superseded, so its result must not overwrite the newer one).
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
