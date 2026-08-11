import Foundation

/// A bounded, insertion-ordered set. `insert` returns whether the item was new; once the
/// capacity is exceeded the oldest item is evicted. Used to suppress duplicate packets.
public struct RingSet: Equatable {
    private var items: Set<Data> = []
    private var order: [Data] = []
    private let capacity: Int

    /// No default: every ring must state its size against the reference constant it mirrors.
    /// A defaulted capacity is how `seenPacketHashes` silently ran at 1000 instead of 262144.
    public init(capacity: Int) { self.capacity = capacity }

    @discardableResult
    public mutating func insert(_ item: Data) -> Bool {
        guard !items.contains(item) else { return false }
        items.insert(item)
        order.append(item)
        if order.count > capacity {
            let evicted = order.removeFirst()
            items.remove(evicted)
        }
        return true
    }

    public func contains(_ item: Data) -> Bool { items.contains(item) }
}
