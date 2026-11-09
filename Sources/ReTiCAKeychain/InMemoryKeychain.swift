import Foundation

/// Thread-safe in-memory `KeychainOps` for tests and previews, shaped like the real Keychain:
/// - an item is keyed by location + account (as `SecItem*`'s primary key); `add` never sets an
///   account (account "") and is an atomic check-and-insert: `.duplicate` if an item already
///   exists at that location with account "" (nothing is overwritten);
/// - a read returns the one match with an opaque persistent reference, or `rejected` when several
///   match (all accounts; a nil access group matches the service in ANY group, as `SecItem*` does)
///   or when any match is synchronizable; `deleteItem` removes exactly the item a prior `found`
///   read named, while `delete(location)` removes EVERY match regardless;
/// - `update` replaces the data of every device-local match in place (same account, same
///   persistent reference), as `SecItemUpdate` does; `.notFound` when there is none, and a
///   synchronizable item is never matched;
/// - failures can be injected per location (`failDelete` also covers `deleteItem` of items at
///   that location), and `dropAdds` makes an add report `.added` while storing nothing.
/// `onBeforeAdd` and `onBeforeRead` run outside the lock, so a hook may call `set` (e.g. another
/// app winning a race).
/// Fidelity note: an unentitled named group returns `notFound` here where the real Keychain
/// returns `-34018` `errSecMissingEntitlement`.
public final class InMemoryKeychain: @unchecked Sendable {
    public typealias Location = IdentityKeychain.Location

    private struct Key: Hashable {
        var location: Location
        var account: String
    }

    private struct Stored {
        var data: Data
        var ref: Data
        var synchronizable: Bool
    }

    private let lock = NSLock()
    private var items: [Key: Stored] = [:]
    private var nextRef = 0
    private var readFailures: [Location: Int32] = [:]
    private var addFailures: [Location: Int32] = [:]
    private var deleteFailures: [Location: Int32] = [:]
    private var updateFailures: [Location: Int32] = [:]
    private var droppedAdds: Set<Location> = []
    private var beforeAdd: (@Sendable (Location) -> Void)?
    private var beforeRead: (@Sendable (Location) -> Void)?
    private var adds = 0

    public init(_ items: [Location: Data] = [:]) {
        for (location, data) in items {
            self.items[Key(location: location, account: "")] = Stored(data: data, ref: makeRef(), synchronizable: false)
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
    /// `synchronizable` models an iCloud-synced copy (something `add` never writes).
    public func set(_ data: Data?, at location: Location, account: String = "", synchronizable: Bool = false) {
        locked {
            let key = Key(location: location, account: account)
            if let data {
                items[key] = Stored(data: data, ref: makeRef(), synchronizable: synchronizable)
            } else {
                items[key] = nil
            }
        }
    }
    public func failRead(at location: Location, status: Int32) { locked { readFailures[location] = status } }
    public func failAdd(at location: Location, status: Int32) { locked { addFailures[location] = status } }
    public func failDelete(at location: Location, status: Int32) { locked { deleteFailures[location] = status } }
    public func failUpdate(at location: Location, status: Int32) { locked { updateFailures[location] = status } }
    public func dropAdds(at location: Location) { _ = locked { droppedAdds.insert(location) } }
    public func clearFailures() {
        locked {
            readFailures = [:]
            addFailures = [:]
            deleteFailures = [:]
            updateFailures = [:]
            droppedAdds = []
        }
    }
    public func onBeforeAdd(_ hook: @escaping @Sendable (Location) -> Void) { locked { beforeAdd = hook } }
    /// Runs outside the lock before every `read`, so a hook may `set` (e.g. another app writing
    /// the shared item between rule 1 and the probe).
    public func onBeforeRead(_ hook: @escaping @Sendable (Location) -> Void) { locked { beforeRead = hook } }
    /// Number of `add` calls (including ones that failed or were duplicates).
    public var addCount: Int { locked { adds } }

    public var ops: KeychainOps {
        KeychainOps(
            read: { [self] location in self.read(location) },
            add: { [self] location, data in self.add(location, data) },
            delete: { [self] location in self.delete(location) },
            deleteItem: { [self] ref in self.deleteItem(ref) },
            update: { [self] location, data in self.update(location, data) }
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
        let hook = locked { beforeRead }
        hook?(location)
        return locked {
            if let status = readFailures[location] { return .failed(status) }
            let matches = matchingKeys(location).compactMap { items[$0] }
            guard !matches.isEmpty else { return .notFound }
            if matches.contains(where: \.synchronizable) { return .rejected(.synchronizableItem) }
            if matches.count > 1 { return .rejected(.multipleItems(count: matches.count)) }
            return .found(matches[0].data, persistentRef: matches[0].ref)
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
            items[key] = Stored(data: data, ref: makeRef(), synchronizable: false)
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

    private func update(_ location: Location, _ data: Data) -> KeychainOps.UpdateResult {
        locked {
            if let status = updateFailures[location] { return .failed(status) }
            let keys = matchingKeys(location).filter { items[$0]?.synchronizable == false }
            guard !keys.isEmpty else { return .notFound }
            for key in keys { items[key]?.data = data }
            return .updated
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
