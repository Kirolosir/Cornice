import Foundation

/// Shared number helpers, kept here so each file doesn't need its own copy.
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
