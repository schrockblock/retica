import Foundation

/// Thread-safe in-memory `KeychainOps` for tests and previews, shaped like the real Keychain:
/// - an item is keyed by location + account (as `SecItem*`'s primary key); `add` never sets an
///   account (account "") and is an atomic check-and-insert: `.duplicate` if an item already
///   exists at that location with account "" (nothing is overwritten);
/// - a read returns one match (lowest group, then account, first) with an opaque persistent
///   reference; `deleteItem` removes exactly that item, while `delete(location)` removes EVERY
///   match (all accounts; a nil access group matches the service in ANY group, as `SecItem*` does);
/// - failures can be injected per location (`failDelete` also covers `deleteItem` of items at
///   that location), and `dropAdds` makes an add report `.added` while storing nothing.
/// `onBeforeAdd` runs outside the lock, so a hook may call `set` (e.g. another app winning a race).
public final class InMemoryKeychain: @unchecked Sendable {
    public typealias Location = IdentityKeychain.Location

    private struct Key: Hashable {
        var location: Location
        var account: String
    }

    private struct Stored {
        var data: Data
        var ref: Data
    }

    private let lock = NSLock()
    private var items: [Key: Stored] = [:]
    private var nextRef = 0
    private var readFailures: [Location: Int32] = [:]
    private var addFailures: [Location: Int32] = [:]
    private var deleteFailures: [Location: Int32] = [:]
    private var droppedAdds: Set<Location> = []
    private var beforeAdd: (@Sendable (Location) -> Void)?
    private var adds = 0

    public init(_ items: [Location: Data] = [:]) {
        for (location, data) in items {
            self.items[Key(location: location, account: "")] = Stored(data: data, ref: makeRef())
        }
    }

    /// Caller holds the lock (or is `init`).
    private func makeRef() -> Data {
        nextRef += 1
        return Data("inmemory-ref-\(nextRef)".utf8)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The item stored at exactly this location and account (no nil-group matching).
    public func item(at location: Location, account: String = "") -> Data? {
        locked { items[Key(location: location, account: account)]?.data }
    }
    /// Plants (or with nil, removes) an item at exactly this location and account.
    public func set(_ data: Data?, at location: Location, account: String = "") {
        locked {
            let key = Key(location: location, account: account)
            if let data {
                items[key] = Stored(data: data, ref: makeRef())
            } else {
                items[key] = nil
            }
        }
    }
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
            delete: { [self] location in self.delete(location) },
            deleteItem: { [self] ref in self.deleteItem(ref) }
        )
    }

    /// Caller holds the lock. Every item the location's query matches, in a stable order.
    private func matchingKeys(_ location: Location) -> [Key] {
        items.keys
            .filter { key in
                key.location.service == location.service
                    && (location.accessGroup == nil || key.location.accessGroup == location.accessGroup)
            }
            .sorted {
                ($0.location.accessGroup ?? "", $0.account) < ($1.location.accessGroup ?? "", $1.account)
            }
    }

    private func read(_ location: Location) -> KeychainOps.ReadResult {
        locked {
            if let status = readFailures[location] { return .failed(status) }
            guard let key = matchingKeys(location).first, let stored = items[key] else { return .notFound }
            return .found(stored.data, persistentRef: stored.ref)
        }
    }

    /// Group-less adds are unsupported: on device, a group-less `SecItemAdd` lands in the app's
    /// default (first entitled) access group, which this in-memory double has no way to model.
    private func add(_ location: Location, _ data: Data) -> KeychainOps.AddResult {
        precondition(location.accessGroup != nil, "InMemoryKeychain.add requires a location with an access group")
        let hook = locked { beforeAdd }
        hook?(location)
        return locked {
            adds += 1
            if let status = addFailures[location] { return .failed(status) }
            let key = Key(location: location, account: "")
            if items[key] != nil { return .duplicate }
            if droppedAdds.contains(location) { return .added }
            items[key] = Stored(data: data, ref: makeRef())
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

    private func deleteItem(_ ref: Data) -> KeychainOps.DeleteResult {
        locked {
            guard let key = items.first(where: { $0.value.ref == ref })?.key else { return .notFound }
            if let status = deleteFailures[key.location] { return .failed(status) }
            items[key] = nil
            return .deleted
        }
    }
}
