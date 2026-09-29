import Foundation
import Testing
import ReTiCA
@testable import ReTiCAKeychain

private let shared = IdentityKeychain.Location(service: "reticulum.identity", accessGroup: "TEAMID.co.example.reticulum.identity")
private let legacyA = IdentityKeychain.Location(service: "a.identity", accessGroup: "TEAMID.co.example.a")
private let legacyB = IdentityKeychain.Location(service: "b.identity", accessGroup: "TEAMID.co.example.b")
private let garbage = Data(repeating: 0xAB, count: 63)

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

/// Spec 2026-09-29 §4.4: a read-only report of legacy items whose identity differs from the one
/// that would win (the shared item, or the first legacy item when the shared one is absent).
@Suite("IdentityKeychain.legacyConflicts")
struct IdentityKeychainConflictTests {

    @Test func noItemsAnywhereIsNone() {
        let keychain = InMemoryKeychain()
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA, legacyB], ops: keychain.ops) == .none)
        #expect(keychain.addCount == 0)
    }

    @Test func sharedOnlyAndByteEqualLegacyAreNone() {
        let (_, data) = makeSeed()
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA], ops: InMemoryKeychain([shared: data]).ops) == .none)
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA], ops: InMemoryKeychain([shared: data, legacyA: data]).ops) == .none)
    }

    @Test func aLegacyItemDifferingFromSharedIsAConflict() {
        let (sharedIdentity, sharedData) = makeSeed()
        let (otherIdentity, otherData) = makeSeed()
        let sameData = sharedData
        let keychain = InMemoryKeychain([shared: sharedData, legacyA: otherData, legacyB: sameData])
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA, legacyB], ops: keychain.ops)
                == .conflicts(sharedHash: sharedIdentity.hash,
                              legacy: [.init(location: legacyA, identityHash: otherIdentity.hash)]))
        // Read-only: nothing added or removed.
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: shared) == sharedData)
        #expect(keychain.item(at: legacyA) == otherData)
        #expect(keychain.item(at: legacyB) == sameData)
    }

    /// Shared absent: the first legacy item is the reference (it would win the migration).
    @Test func withSharedAbsentTheFirstLegacyIdentityIsTheReference() {
        let (_, first) = makeSeed()
        let (second, secondData) = makeSeed()
        let keychain = InMemoryKeychain([legacyA: first, legacyB: secondData])
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA, legacyB], ops: keychain.ops)
                == .conflicts(sharedHash: nil, legacy: [.init(location: legacyB, identityHash: second.hash)]))
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA], ops: keychain.ops) == .none)
        #expect(keychain.addCount == 0)
    }

    @Test func corruptItemsFail() {
        let (_, data) = makeSeed()
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA], ops: InMemoryKeychain([shared: garbage]).ops)
                == .failed(.corrupt(location: shared)))
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA], ops: InMemoryKeychain([shared: data, legacyA: garbage]).ops)
                == .failed(.corrupt(location: legacyA)))
    }

    @Test func readErrorsAndRejectionsFail() {
        let (_, a) = makeSeed()
        let (_, b) = makeSeed()
        let keychain = InMemoryKeychain([shared: a])
        keychain.failRead(at: legacyA, status: -25308)
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA], ops: keychain.ops)
                == .failed(.readFailed(location: legacyA, status: -25308)))
        keychain.clearFailures()
        keychain.set(b, at: legacyA)
        keychain.set(a, at: legacyA, account: "second")
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA], ops: keychain.ops)
                == .failed(.ambiguousItems(location: legacyA, count: 2)))
    }

    @Test func unscopedLocationsAreRejectedBeforeAnyRead() {
        let unscoped = IdentityKeychain.Location(service: legacyA.service, accessGroup: nil)
        let keychain = InMemoryKeychain()
        let reads = Collector<IdentityKeychain.Location>()
        keychain.onBeforeRead { reads.append($0) }
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [unscoped], ops: keychain.ops)
                == .failed(.invalidLocation(unscoped)))
        #expect(reads.values.isEmpty)
    }

    @Test func aSharedAliasInLegacyIsIgnored() {
        let (_, data) = makeSeed()
        let keychain = InMemoryKeychain([shared: data])
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [shared, legacyA], ops: keychain.ops) == .none)
    }

    /// Conflicts name their locations; strays in unnamed groups are `load`'s job, not this query's.
    @Test func theGrouplessProbeIsNotRun() {
        let (_, data) = makeSeed()
        let (_, stray) = makeSeed()
        let elsewhere = IdentityKeychain.Location(service: legacyA.service, accessGroup: "TEAMID.co.example.wrong")
        let keychain = InMemoryKeychain([shared: data, elsewhere: stray])
        let reads = Collector<IdentityKeychain.Location>()
        keychain.onBeforeRead { reads.append($0) }
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA], ops: keychain.ops) == .none)
        #expect(reads.values.allSatisfy { $0.accessGroup != nil })
    }
}
