import Foundation
import Security
import Testing
@testable import ReTiCAKeychain

private let grouped = IdentityKeychain.Location(service: "svc", accessGroup: "TEAMID.group")
private let ungrouped = IdentityKeychain.Location(service: "svc", accessGroup: nil)

@Suite("KeychainOps")
struct KeychainOpsTests {
    @Test func liveQueriesAreScopedAndNeverSynchronizable() {
        let read = KeychainOps.readQuery(grouped)
        #expect(read[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(read[kSecAttrService as String] as? String == "svc")
        #expect(read[kSecAttrAccessGroup as String] as? String == "TEAMID.group")
        #expect(read[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(read[kSecReturnData as String] as? Bool == true)
        #expect(read[kSecReturnPersistentRef as String] as? Bool == true)
        #expect(read[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)

        let add = KeychainOps.addAttributes(grouped, data: Data([1, 2, 3]))
        #expect(add[kSecAttrAccessGroup as String] as? String == "TEAMID.group")
        #expect(add[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(add[kSecValueData as String] as? Data == Data([1, 2, 3]))
        #expect(add[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)

        let delete = KeychainOps.deleteQuery(grouped)
        #expect(delete[kSecAttrAccessGroup as String] as? String == "TEAMID.group")
        #expect(delete[kSecReturnData as String] == nil)

        // Deleting by persistent reference addresses exactly one item: no service/group/account.
        let deleteItem = KeychainOps.deleteItemQuery(Data([7]))
        #expect(deleteItem[kSecValuePersistentRef as String] as? Data == Data([7]))
        #expect(deleteItem[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(deleteItem[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(deleteItem[kSecAttrService as String] == nil)
        #expect(deleteItem[kSecAttrAccessGroup as String] == nil)

        for query in [read, add, delete, deleteItem] {
            #expect(query[kSecAttrSynchronizable as String] == nil)
        }
        #expect(KeychainOps.readQuery(ungrouped)[kSecAttrAccessGroup as String] == nil)
    }

    @Test func liveStatusMapping() {
        #expect(KeychainOps.mapRead(status: errSecSuccess, data: Data([9]), persistentRef: Data([5]))
                == .found(Data([9]), persistentRef: Data([5])))
        // success without data or ref is NOT first-run: treating it as absent would mint (rotation).
        #expect(KeychainOps.mapRead(status: errSecSuccess, data: nil, persistentRef: Data([5])) == .failed(errSecSuccess))
        #expect(KeychainOps.mapRead(status: errSecSuccess, data: Data([9]), persistentRef: nil) == .failed(errSecSuccess))
        #expect(KeychainOps.mapRead(status: errSecItemNotFound, data: nil, persistentRef: nil) == .notFound)
        #expect(KeychainOps.mapRead(status: errSecInteractionNotAllowed, data: nil, persistentRef: nil)
                == .failed(errSecInteractionNotAllowed))
        #expect(KeychainOps.mapAdd(status: errSecSuccess) == .added)
        #expect(KeychainOps.mapAdd(status: errSecDuplicateItem) == .duplicate)
        #expect(KeychainOps.mapAdd(status: errSecMissingEntitlement) == .failed(errSecMissingEntitlement))
        #expect(KeychainOps.mapDelete(status: errSecSuccess) == .deleted)
        #expect(KeychainOps.mapDelete(status: errSecItemNotFound) == .notFound)
        #expect(KeychainOps.mapDelete(status: errSecInteractionNotAllowed) == .failed(errSecInteractionNotAllowed))
    }

    @Test func inMemoryAddIsAddOnly() {
        let keychain = InMemoryKeychain()
        #expect(keychain.ops.add(grouped, Data([1])) == .added)
        #expect(keychain.ops.add(grouped, Data([2])) == .duplicate)
        #expect(keychain.item(at: grouped) == Data([1]))
        #expect(keychain.addCount == 2)
    }

    @Test func inMemoryNilGroupMatchesAnyGroupOnReadAndDelete() {
        let keychain = InMemoryKeychain([grouped: Data([1])])
        #expect(keychain.ops.read(ungrouped).data == Data([1]))
        #expect(keychain.ops.read(IdentityKeychain.Location(service: "svc", accessGroup: "OTHER.group")) == .notFound)
        #expect(keychain.ops.delete(ungrouped) == .deleted)
        #expect(keychain.item(at: grouped) == nil)
        #expect(keychain.ops.delete(ungrouped) == .notFound)
    }

    @Test func inMemoryInjectedFailuresAndDroppedAdds() {
        let keychain = InMemoryKeychain([grouped: Data([1])])
        keychain.failRead(at: grouped, status: errSecInteractionNotAllowed)
        #expect(keychain.ops.read(grouped) == .failed(errSecInteractionNotAllowed))
        keychain.failDelete(at: grouped, status: errSecInteractionNotAllowed)
        #expect(keychain.ops.delete(grouped) == .failed(errSecInteractionNotAllowed))
        keychain.clearFailures()
        #expect(keychain.ops.read(grouped).data == Data([1]))

        let other = IdentityKeychain.Location(service: "other", accessGroup: "TEAMID.group")
        keychain.failAdd(at: other, status: errSecMissingEntitlement)
        #expect(keychain.ops.add(other, Data([2])) == .failed(errSecMissingEntitlement))
        keychain.clearFailures()
        keychain.dropAdds(at: other)
        #expect(keychain.ops.add(other, Data([2])) == .added)
        #expect(keychain.item(at: other) == nil)
    }

    /// Items differing only by account share a location query; `deleteItem` removes just the one read.
    @Test func inMemoryDeleteItemRemovesOnlyTheItemRead() {
        let keychain = InMemoryKeychain()
        keychain.set(Data([1]), at: grouped)
        keychain.set(Data([2]), at: grouped, account: "other")
        guard case let .found(data, ref) = keychain.ops.read(grouped) else {
            Issue.record("expected .found")
            return
        }
        #expect(data == Data([1]))
        #expect(keychain.ops.deleteItem(ref) == .deleted)
        #expect(keychain.item(at: grouped) == nil)
        #expect(keychain.item(at: grouped, account: "other") == Data([2]))
        #expect(keychain.ops.deleteItem(ref) == .notFound)
        // The query delete, by contrast, removes every account.
        keychain.set(Data([1]), at: grouped)
        #expect(keychain.ops.delete(grouped) == .deleted)
        #expect(keychain.item(at: grouped, account: "other") == nil)
    }
}
