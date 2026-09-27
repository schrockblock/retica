import Foundation
import Security

/// The three Keychain primitives `IdentityKeychain` needs, injectable for tests.
/// The live value is logic-free apart from pure OSStatus mapping; every decision lives in
/// `IdentityKeychain.loadOrCreate`.
public struct KeychainOps: Sendable {
    public enum ReadResult: Sendable, Equatable { case found(Data), notFound, failed(Int32) }
    public enum AddResult: Sendable, Equatable { case added, duplicate, failed(Int32) }
    public enum DeleteResult: Sendable, Equatable { case deleted, notFound, failed(Int32) }

    public var read: @Sendable (IdentityKeychain.Location) -> ReadResult
    public var add: @Sendable (IdentityKeychain.Location, Data) -> AddResult
    public var delete: @Sendable (IdentityKeychain.Location) -> DeleteResult

    public init(
        read: @escaping @Sendable (IdentityKeychain.Location) -> ReadResult,
        add: @escaping @Sendable (IdentityKeychain.Location, Data) -> AddResult,
        delete: @escaping @Sendable (IdentityKeychain.Location) -> DeleteResult
    ) {
        self.read = read
        self.add = add
        self.delete = delete
    }
}

extension KeychainOps {
    /// Generic-password items over `SecItem*`. Items are device-local: `kSecAttrSynchronizable`
    /// is never set (a Reticulum identity on two devices splits direct LXMF delivery), and
    /// accessibility is `kSecAttrAccessibleAfterFirstUnlock` (readable by background launches
    /// after the first unlock; iOS prewarm BEFORE first unlock fails with
    /// errSecInteractionNotAllowed, which callers must treat as "not now", never "absent").
    public static let live = KeychainOps(
        read: { location in
            var result: AnyObject?
            let status = SecItemCopyMatching(readQuery(location) as CFDictionary, &result)
            return mapRead(status: status, data: result as? Data)
        },
        add: { location, data in
            mapAdd(status: SecItemAdd(addAttributes(location, data: data) as CFDictionary, nil))
        },
        delete: { location in
            mapDelete(status: SecItemDelete(deleteQuery(location) as CFDictionary))
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

    static func readQuery(_ location: IdentityKeychain.Location) -> [String: Any] {
        var query = baseQuery(location)
        query[kSecReturnData as String] = true
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

    /// success+data → found; success WITHOUT data → failed (never "absent": that would mint);
    /// itemNotFound → notFound; anything else → failed(status).
    static func mapRead(status: OSStatus, data: Data?) -> ReadResult {
        switch status {
        case errSecSuccess:
            guard let data else { return .failed(errSecSuccess) }
            return .found(data)
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
