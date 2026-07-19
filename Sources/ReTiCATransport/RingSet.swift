import Foundation

/// A bounded, insertion-ordered set. `insert` returns whether the item was new; once the
/// capacity is exceeded the oldest item is evicted. Used to suppress duplicate packets.
public struct RingSet: Equatable {
    private var items: Set<Data> = []
    private var order: [Data] = []
    private let capacity: Int

    public init(capacity: Int = 1000) { self.capacity = capacity }

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
