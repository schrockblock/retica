import Foundation
import Security
import Testing
@testable import ReTiCAKeychain

private let grouped = IdentityKeychain.Location(service: "svc", accessGroup: "TEAMID.group")
private let ungrouped = IdentityKeychain.Location(service: "svc", accessGroup: nil)

@Suite("KeychainOps")
struct KeychainOpsTests {
    @Test func liveQueriesAreScopedAndSeeEveryItem() {
        let read = KeychainOps.readQuery(grouped)
        #expect(read[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(read[kSecAttrService as String] as? String == "svc")
        #expect(read[kSecAttrAccessGroup as String] as? String == "TEAMID.group")
        #expect(read[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(read[kSecReturnData as String] as? Bool == true)
        #expect(read[kSecReturnAttributes as String] as? Bool == true)
        #expect(read[kSecReturnPersistentRef as String] as? Bool == true)
        // Every item, synced or not, so duplicates and iCloud copies are visible (never silently picked).
        #expect(read[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String)
        #expect(read[kSecAttrSynchronizable as String] as? String == kSecAttrSynchronizableAny as String)

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

        // An update addresses the location (class, service, group) and changes only the data.
        let update = KeychainOps.updateQuery(grouped)
        #expect(update[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(update[kSecAttrService as String] as? String == "svc")
        #expect(update[kSecAttrAccessGroup as String] as? String == "TEAMID.group")
        #expect(update[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(update[kSecReturnData as String] == nil)
        let changes = KeychainOps.updateAttributes(data: Data([4]))
        #expect(changes.count == 1)
        #expect(changes[kSecValueData as String] as? Data == Data([4]))

        // Writes and deletes never touch the synchronizable attribute (items stay device-local).
        // Absent from the update query, SecItemUpdate matches only device-local items.
        for query in [add, delete, deleteItem, update] {
            #expect(query[kSecAttrSynchronizable as String] == nil)
        }
        #expect(KeychainOps.readQuery(ungrouped)[kSecAttrAccessGroup as String] == nil)
    }

    private func item(_ data: Data?, ref: Data?, synchronizable: Any? = nil) -> [String: Any] {
        var attributes: [String: Any] = [:]
        if let data { attributes[kSecValueData as String] = data }
        if let ref { attributes[kSecValuePersistentRef as String] = ref }
        if let synchronizable { attributes[kSecAttrSynchronizable as String] = synchronizable }
        return attributes
    }

    @Test func liveStatusMapping() {
        let one = item(Data([9]), ref: Data([5]))
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: [one]) == .found(Data([9]), persistentRef: Data([5])))
        // An item that never carried the attribute is device-local.
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: [item(Data([9]), ref: Data([5]), synchronizable: false)])
                == .found(Data([9]), persistentRef: Data([5])))
        // success without data or ref is NOT first-run: treating it as absent would mint (rotation).
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: [item(nil, ref: Data([5]))]) == .failed(errSecSuccess))
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: [item(Data([9]), ref: nil)]) == .failed(errSecSuccess))
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: nil) == .failed(errSecSuccess))
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: []) == .failed(errSecSuccess))
        #expect(KeychainOps.mapRead(status: errSecItemNotFound, items: nil) == .notFound)
        #expect(KeychainOps.mapRead(status: errSecInteractionNotAllowed, items: nil) == .failed(errSecInteractionNotAllowed))
        // Two items: never pick one.
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: [one, item(Data([8]), ref: Data([6]))])
                == .rejected(.multipleItems(count: 2)))
        // A synced item is refused even when it is the only one, and before counting.
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: [item(Data([9]), ref: Data([5]), synchronizable: true)])
                == .rejected(.synchronizableItem))
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: [one, item(Data([8]), ref: Data([6]), synchronizable: NSNumber(value: 1))])
                == .rejected(.synchronizableItem))
        #expect(KeychainOps.isSynchronizable([kSecAttrSynchronizable as String: NSNumber(value: 1)]))
        #expect(KeychainOps.isSynchronizable([kSecAttrSynchronizable as String: kCFBooleanTrue as Any]))
        #expect(!KeychainOps.isSynchronizable([kSecAttrSynchronizable as String: NSNumber(value: 0)]))
        #expect(!KeychainOps.isSynchronizable([:]))

        #expect(KeychainOps.mapAdd(status: errSecSuccess) == .added)
        #expect(KeychainOps.mapAdd(status: errSecDuplicateItem) == .duplicate)
        #expect(KeychainOps.mapAdd(status: errSecMissingEntitlement) == .failed(errSecMissingEntitlement))
        #expect(KeychainOps.mapDelete(status: errSecSuccess) == .deleted)
        #expect(KeychainOps.mapDelete(status: errSecItemNotFound) == .notFound)
        #expect(KeychainOps.mapDelete(status: errSecInteractionNotAllowed) == .failed(errSecInteractionNotAllowed))
        #expect(KeychainOps.mapUpdate(status: errSecSuccess) == .updated)
        #expect(KeychainOps.mapUpdate(status: errSecItemNotFound) == .notFound)
        #expect(KeychainOps.mapUpdate(status: errSecInteractionNotAllowed) == .failed(errSecInteractionNotAllowed))
    }

    /// A hand-built `KeychainOps` without `update` fails loudly, never silently succeeds.
    @Test func updateDefaultsToUnimplemented() {
        let ops = KeychainOps(read: { _ in .notFound }, add: { _, _ in .added },
                              delete: { _ in .notFound }, deleteItem: { _ in .notFound })
        #expect(ops.update(grouped, Data([1])) == .failed(errSecUnimplemented))
    }

    /// `update` replaces the data in place (same item, same persistent reference), reports
    /// `.notFound` with no item, never matches a synchronizable copy, and honours `failUpdate`.
    @Test func inMemoryUpdateReplacesInPlace() {
        let keychain = InMemoryKeychain()
        #expect(keychain.ops.update(grouped, Data([1])) == .notFound)
        #expect(keychain.item(at: grouped) == nil, "update never creates an item")

        keychain.set(Data([1]), at: grouped)
        guard case let .found(_, ref) = keychain.ops.read(grouped) else {
            Issue.record("expected .found")
            return
        }
        #expect(keychain.ops.update(grouped, Data([2])) == .updated)
        #expect(keychain.ops.read(grouped) == .found(Data([2]), persistentRef: ref))
        #expect(keychain.addCount == 0)

        let synced = IdentityKeychain.Location(service: "synced", accessGroup: "TEAMID.group")
        keychain.set(Data([3]), at: synced, synchronizable: true)
        #expect(keychain.ops.update(synced, Data([4])) == .notFound)
        #expect(keychain.item(at: synced) == Data([3]))

        keychain.failUpdate(at: grouped, status: errSecInteractionNotAllowed)
        #expect(keychain.ops.update(grouped, Data([5])) == .failed(errSecInteractionNotAllowed))
        #expect(keychain.item(at: grouped) == Data([2]))
        keychain.clearFailures()
        #expect(keychain.ops.update(grouped, Data([5])) == .updated)
        #expect(keychain.item(at: grouped) == Data([5]))
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

    @Test func inMemoryRejectsMultipleAndSynchronizableItems() {
        let keychain = InMemoryKeychain([grouped: Data([1])])
        keychain.set(Data([2]), at: grouped, account: "other")
        #expect(keychain.ops.read(grouped) == .rejected(.multipleItems(count: 2)))
        #expect(keychain.ops.read(ungrouped) == .rejected(.multipleItems(count: 2)))
        keychain.set(nil, at: grouped, account: "other")
        #expect(keychain.ops.read(grouped).data == Data([1]))
        // A synced copy in another group is seen by the group-less read and refused.
        let elsewhere = IdentityKeychain.Location(service: "svc", accessGroup: "OTHER.group")
        keychain.set(Data([3]), at: elsewhere, synchronizable: true)
        #expect(keychain.ops.read(ungrouped) == .rejected(.synchronizableItem))
        #expect(keychain.ops.read(grouped).data == Data([1]))
        #expect(keychain.ops.read(elsewhere) == .rejected(.synchronizableItem))
        #expect(keychain.item(at: elsewhere) == Data([3]))
        // `add` never stores a synchronizable item.
        let fresh = IdentityKeychain.Location(service: "fresh", accessGroup: "TEAMID.group")
        #expect(keychain.ops.add(fresh, Data([4])) == .added)
        #expect(keychain.ops.read(fresh).data == Data([4]))
    }

    /// Items differing only by account share a location query; `deleteItem` removes just the one read.
    @Test func inMemoryDeleteItemRemovesOnlyTheItemRead() {
        let keychain = InMemoryKeychain()
        keychain.set(Data([1]), at: grouped)
        guard case let .found(data, ref) = keychain.ops.read(grouped) else {
            Issue.record("expected .found")
            return
        }
        #expect(data == Data([1]))
        keychain.set(Data([2]), at: grouped, account: "other")
        #expect(keychain.ops.read(grouped) == .rejected(.multipleItems(count: 2)))
        #expect(keychain.ops.deleteItem(ref) == .deleted)
        #expect(keychain.item(at: grouped) == nil)
        #expect(keychain.item(at: grouped, account: "other") == Data([2]))
        #expect(keychain.ops.read(grouped).data == Data([2]))
        #expect(keychain.ops.deleteItem(ref) == .notFound)
        // The query delete, by contrast, removes every account.
        keychain.set(Data([1]), at: grouped)
        #expect(keychain.ops.delete(grouped) == .deleted)
        #expect(keychain.item(at: grouped, account: "other") == nil)
    }
}
