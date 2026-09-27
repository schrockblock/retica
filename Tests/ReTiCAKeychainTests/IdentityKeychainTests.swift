import Foundation
import Testing
import ReTiCA
@testable import ReTiCAKeychain

private let shared = IdentityKeychain.Location(service: "reticulum.identity", accessGroup: "TEAMID.co.example.reticulum.identity")
private let legacy = IdentityKeychain.Location(service: "app.identity", accessGroup: nil)
private let olderLegacy = IdentityKeychain.Location(service: "app.identity.v0", accessGroup: nil)
private let garbage = Data(repeating: 0xAB, count: 63)

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

private func isCreated(_ outcome: IdentityKeychain.Outcome) -> Bool {
    if case .created = outcome { return true }
    return false
}

@Suite("IdentityKeychain.loadOrCreate")
struct IdentityKeychainTests {

    // MARK: Rule 1 — shared item present

    @Test func validSharedItemLoadsAndNothingIsWritten() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain([shared: data])
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
        #expect(keychain.addCount == 0)
    }

    @Test func corruptSharedItemFailsAndIsNeverOverwritten() {
        let (_, legacyData) = makeSeed()
        let keychain = InMemoryKeychain([shared: garbage, legacy: legacyData])
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.corrupt(location: shared)))
        #expect(keychain.item(at: shared) == garbage)
        #expect(keychain.item(at: legacy) == legacyData)
        #expect(keychain.addCount == 0)
    }

    /// iOS prewarm before first unlock: errSecInteractionNotAllowed (-25308).
    @Test func sharedReadErrorNeverMints() {
        let keychain = InMemoryKeychain()
        keychain.failRead(at: shared, status: -25308)
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.readFailed(location: shared, status: -25308)))
        #expect(keychain.addCount == 0)
    }

    // MARK: Rule 3 — nothing anywhere

    @Test func emptyKeychainCreatesAndPersists() {
        let keychain = InMemoryKeychain()
        let outcome = IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops)
        guard case let .created(identity) = outcome else {
            Issue.record("expected .created")
            return
        }
        #expect(keychain.item(at: shared) == identity.privateKey)
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
    }

    @Test func createAddFailureFailsAndStoresNothing() {
        let keychain = InMemoryKeychain()
        keychain.failAdd(at: shared, status: -34018)
        #expect(IdentityKeychain.loadOrCreate(shared: shared, ops: keychain.ops) == .failed(.addFailed(status: -34018)))
        #expect(keychain.item(at: shared) == nil)
    }

    @Test func simultaneousFirstLaunchOtherAppsIdentityWins() {
        let (other, otherData) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeAdd { location in
            if location == shared { keychain.set(otherData, at: shared) }
        }
        #expect(IdentityKeychain.loadOrCreate(shared: shared, ops: keychain.ops) == .loaded(other))
        #expect(keychain.item(at: shared) == otherData)
    }

    @Test func concurrentFirstLaunchesAgreeOnOneIdentity() {
        let launches = 8
        let keychain = InMemoryKeychain()
        let barrier = Barrier(parties: launches)
        // Every launch has read "absent" before any add proceeds: a guaranteed race.
        keychain.onBeforeAdd { _ in barrier.arriveAndWait() }
        let outcomes = Collector<IdentityKeychain.Outcome>()
        let group = DispatchGroup()
        for _ in 0..<launches {
            group.enter()
            Thread {
                outcomes.append(IdentityKeychain.loadOrCreate(shared: shared, ops: keychain.ops))
                group.leave()
            }.start()
        }
        #expect(group.wait(timeout: .now() + 10) == .success)
        let all = outcomes.values
        #expect(all.count == launches)
        #expect(Set(all.compactMap { $0.identity?.hash }).count == 1)
        #expect(all.filter(isCreated).count == 1)
    }

    @Test func duplicateThenCorruptSharedFails() {
        let keychain = InMemoryKeychain()
        keychain.onBeforeAdd { location in
            if location == shared { keychain.set(garbage, at: shared) }
        }
        #expect(IdentityKeychain.loadOrCreate(shared: shared, ops: keychain.ops) == .failed(.corrupt(location: shared)))
    }

    // MARK: Rule 2 — migrate a legacy item

    @Test func legacyItemMigratesVerifiedThenDeleted() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain([legacy: data])
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .migrated(identity))
        #expect(keychain.item(at: shared) == data)
        #expect(keychain.item(at: legacy) == nil)
    }

    @Test func migrationWhoseCopyCannotBeVerifiedKeepsLegacy() {
        let (_, data) = makeSeed()
        let keychain = InMemoryKeychain([legacy: data])
        keychain.dropAdds(at: shared)
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .failed(.verifyFailed))
        #expect(keychain.item(at: legacy) == data)
    }

    @Test func migrationAddFailureKeepsLegacyAndNeverMints() {
        let (_, data) = makeSeed()
        let keychain = InMemoryKeychain([legacy: data])
        keychain.failAdd(at: shared, status: -34018)
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.addFailed(status: -34018)))
        #expect(keychain.item(at: legacy) == data)
        #expect(keychain.item(at: shared) == nil)
    }

    @Test func migrationRaceOtherAppsIdentityWinsAndLegacyIsKept() {
        let (_, legacyData) = makeSeed()
        let (other, otherData) = makeSeed()
        let keychain = InMemoryKeychain([legacy: legacyData])
        keychain.onBeforeAdd { location in
            if location == shared { keychain.set(otherData, at: shared) }
        }
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(other))
        #expect(keychain.item(at: legacy) == legacyData)
    }

    @Test func migrationRaceWithTheSameSeedCompletesMigration() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain([legacy: data])
        keychain.onBeforeAdd { location in
            if location == shared { keychain.set(data, at: shared) }
        }
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .migrated(identity))
        #expect(keychain.item(at: legacy) == nil)
    }

    @Test func corruptLegacyItemFailsAndNeverMints() {
        let keychain = InMemoryKeychain([legacy: garbage])
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.corrupt(location: legacy)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: legacy) == garbage)
    }

    @Test func legacyReadErrorNeverMints() {
        let keychain = InMemoryKeychain()
        keychain.failRead(at: legacy, status: -25308)
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.readFailed(location: legacy, status: -25308)))
        #expect(keychain.addCount == 0)
    }

    @Test func laterLegacyLocationIsMigratedWhenEarlierOnesAreEmpty() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain([olderLegacy: data])
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy, olderLegacy], ops: keychain.ops)
                == .migrated(identity))
        #expect(keychain.item(at: olderLegacy) == nil)
    }

    // MARK: Interruption and cleanup

    @Test func legacyDeleteFailureStillMigratesAndNextLoadCleansUp() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain([legacy: data])
        keychain.failDelete(at: legacy, status: -25308)
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .migrated(identity))
        #expect(keychain.item(at: legacy) == data)
        keychain.clearFailures()
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
        #expect(keychain.item(at: legacy) == nil)
    }

    /// Crash after the add, before the delete: both items hold the same seed.
    @Test func interruptedMigrationLeftoverIsRemovedOnNextLoad() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain([shared: data, legacy: data])
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
        #expect(keychain.item(at: legacy) == nil)
        #expect(keychain.item(at: shared) == data)
    }

    @Test func differentLegacyIdentityIsNeverDeletedWhenSharedExists() {
        let (sharedIdentity, sharedData) = makeSeed()
        let (_, legacyData) = makeSeed()
        let keychain = InMemoryKeychain([shared: sharedData, legacy: legacyData])
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(sharedIdentity))
        #expect(keychain.item(at: legacy) == legacyData)
    }

    @Test func legacyLocationAliasingTheSharedItemIsIgnored() {
        let (identity, data) = makeSeed()
        let alias = IdentityKeychain.Location(service: shared.service, accessGroup: nil)
        let keychain = InMemoryKeychain([shared: data])
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [alias], ops: keychain.ops) == .loaded(identity))
        #expect(keychain.item(at: shared) == data)
    }
}
