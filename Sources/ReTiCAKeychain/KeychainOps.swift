import Foundation
import Security

/// The Keychain primitives `IdentityKeychain` needs, injectable for tests.
/// The live value is logic-free apart from pure OSStatus mapping; every decision lives in
/// `IdentityKeychain` (`load`, `loadOrCreate`, `importIdentity`).
public struct KeychainOps: Sendable {
    public enum ReadResult: Sendable, Equatable {
        /// One matching item: its bytes and its persistent reference, which addresses exactly
        /// that item (whatever its account) for `deleteItem`.
        case found(Data, persistentRef: Data)
        case notFound
        case failed(Int32)

        /// The item's bytes when found.
        public var data: Data? {
            if case let .found(data, _) = self { return data }
            return nil
        }
    }
    public enum AddResult: Sendable, Equatable { case added, duplicate, failed(Int32) }
    public enum DeleteResult: Sendable, Equatable { case deleted, notFound, failed(Int32) }

    public var read: @Sendable (IdentityKeychain.Location) -> ReadResult
    public var add: @Sendable (IdentityKeychain.Location, Data) -> AddResult
    /// Deletes EVERY item matching the location's query (all accounts; with a nil group, all
    /// groups). `IdentityKeychain` never uses it — it deletes only via `deleteItem`. Kept for
    /// test cleanup of test-owned services.
    public var delete: @Sendable (IdentityKeychain.Location) -> DeleteResult
    /// Deletes exactly the one item a `read` returned, by its persistent reference.
    public var deleteItem: @Sendable (_ persistentRef: Data) -> DeleteResult

    public init(
        read: @escaping @Sendable (IdentityKeychain.Location) -> ReadResult,
        add: @escaping @Sendable (IdentityKeychain.Location, Data) -> AddResult,
        delete: @escaping @Sendable (IdentityKeychain.Location) -> DeleteResult,
        deleteItem: @escaping @Sendable (_ persistentRef: Data) -> DeleteResult
    ) {
        self.read = read
        self.add = add
        self.delete = delete
        self.deleteItem = deleteItem
    }
}

extension KeychainOps {
    /// Generic-password items over `SecItem*`. Items are device-local: `kSecAttrSynchronizable`
    /// is never set (a Reticulum identity on two devices splits direct LXMF delivery), and
    /// accessibility is `kSecAttrAccessibleAfterFirstUnlock` (readable by background launches
    /// after the first unlock; iOS prewarm BEFORE first unlock fails with
    /// errSecInteractionNotAllowed, which callers must treat as "not now", never "absent").
    /// Queries address items by class + service (+ access group) only — no `kSecAttrAccount` is
    /// ever set — and never set `kSecAttrSynchronizable`; every adopting app must write the
    /// shared item with these exact same attributes, or the copies won't collide/dedupe.
    /// Because a query ignores the account, reads return a persistent reference and
    /// `IdentityKeychain` deletes by that reference, never by query.
    public static let live = KeychainOps(
        read: { location in
            var result: AnyObject?
            let status = SecItemCopyMatching(readQuery(location) as CFDictionary, &result)
            let attributes = result as? [String: Any]
            return mapRead(
                status: status,
                data: attributes?[kSecValueData as String] as? Data,
                persistentRef: attributes?[kSecValuePersistentRef as String] as? Data
            )
        },
        add: { location, data in
            mapAdd(status: SecItemAdd(addAttributes(location, data: data) as CFDictionary, nil))
        },
        delete: { location in
            mapDelete(status: SecItemDelete(deleteQuery(location) as CFDictionary))
        },
        deleteItem: { persistentRef in
            mapDelete(status: SecItemDelete(deleteItemQuery(persistentRef) as CFDictionary))
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

    /// One item's data AND persistent reference (the result is then an attributes dictionary).
    static func readQuery(_ location: IdentityKeychain.Location) -> [String: Any] {
        var query = baseQuery(location)
        query[kSecReturnData as String] = true
        query[kSecReturnPersistentRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
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

    /// Exactly one item, by persistent reference — no service/group/account matching.
    static func deleteItemQuery(_ persistentRef: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: persistentRef,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// success + data + ref → found; success missing either → failed (never "absent": that
    /// would mint); itemNotFound → notFound; anything else → failed(status).
    static func mapRead(status: OSStatus, data: Data?, persistentRef: Data?) -> ReadResult {
        switch status {
        case errSecSuccess:
            guard let data, let persistentRef else { return .failed(errSecSuccess) }
            return .found(data, persistentRef: persistentRef)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(status)
        }
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
}
