import Foundation
import Security

/// The Keychain primitives `IdentityKeychain` needs, injectable for tests.
/// The live value is logic-free apart from pure result mapping (status, the synchronizable check,
/// the item count); every decision lives in `IdentityKeychain` (`load`, `loadOrCreate`,
/// `importIdentity`).
public struct KeychainOps: Sendable {
    public enum ReadRejection: Sendable, Equatable {
        /// More than one item matched the query (two accounts at one location, or the group-less
        /// probe found the service in several groups). One is never picked.
        case multipleItems(count: Int)
        /// At least one matching item is `kSecAttrSynchronizable`: an iCloud-synced identity would
        /// split direct LXMF delivery across devices, so it is refused even when it is the only one.
        case synchronizableItem
    }

    public enum ReadResult: Sendable, Equatable {
        /// Exactly one device-local item: its bytes and its persistent reference, which addresses
        /// exactly that item (whatever its account) for `deleteItem`.
        case found(Data, persistentRef: Data)
        case notFound
        case failed(Int32)
        /// Items exist but the read refuses to pick one (see `ReadRejection`). Callers fail closed.
        case rejected(ReadRejection)

        /// The item's bytes when found.
        public var data: Data? {
            if case let .found(data, _) = self { return data }
            return nil
        }
    }
    public enum AddResult: Sendable, Equatable { case added, duplicate, failed(Int32) }
    public enum DeleteResult: Sendable, Equatable { case deleted, notFound, failed(Int32) }
    public enum UpdateResult: Sendable, Equatable { case updated, notFound, failed(Int32) }

    public var read: @Sendable (IdentityKeychain.Location) -> ReadResult
    public var add: @Sendable (IdentityKeychain.Location, Data) -> AddResult
    /// Deletes EVERY item matching the location's query (all accounts; with a nil group, all
    /// groups). `IdentityKeychain` never uses it — it deletes only via `deleteItem`. Kept for
    /// test cleanup of test-owned services.
    public var delete: @Sendable (IdentityKeychain.Location) -> DeleteResult
    /// Deletes exactly the one item a `read` returned, by its persistent reference.
    public var deleteItem: @Sendable (_ persistentRef: Data) -> DeleteResult
    /// Replaces the data of the device-local items matching the location's query, in place
    /// (`SecItemUpdate`): there is no moment when the item is missing, as there is between a
    /// delete and an add. `.notFound` when no device-local item matches; a synchronizable item is
    /// never matched. `IdentityKeychain` never uses it. Its own items are add-only.
    public var update: @Sendable (IdentityKeychain.Location, Data) -> UpdateResult

    /// `update` defaults to failing with `errSecUnimplemented`, so a hand-built `KeychainOps` that
    /// predates it still compiles, and a caller that needs it sees a failure, never a silent no-op.
    public init(
        read: @escaping @Sendable (IdentityKeychain.Location) -> ReadResult,
        add: @escaping @Sendable (IdentityKeychain.Location, Data) -> AddResult,
        delete: @escaping @Sendable (IdentityKeychain.Location) -> DeleteResult,
        deleteItem: @escaping @Sendable (_ persistentRef: Data) -> DeleteResult,
        update: @escaping @Sendable (IdentityKeychain.Location, Data) -> UpdateResult = { _, _ in
            .failed(errSecUnimplemented)
        }
    ) {
        self.read = read
        self.add = add
        self.delete = delete
        self.deleteItem = deleteItem
        self.update = update
    }
}

extension KeychainOps {
    /// Generic-password items over `SecItem*`. Items are device-local: `kSecAttrSynchronizable`
    /// is never set (a Reticulum identity on two devices splits direct LXMF delivery), and
    /// accessibility is `kSecAttrAccessibleAfterFirstUnlock` (readable by background launches
    /// after the first unlock; iOS prewarm BEFORE first unlock fails with
    /// errSecInteractionNotAllowed, which callers must treat as "not now", never "absent").
    /// Queries address items by class + service (+ access group) only — no `kSecAttrAccount` is
    /// ever set. Writes and deletes never set `kSecAttrSynchronizable`; every adopting app must
    /// write the shared item with these exact same attributes, or the copies won't collide/dedupe.
    /// Reads see EVERY matching item, synced or not, and refuse to pick one when there is more
    /// than one or when any is iCloud-synchronizable — callers fail closed instead of silently
    /// choosing an item. Because a query ignores the account, a single-item read returns a
    /// persistent reference and `IdentityKeychain` deletes by that reference, never by query.
    public static let live = KeychainOps(
        read: { location in
            var result: AnyObject?
            let status = SecItemCopyMatching(readQuery(location) as CFDictionary, &result)
            return mapRead(status: status, items: result as? [[String: Any]])
        },
        add: { location, data in
            mapAdd(status: SecItemAdd(addAttributes(location, data: data) as CFDictionary, nil))
        },
        delete: { location in
            mapDelete(status: SecItemDelete(deleteQuery(location) as CFDictionary))
        },
        deleteItem: { persistentRef in
            mapDelete(status: SecItemDelete(deleteItemQuery(persistentRef) as CFDictionary))
        },
        update: { location, data in
            mapUpdate(status: SecItemUpdate(updateQuery(location) as CFDictionary,
                                            updateAttributes(data: data) as CFDictionary))
        }
    )

    /// Class + service (+ access group when given). `kSecUseDataProtectionKeychain` makes
    /// macOS / Mac Catalyst use the iOS-style keychain, where access groups work; on iOS it is
    /// the only keychain anyway.
    static func baseQuery(_ location: IdentityKeychain.Location) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: location.service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let group = location.accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    /// Every item the location matches, synced or not, with attributes, data and persistent ref
    /// (the result is then an array of attribute dictionaries). Match-limit-all and
    /// synchronizable-any make duplicates and iCloud copies visible instead of silently picking one.
    static func readQuery(_ location: IdentityKeychain.Location) -> [String: Any] {
        var query = baseQuery(location)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecReturnPersistentRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        return query
    }

    static func addAttributes(_ location: IdentityKeychain.Location, data: Data) -> [String: Any] {
        var attributes = baseQuery(location)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return attributes
    }

    static func deleteQuery(_ location: IdentityKeychain.Location) -> [String: Any] {
        baseQuery(location)
    }

    /// Class + service (+ access group). No synchronizable attribute, so `SecItemUpdate` matches
    /// only device-local items (its default) and never rewrites an iCloud copy.
    static func updateQuery(_ location: IdentityKeychain.Location) -> [String: Any] {
        baseQuery(location)
    }

    /// Only the data changes; accessibility and every other attribute stay as the add set them.
    static func updateAttributes(data: Data) -> [String: Any] {
        [kSecValueData as String: data]
    }

    /// Exactly one item, by persistent reference — no service/group/account matching.
    static func deleteItemQuery(_ persistentRef: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: persistentRef,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// itemNotFound → notFound; any other non-success → failed(status); success → a synced item
    /// anywhere in the result → rejected(.synchronizableItem) (checked first: one is enough);
    /// more than one item → rejected(.multipleItems); exactly one with data and ref → found;
    /// success with no items or an item missing data/ref → failed(errSecSuccess) (never "absent":
    /// that would mint).
    static func mapRead(status: OSStatus, items: [[String: Any]]?) -> ReadResult {
        switch status {
        case errSecItemNotFound:
            return .notFound
        case errSecSuccess:
            guard let items, !items.isEmpty else { return .failed(errSecSuccess) }
            if items.contains(where: isSynchronizable) { return .rejected(.synchronizableItem) }
            if items.count > 1 { return .rejected(.multipleItems(count: items.count)) }
            guard let data = items[0][kSecValueData as String] as? Data,
                  let persistentRef = items[0][kSecValuePersistentRef as String] as? Data
            else { return .failed(errSecSuccess) }
            return .found(data, persistentRef: persistentRef)
        default:
            return .failed(status)
        }
    }

    /// `kSecAttrSynchronizable` comes back as a CFBoolean / NSNumber on synced items and is absent
    /// (or 0) on device-local ones.
    static func isSynchronizable(_ attributes: [String: Any]) -> Bool {
        guard let value = attributes[kSecAttrSynchronizable as String] else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        if let flag = value as? Bool { return flag }
        // An attribute of an unrecognised type is not evidence of syncing: Security returns CFBoolean/NSNumber, our own writes never set the attribute, and refusing here would lock every adopter out on an SDK type change (a total outage against a theoretical risk). Ruled fail-open on purpose.
        return false
    }

    static func mapAdd(status: OSStatus) -> AddResult {
        switch status {
        case errSecSuccess: return .added
        case errSecDuplicateItem: return .duplicate
        default: return .failed(status)
        }
    }

    static func mapDelete(status: OSStatus) -> DeleteResult {
        switch status {
        case errSecSuccess: return .deleted
        case errSecItemNotFound: return .notFound
        default: return .failed(status)
        }
    }

    static func mapUpdate(status: OSStatus) -> UpdateResult {
        switch status {
        case errSecSuccess: return .updated
        case errSecItemNotFound: return .notFound
        default: return .failed(status)
        }
    }
}
