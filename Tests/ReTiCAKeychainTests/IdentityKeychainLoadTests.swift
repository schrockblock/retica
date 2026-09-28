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

/// `load` applies every `loadOrCreate` rule except the mint: when nothing exists anywhere it
/// returns `.absent` and writes nothing (spec 2026-09-28 §3).
@Suite("IdentityKeychain.load")
struct IdentityKeychainLoadTests {

    @Test func loadOnAnEmptyKeychainIsAbsentAndWritesNothing() {
        let keychain = InMemoryKeychain()
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops) == .absent)
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: shared) == nil)
        // Repeatable: nothing was minted by the first call.
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops) == .absent)
        #expect(keychain.addCount == 0)
    }

    @Test func loadReturnsTheSharedIdentityWithoutWriting() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain([shared: data])
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
        #expect(keychain.addCount == 0)
    }

    @Test func loadMigratesALegacyItemLikeLoadOrCreate() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain([legacy: data])
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops) == .migrated(identity))
        #expect(keychain.item(at: shared) == data)
        #expect(keychain.item(at: legacy) == nil)
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
    }

    /// Crash after the add, before the delete: both items hold the same seed.
    @Test func loadRemovesAnInterruptedMigrationLeftover() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain([shared: data, legacy: data])
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
        #expect(keychain.item(at: legacy) == nil)
        #expect(keychain.item(at: shared) == data)
    }

    @Test func loadFailsClosedOnAStrayItemInAnotherGroup() {
        let (_, data) = makeSeed()
        let stray = IdentityKeychain.Location(service: legacy.service, accessGroup: "TEAMID.co.example.wrong")
        let keychain = InMemoryKeychain([stray: data])
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.unexpectedItem(service: legacy.service)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: stray) == data)
    }

    /// iOS prewarm before first unlock: errSecInteractionNotAllowed. Unknown is never "absent".
    @Test func loadReadErrorIsAFailureNeverAbsent() {
        let keychain = InMemoryKeychain()
        keychain.failRead(at: shared, status: -25308)
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.readFailed(location: shared, status: -25308)))
        #expect(keychain.addCount == 0)
    }

    @Test func loadProbeReadErrorIsAFailureNeverAbsent() {
        let anyGroup = IdentityKeychain.Location(service: legacy.service, accessGroup: nil)
        let keychain = InMemoryKeychain()
        keychain.failRead(at: anyGroup, status: -25308)
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.readFailed(location: anyGroup, status: -25308)))
        #expect(keychain.addCount == 0)
    }

    @Test func loadRejectsGrouplessLocationsAndTouchesNothing() {
        let (_, data) = makeSeed()
        let unscoped = IdentityKeychain.Location(service: shared.service, accessGroup: nil)
        let emptyLegacy = IdentityKeychain.Location(service: legacy.service, accessGroup: "")
        let keychain = InMemoryKeychain([shared: data, legacy: data])
        #expect(IdentityKeychain.load(shared: unscoped, legacy: [legacy], ops: keychain.ops)
                == .failed(.invalidLocation(unscoped)))
        #expect(IdentityKeychain.load(shared: shared, legacy: [emptyLegacy], ops: keychain.ops)
                == .failed(.invalidLocation(emptyLegacy)))
        #expect(keychain.item(at: shared) == data)
        #expect(keychain.item(at: legacy) == data)
        #expect(keychain.addCount == 0)
    }

    @Test func loadCorruptSharedItemFailsAndIsKept() {
        let keychain = InMemoryKeychain([shared: garbage])
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.corrupt(location: shared)))
        #expect(keychain.item(at: shared) == garbage)
        #expect(keychain.addCount == 0)
    }
}
