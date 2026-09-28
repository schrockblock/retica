import Foundation
import Testing
import ReTiCA
@testable import ReTiCAKeychain

private let shared = IdentityKeychain.Location(service: "reticulum.identity", accessGroup: "TEAMID.co.example.reticulum.identity")
private let appGroup = "TEAMID.co.example.app"
private let legacy = IdentityKeychain.Location(service: "app.identity", accessGroup: appGroup)
private let garbage = Data(repeating: 0xAB, count: 63)

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

/// Records every KeychainOps call by kind, so tests can prove "no Keychain access" / "no delete".
private func recording(_ base: KeychainOps, into calls: Collector<String>) -> KeychainOps {
    KeychainOps(
        read: { location in
            calls.append("read")
            return base.read(location)
        },
        add: { location, data in
            calls.append("add")
            return base.add(location, data)
        },
        delete: { location in
            calls.append("delete")
            return base.delete(location)
        },
        deleteItem: { ref in
            calls.append("deleteItem")
            return base.deleteItem(ref)
        }
    )
}

/// Runs `after` once an add has returned (outside the keychain's lock).
private func afterAdd(_ base: KeychainOps, _ after: @escaping @Sendable (KeychainOps.AddResult) -> Void) -> KeychainOps {
    KeychainOps(
        read: base.read,
        add: { location, data in
            let result = base.add(location, data)
            after(result)
            return result
        },
        delete: base.delete,
        deleteItem: base.deleteItem
    )
}

/// Spec 2026-09-28 §3: validate → groups → full scan (refuse if anything exists) → add-only →
/// verify. Never deletes, never overwrites.
@Suite("IdentityKeychain.importIdentity")
struct IdentityKeychainImportTests {

    @Test func importIntoAnEmptyKeychainStoresVerifiesAndLoads() {
        let (identity, key) = makeSeed()
        let keychain = InMemoryKeychain()
        #expect(IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .imported(identity))
        #expect(keychain.item(at: shared) == key)
        #expect(keychain.addCount == 1)
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
    }

    @Test func importRefusesWhenTheSharedItemHoldsAnotherIdentity() {
        let (_, existing) = makeSeed()
        let (_, key) = makeSeed()
        let keychain = InMemoryKeychain([shared: existing])
        #expect(IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .identityPresent(service: shared.service))
        #expect(keychain.item(at: shared) == existing)
        #expect(keychain.addCount == 0)
    }

    @Test func importRefusesEvenWhenTheSharedItemHoldsTheSameKey() {
        let (_, key) = makeSeed()
        let keychain = InMemoryKeychain([shared: key])
        #expect(IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .identityPresent(service: shared.service))
        #expect(keychain.addCount == 0)
    }

    @Test func importRefusesWhenALegacyItemExists() {
        let (_, existing) = makeSeed()
        let (_, key) = makeSeed()
        let keychain = InMemoryKeychain([legacy: existing])
        #expect(IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .identityPresent(service: legacy.service))
        #expect(keychain.item(at: legacy) == existing)
        #expect(keychain.item(at: shared) == nil)
        #expect(keychain.addCount == 0)
    }

    @Test func importRefusesAStrayItemInAnotherGroup() {
        let (_, strayKey) = makeSeed()
        let (_, key) = makeSeed()
        let stray = IdentityKeychain.Location(service: shared.service, accessGroup: "TEAMID.co.example.other")
        let keychain = InMemoryKeychain([stray: strayKey])
        #expect(IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .identityPresent(service: shared.service))
        #expect(keychain.item(at: stray) == strayKey)
        #expect(keychain.item(at: shared) == nil)
        #expect(keychain.addCount == 0)
    }

    @Test func importRefusesACorruptSharedItemAndKeepsIt() {
        let (_, key) = makeSeed()
        let keychain = InMemoryKeychain([shared: garbage])
        #expect(IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .identityPresent(service: shared.service))
        #expect(keychain.item(at: shared) == garbage)
        #expect(keychain.addCount == 0)
    }

    /// Every 64-byte input is a valid key (X25519/Ed25519 accept any 32-byte seed), so
    /// `.invalidKey` is exactly "not 64 bytes" — and is decided before any Keychain access.
    @Test func importRejectsWrongLengthKeysBeforeAnyKeychainAccess() {
        let keychain = InMemoryKeychain()
        let calls = Collector<String>()
        let ops = recording(keychain.ops, into: calls)
        for length in [0, 32, 63, 65, 128] {
            #expect(IdentityKeychain.importIdentity(privateKey: Data(repeating: 0x11, count: length),
                                                    shared: shared, legacy: [legacy], ops: ops) == .invalidKey,
                    "length \(length)")
        }
        #expect(calls.values.isEmpty)
    }

    @Test func importReadErrorFailsAndAddsNothing() {
        let (_, key) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.failRead(at: shared, status: -25308)
        #expect(IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.readFailed(location: shared, status: -25308)))
        #expect(keychain.addCount == 0)
    }

    @Test func importProbeReadErrorFailsAndAddsNothing() {
        let (_, key) = makeSeed()
        let anyGroup = IdentityKeychain.Location(service: shared.service, accessGroup: nil)
        let keychain = InMemoryKeychain()
        keychain.failRead(at: anyGroup, status: -25308)
        #expect(IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.readFailed(location: anyGroup, status: -25308)))
        #expect(keychain.addCount == 0)
    }

    @Test func importDuplicateRaceStoredIdentityWins() {
        let (_, key) = makeSeed()
        let (_, other) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeAdd { location in
            if location == shared { keychain.set(other, at: shared) }
        }
        #expect(IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .identityPresent(service: shared.service))
        #expect(keychain.item(at: shared) == other)
    }

    @Test func importDuplicateRaceWithTheSameKeyImports() {
        let (identity, key) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeAdd { location in
            if location == shared { keychain.set(key, at: shared) }
        }
        #expect(IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .imported(identity))
        #expect(keychain.item(at: shared) == key)
    }

    @Test func importAddFailureFailsAndStoresNothing() {
        let (_, key) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.failAdd(at: shared, status: -34018)
        #expect(IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.addFailed(status: -34018)))
        #expect(keychain.item(at: shared) == nil)
    }

    @Test func importWhoseCopyCannotBeVerifiedFails() {
        let (_, key) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.dropAdds(at: shared)
        #expect(IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.verifyFailed(status: nil)))
    }

    @Test func importVerifyReadErrorCarriesStatus() {
        let (_, key) = makeSeed()
        let keychain = InMemoryKeychain()
        let unreadable = afterAdd(keychain.ops) { result in
            if result == .added { keychain.failRead(at: shared, status: -25308) }
        }
        #expect(IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [legacy], ops: unreadable)
                == .failed(.verifyFailed(status: -25308)))
        #expect(keychain.addCount == 1)
    }

    @Test func importRejectsGrouplessLocationsAndTouchesNothing() {
        let (_, key) = makeSeed()
        let emptyShared = IdentityKeychain.Location(service: shared.service, accessGroup: "")
        let unscopedLegacy = IdentityKeychain.Location(service: legacy.service, accessGroup: nil)
        let keychain = InMemoryKeychain()
        #expect(IdentityKeychain.importIdentity(privateKey: key, shared: emptyShared, legacy: [], ops: keychain.ops)
                == .failed(.invalidLocation(emptyShared)))
        #expect(IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [unscopedLegacy], ops: keychain.ops)
                == .failed(.invalidLocation(unscopedLegacy)))
        #expect(keychain.addCount == 0)
    }

    /// A refusal, a success and a duplicate race: none may delete anything.
    @Test func importNeverDeletesAnything() {
        let (_, key) = makeSeed()
        let (_, strayKey) = makeSeed()
        let (_, other) = makeSeed()
        let calls = Collector<String>()
        let stray = IdentityKeychain.Location(service: legacy.service, accessGroup: "TEAMID.co.example.other")
        let refusing = InMemoryKeychain([stray: strayKey])
        _ = IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [legacy], ops: recording(refusing.ops, into: calls))
        let empty = InMemoryKeychain()
        _ = IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [legacy], ops: recording(empty.ops, into: calls))
        let racing = InMemoryKeychain()
        racing.onBeforeAdd { location in racing.set(other, at: location) }
        _ = IdentityKeychain.importIdentity(privateKey: key, shared: shared, legacy: [legacy], ops: recording(racing.ops, into: calls))
        #expect(calls.values.contains("add"), "the recorder saw the calls")
        #expect(!calls.values.contains("delete"))
        #expect(!calls.values.contains("deleteItem"))
        #expect(refusing.item(at: stray) == strayKey)
    }
}
