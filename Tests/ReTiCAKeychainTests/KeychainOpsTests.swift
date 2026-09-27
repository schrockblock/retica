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
        #expect(read[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)

        let add = KeychainOps.addAttributes(grouped, data: Data([1, 2, 3]))
        #expect(add[kSecAttrAccessGroup as String] as? String == "TEAMID.group")
        #expect(add[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(add[kSecValueData as String] as? Data == Data([1, 2, 3]))
        #expect(add[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)

        let delete = KeychainOps.deleteQuery(grouped)
        #expect(delete[kSecAttrAccessGroup as String] as? String == "TEAMID.group")
        #expect(delete[kSecReturnData as String] == nil)

        for query in [read, add, delete] {
            #expect(query[kSecAttrSynchronizable as String] == nil)
        }
        #expect(KeychainOps.readQuery(ungrouped)[kSecAttrAccessGroup as String] == nil)
    }

    @Test func liveStatusMapping() {
        #expect(KeychainOps.mapRead(status: errSecSuccess, data: Data([9])) == .found(Data([9])))
        // success without data is NOT first-run: treating it as absent would mint (rotation).
        #expect(KeychainOps.mapRead(status: errSecSuccess, data: nil) == .failed(errSecSuccess))
        #expect(KeychainOps.mapRead(status: errSecItemNotFound, data: nil) == .notFound)
        #expect(KeychainOps.mapRead(status: errSecInteractionNotAllowed, data: nil) == .failed(errSecInteractionNotAllowed))
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
        #expect(keychain.ops.read(ungrouped) == .found(Data([1])))
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
        #expect(keychain.ops.read(grouped) == .found(Data([1])))

        let other = IdentityKeychain.Location(service: "other", accessGroup: "TEAMID.group")
        keychain.failAdd(at: other, status: errSecMissingEntitlement)
        #expect(keychain.ops.add(other, Data([2])) == .failed(errSecMissingEntitlement))
        keychain.clearFailures()
        keychain.dropAdds(at: other)
        #expect(keychain.ops.add(other, Data([2])) == .added)
        #expect(keychain.item(at: other) == nil)
    }
}
