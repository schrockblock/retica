import Foundation
import Testing
import ReTiCA
@testable import ReTiCAKeychain

private let shared = IdentityKeychain.Location(service: "reticulum.identity", accessGroup: "TEAMID.co.example.reticulum.identity")
private let legacy = IdentityKeychain.Location(service: "app.identity", accessGroup: "TEAMID.co.example.app")
private let wrongGroup = "TEAMID.co.example.wrong"

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

/// Spec 2026-09-29 §4.1–4.2: a read that finds more than one item, or any iCloud-synchronizable
/// item, fails closed everywhere. Nothing is minted, migrated, deleted or imported past it.
@Suite("IdentityKeychain hardening: duplicates and synchronizable items")
struct IdentityKeychainHardeningTests {

    @Test func loadFailsClosedOnTwoItemsAtTheSharedLocation() {
        let (_, a) = makeSeed()
        let (_, b) = makeSeed()
        let keychain = InMemoryKeychain([shared: a])
        keychain.set(b, at: shared, account: "second")
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: shared, count: 2)))
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: shared, count: 2)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: shared) == a)
        #expect(keychain.item(at: shared, account: "second") == b)
    }

    @Test func loadFailsClosedOnASynchronizableSharedItem() {
        let (_, data) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.set(data, at: shared, synchronizable: true)
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.synchronizableItem(location: shared)))
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.synchronizableItem(location: shared)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: shared) == data)
    }

    @Test func loadFailsClosedOnASynchronizableLegacyItemAndMigratesNothing() {
        let (_, data) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.set(data, at: legacy, synchronizable: true)
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.synchronizableItem(location: legacy)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: shared) == nil)
        #expect(keychain.item(at: legacy) == data)
    }

    @Test func loadFailsClosedOnTwoLegacyItems() {
        let (_, a) = makeSeed()
        let (_, b) = makeSeed()
        let keychain = InMemoryKeychain([legacy: a])
        keychain.set(b, at: legacy, account: "second")
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: legacy, count: 2)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: shared) == nil)
    }

    /// The group-less probe now sees synced strays too.
    @Test func loadProbeSeesASynchronizableStray() {
        let (_, data) = makeSeed()
        let stray = IdentityKeychain.Location(service: legacy.service, accessGroup: wrongGroup)
        let keychain = InMemoryKeychain()
        keychain.set(data, at: stray, synchronizable: true)
        let anyGroup = IdentityKeychain.Location(service: legacy.service, accessGroup: nil)
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.synchronizableItem(location: anyGroup)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: stray) == data)
    }

    /// Several strays under one service are still "an unexpected item exists".
    @Test func loadProbeWithSeveralStraysIsAnUnexpectedItem() {
        let (_, a) = makeSeed()
        let (_, b) = makeSeed()
        let keychain = InMemoryKeychain([
            IdentityKeychain.Location(service: legacy.service, accessGroup: wrongGroup): a,
            IdentityKeychain.Location(service: legacy.service, accessGroup: "TEAMID.co.example.other"): b,
        ])
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.unexpectedItem(service: legacy.service)))
        #expect(keychain.addCount == 0)
    }

    /// A good shared item next to a duplicated legacy pair: loads, deletes nothing (the leftover
    /// cleanup only ever removes a single byte-equal item it could read).
    @Test func loadKeepsADuplicatedLegacyPairNextToAGoodSharedItem() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain([shared: data, legacy: data])
        keychain.set(data, at: legacy, account: "second")
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
        #expect(keychain.item(at: legacy) == data)
        #expect(keychain.item(at: legacy, account: "second") == data)
    }

    /// Another process adds the shared item during migration, and the re-read finds two: fail,
    /// keep the legacy item.
    @Test func migrationDuplicateRereadRejectedFailsAndKeepsLegacy() {
        let (_, legacySeed) = makeSeed()
        let (_, a) = makeSeed()
        let (_, b) = makeSeed()
        let keychain = InMemoryKeychain([legacy: legacySeed])
        keychain.onBeforeAdd { location in
            guard location == shared else { return }
            keychain.set(a, at: shared)
            keychain.set(b, at: shared, account: "second")
        }
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: shared, count: 2)))
        #expect(keychain.item(at: legacy) == legacySeed)
    }

    @Test func importRefusesOnTwoItemsAtTheSharedLocation() {
        let (_, a) = makeSeed()
        let (_, b) = makeSeed()
        let (_, candidate) = makeSeed()
        let keychain = InMemoryKeychain([shared: a])
        keychain.set(b, at: shared, account: "second")
        #expect(IdentityKeychain.importIdentity(privateKey: candidate, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: shared, count: 2)))
        #expect(keychain.addCount == 0)
    }

    @Test func importRefusesOnASynchronizableStray() {
        let (_, data) = makeSeed()
        let (_, candidate) = makeSeed()
        let stray = IdentityKeychain.Location(service: shared.service, accessGroup: wrongGroup)
        let keychain = InMemoryKeychain()
        keychain.set(data, at: stray, synchronizable: true)
        let anyGroup = IdentityKeychain.Location(service: shared.service, accessGroup: nil)
        #expect(IdentityKeychain.importIdentity(privateKey: candidate, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.synchronizableItem(location: anyGroup)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: shared) == nil)
    }

    /// The verify re-read after a successful import add finds a second item: fail, nothing deleted.
    @Test func importVerifyRereadRejectedFails() {
        let (_, candidate) = makeSeed()
        let (_, other) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeAdd { location in
            guard location == shared else { return }
            keychain.set(other, at: shared, account: "second")
        }
        #expect(IdentityKeychain.importIdentity(privateKey: candidate, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: shared, count: 2)))
        #expect(keychain.item(at: shared) == candidate)
        #expect(keychain.item(at: shared, account: "second") == other)
    }

    /// `migrate`'s `.added` re-read (not the `.duplicate` re-read above): the add itself succeeds
    /// at account "", but another process has also planted a second item under a different
    /// account, so the verify re-read sees two. Fail, keep the legacy item.
    @Test func migrationAddedRereadRejectedFailsAndKeepsLegacy() {
        let (_, legacySeed) = makeSeed()
        let (_, different) = makeSeed()
        let keychain = InMemoryKeychain([legacy: legacySeed])
        keychain.onBeforeAdd { location in
            guard location == shared else { return }
            keychain.set(different, at: shared, account: "second")
        }
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: shared, count: 2)))
        #expect(keychain.item(at: legacy) == legacySeed)
        #expect(keychain.item(at: shared) == legacySeed)
        #expect(keychain.item(at: shared, account: "second") == different)
    }

    /// `loadOrCreate`'s mint sees `.duplicate` on add (another process planted both accounts
    /// first), and the `rereadWinner` re-read sees two. Fail; the mint never overwrote.
    @Test func mintDuplicateRereadRejectedFails() {
        let (_, a) = makeSeed()
        let (_, b) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeAdd { location in
            guard location == shared else { return }
            keychain.set(a, at: shared)
            keychain.set(b, at: shared, account: "second")
        }
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: shared, count: 2)))
        #expect(keychain.item(at: shared) == a)
        #expect(keychain.item(at: shared, account: "second") == b)
    }

    /// `importIdentity` step 4's `.duplicate` re-read (not step 5's verify re-read above): the
    /// add sees a duplicate because another process planted both accounts first, and the re-read
    /// sees two. Fail; nothing deleted.
    @Test func importDuplicateRereadRejectedFails() {
        let (_, a) = makeSeed()
        let (_, b) = makeSeed()
        let (_, candidate) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeAdd { location in
            guard location == shared else { return }
            keychain.set(a, at: shared)
            keychain.set(b, at: shared, account: "second")
        }
        #expect(IdentityKeychain.importIdentity(privateKey: candidate, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: shared, count: 2)))
        #expect(keychain.item(at: shared) == a)
        #expect(keychain.item(at: shared, account: "second") == b)
    }
}
