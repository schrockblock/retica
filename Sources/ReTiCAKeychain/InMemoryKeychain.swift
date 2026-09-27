import Foundation

/// Thread-safe in-memory `KeychainOps` for tests and previews, shaped like the real Keychain:
/// - `add` is an atomic check-and-insert: `.duplicate` if an item already exists at that exact
///   location (nothing is overwritten);
/// - a nil access group on read/delete matches the service in ANY group (as `SecItem*` does);
/// - failures can be injected per location, and `dropAdds` makes an add report `.added` while
///   storing nothing (a copy that can't be verified).
/// `onBeforeAdd` runs outside the lock, so a hook may call `set` (e.g. another app winning a race).
public final class InMemoryKeychain: @unchecked Sendable {
    public typealias Location = IdentityKeychain.Location

    private let lock = NSLock()
    private var items: [Location: Data]
    private var readFailures: [Location: Int32] = [:]
    private var addFailures: [Location: Int32] = [:]
    private var deleteFailures: [Location: Int32] = [:]
    private var droppedAdds: Set<Location> = []
    private var beforeAdd: (@Sendable (Location) -> Void)?
    private var adds = 0

    public init(_ items: [Location: Data] = [:]) {
        self.items = items
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The item stored at exactly this location (no nil-group matching).
    public func item(at location: Location) -> Data? { locked { items[location] } }
    public func set(_ data: Data?, at location: Location) { locked { items[location] = data } }
    public func failRead(at location: Location, status: Int32) { locked { readFailures[location] = status } }
    public func failAdd(at location: Location, status: Int32) { locked { addFailures[location] = status } }
    public func failDelete(at location: Location, status: Int32) { locked { deleteFailures[location] = status } }
    public func dropAdds(at location: Location) { _ = locked { droppedAdds.insert(location) } }
    public func clearFailures() {
        locked {
            readFailures = [:]
            addFailures = [:]
            deleteFailures = [:]
            droppedAdds = []
        }
    }
    public func onBeforeAdd(_ hook: @escaping @Sendable (Location) -> Void) { locked { beforeAdd = hook } }
    /// Number of `add` calls (including ones that failed or were duplicates).
    public var addCount: Int { locked { adds } }

    public var ops: KeychainOps {
        KeychainOps(
            read: { [self] location in self.read(location) },
            add: { [self] location, data in self.add(location, data) },
            delete: { [self] location in self.delete(location) }
        )
    }

    /// Caller holds the lock.
    private func matchingKeys(_ location: Location) -> [Location] {
        if location.accessGroup != nil {
            return items[location] == nil ? [] : [location]
        }
        return items.keys
            .filter { $0.service == location.service }
            .sorted { ($0.accessGroup ?? "") < ($1.accessGroup ?? "") }
    }

    private func read(_ location: Location) -> KeychainOps.ReadResult {
        locked {
            if let status = readFailures[location] { return .failed(status) }
            guard let key = matchingKeys(location).first, let data = items[key] else { return .notFound }
            return .found(data)
        }
    }

    private func add(_ location: Location, _ data: Data) -> KeychainOps.AddResult {
        let hook = locked { beforeAdd }
        hook?(location)
        return locked {
            adds += 1
            if let status = addFailures[location] { return .failed(status) }
            if items[location] != nil { return .duplicate }
            if droppedAdds.contains(location) { return .added }
            items[location] = data
            return .added
        }
    }

    private func delete(_ location: Location) -> KeychainOps.DeleteResult {
        locked {
            if let status = deleteFailures[location] { return .failed(status) }
            let keys = matchingKeys(location)
            guard !keys.isEmpty else { return .notFound }
            for key in keys { items[key] = nil }
            return .deleted
        }
    }
}
