import Foundation

/// Shared numeric helpers.
///
/// These live in one file rather than being redeclared beside each use: three
/// copies of `clamped(to:)` in the same module is a compile error, and the
/// version that survives is otherwise a matter of which file the compiler saw
/// first.
extension Comparable {
    /// Constrains a value to a range.
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Array {
    /// Removes duplicates by a key, keeping the first occurrence and the order.
    public func reduplicated<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}
