import Foundation
import Testing
import ReTiCA
@testable import ReTiCAKeychain

private let shared = IdentityKeychain.Location(service: "reticulum.identity", accessGroup: "TEAMID.co.example.reticulum.identity")
/// Legacy items live in the old app's app-ID group (an unentitled, group-less write lands there).
private let appGroup = "TEAMID.co.example.app"
private let legacy = IdentityKeychain.Location(service: "app.identity", accessGroup: appGroup)
private let olderLegacy = IdentityKeychain.Location(service: "app.identity.v0", accessGroup: appGroup)
private let garbage = Data(repeating: 0xAB, count: 63)

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

/// Wraps `base` so `afterAdd` runs once an add has returned (outside the keychain's lock) —
/// e.g. to make the shared item vanish or become unreadable before the caller's re-read.
private func ops(_ base: KeychainOps, afterAdd: @escaping @Sendable (KeychainOps.AddResult) -> Void) -> KeychainOps {
    KeychainOps(
        read: base.read,
        add: { location, data in
            let result = base.add(location, data)
            afterAdd(result)
            return result
        },
        delete: base.delete,
        deleteItem: base.deleteItem
    )
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
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .failed(.verifyFailed(status: nil)))
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
        let alias = IdentityKeychain.Location(service: shared.service, accessGroup: shared.accessGroup)
        let keychain = InMemoryKeychain([shared: data])
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [alias], ops: keychain.ops) == .loaded(identity))
        #expect(keychain.item(at: shared) == data)
    }

    // MARK: Location validation (fix round 1)

    /// A group-less shared read would pick an arbitrary group's item; nothing may be touched.
    @Test func nilGroupSharedLocationIsRejectedAndTouchesNothing() {
        let (_, data) = makeSeed()
        let unscoped = IdentityKeychain.Location(service: shared.service, accessGroup: nil)
        let keychain = InMemoryKeychain([shared: data, legacy: data])
        #expect(IdentityKeychain.loadOrCreate(shared: unscoped, legacy: [legacy], ops: keychain.ops)
                == .failed(.invalidLocation(unscoped)))
        #expect(keychain.item(at: shared) == data)
        #expect(keychain.item(at: legacy) == data)
        #expect(keychain.addCount == 0)
    }

    /// A group-less legacy delete would remove the service in EVERY group, including items never verified.
    @Test func nilGroupLegacyLocationIsRejectedAndTouchesNothing() {
        let (_, data) = makeSeed()
        let unscoped = IdentityKeychain.Location(service: legacy.service, accessGroup: nil)
        let keychain = InMemoryKeychain([legacy: data])
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [unscoped], ops: keychain.ops)
                == .failed(.invalidLocation(unscoped)))
        #expect(keychain.item(at: legacy) == data)
        #expect(keychain.item(at: shared) == nil)
        #expect(keychain.addCount == 0)
    }

    // MARK: Fix round 2

    /// Groups are mandatory, so only an exact alias is the shared item: a same-service item in
    /// another named group is a real legacy identity and must migrate, never be skipped (→ mint).
    @Test func sameServiceLegacyInAnotherNamedGroupMigrates() {
        let (identity, data) = makeSeed()
        let oldApp = IdentityKeychain.Location(service: shared.service, accessGroup: "TEAMID.oldApp")
        let keychain = InMemoryKeychain([oldApp: data])
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [oldApp], ops: keychain.ops) == .migrated(identity))
        #expect(keychain.item(at: shared) == data)
        #expect(keychain.item(at: oldApp) == nil)
    }

    /// E.g. a legacy group string with the wrong prefix: the item exists, just not where named.
    @Test func legacyItemOnlyInAnUnexpectedGroupFailsClosed() {
        let (_, data) = makeSeed()
        let actual = IdentityKeychain.Location(service: legacy.service, accessGroup: "TEAMID.co.example.wrong")
        let keychain = InMemoryKeychain([actual: data])
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.unexpectedItem(service: legacy.service)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: actual) == data)
        #expect(keychain.item(at: shared) == nil)
    }

    @Test func sharedServiceItemInAnUnexpectedGroupFailsClosed() {
        let (_, data) = makeSeed()
        let actual = IdentityKeychain.Location(service: shared.service, accessGroup: "TEAMID.co.example.other")
        let keychain = InMemoryKeychain([actual: data])
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.unexpectedItem(service: shared.service)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: actual) == data)
    }

    @Test func emptyStringGroupIsRejectedAndTouchesNothing() {
        let (_, data) = makeSeed()
        let emptyShared = IdentityKeychain.Location(service: shared.service, accessGroup: "")
        let emptyLegacy = IdentityKeychain.Location(service: legacy.service, accessGroup: "")
        let keychain = InMemoryKeychain([legacy: data])
        #expect(IdentityKeychain.loadOrCreate(shared: emptyShared, ops: keychain.ops) == .failed(.invalidLocation(emptyShared)))
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [emptyLegacy], ops: keychain.ops)
                == .failed(.invalidLocation(emptyLegacy)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: legacy) == data)
    }

    /// Two items differ only by account; the location query matches both. Only the one whose
    /// bytes were copied and verified may be deleted.
    @Test func migrationDeletesOnlyTheVerifiedItemNotAnAccountSibling() {
        let (x, xData) = makeSeed()
        let (_, yData) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.set(xData, at: legacy)
        keychain.set(yData, at: legacy, account: "other")
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .migrated(x))
        #expect(keychain.item(at: shared) == xData)
        #expect(keychain.item(at: legacy) == nil)
        #expect(keychain.item(at: legacy, account: "other") == yData)
    }

    @Test func migrationRaceWithTheSameSeedDeletesOnlyTheVerifiedItem() {
        let (x, xData) = makeSeed()
        let (_, yData) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.set(xData, at: legacy)
        keychain.set(yData, at: legacy, account: "other")
        keychain.onBeforeAdd { location in keychain.set(xData, at: location) }
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .migrated(x))
        #expect(keychain.item(at: legacy) == nil)
        #expect(keychain.item(at: legacy, account: "other") == yData)
    }

    @Test func leftoverCleanupDeletesOnlyTheVerifiedItem() {
        let (x, xData) = makeSeed()
        let (_, yData) = makeSeed()
        let keychain = InMemoryKeychain([shared: xData])
        keychain.set(xData, at: legacy)
        keychain.set(yData, at: legacy, account: "other")
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(x))
        #expect(keychain.item(at: legacy) == nil)
        #expect(keychain.item(at: legacy, account: "other") == yData)
    }

    /// The same legacy service in two groups: only the verified one is ever deleted.
    @Test func migratingOneGroupNeverDeletesTheSameServiceInAnotherGroup() {
        let (x, xData) = makeSeed()
        let (_, yData) = makeSeed()
        let g1 = IdentityKeychain.Location(service: "app.identity", accessGroup: "TEAMID.co.example.g1")
        let g2 = IdentityKeychain.Location(service: "app.identity", accessGroup: "TEAMID.co.example.g2")
        let keychain = InMemoryKeychain([g1: xData, g2: yData])
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [g1], ops: keychain.ops) == .migrated(x))
        #expect(keychain.item(at: shared) == xData)
        #expect(keychain.item(at: g1) == nil)
        #expect(keychain.item(at: g2) == yData)
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [g1], ops: keychain.ops) == .loaded(x))
        #expect(keychain.item(at: g2) == yData)
    }

    // MARK: Fail-closed branches (fix round 1)

    @Test func migrationDuplicateWhoseRereadFailsKeepsLegacyAndNeverMints() {
        let (_, legacyData) = makeSeed()
        let (_, otherData) = makeSeed()
        let keychain = InMemoryKeychain([legacy: legacyData])
        keychain.onBeforeAdd { location in
            keychain.set(otherData, at: location)
            keychain.failRead(at: location, status: -25308)
        }
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.readFailed(location: shared, status: -25308)))
        #expect(keychain.item(at: legacy) == legacyData)
        #expect(keychain.item(at: shared) == otherData)
        #expect(keychain.addCount == 1)
    }

    @Test func migrationDuplicateWhoseRereadFindsNothingKeepsLegacyAndNeverMints() {
        let (_, legacyData) = makeSeed()
        let (_, otherData) = makeSeed()
        let keychain = InMemoryKeychain([legacy: legacyData])
        keychain.onBeforeAdd { location in keychain.set(otherData, at: location) }
        let vanishing = ops(keychain.ops) { result in
            if result == .duplicate { keychain.set(nil, at: shared) }
        }
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: vanishing)
                == .failed(.verifyFailed(status: nil)))
        #expect(keychain.item(at: legacy) == legacyData)
        #expect(keychain.item(at: shared) == nil)
        #expect(keychain.addCount == 1)
    }

    @Test func migrationDuplicateWithCorruptSharedKeepsLegacyAndNeverMints() {
        let (_, legacyData) = makeSeed()
        let keychain = InMemoryKeychain([legacy: legacyData])
        keychain.onBeforeAdd { location in keychain.set(garbage, at: location) }
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.corrupt(location: shared)))
        #expect(keychain.item(at: legacy) == legacyData)
        #expect(keychain.item(at: shared) == garbage)
        #expect(keychain.addCount == 1)
    }

    @Test func mintDuplicateWhoseRereadFindsNothingFailsAndNeverMintsAgain() {
        let (_, otherData) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeAdd { location in keychain.set(otherData, at: location) }
        let vanishing = ops(keychain.ops) { result in
            if result == .duplicate { keychain.set(nil, at: shared) }
        }
        #expect(IdentityKeychain.loadOrCreate(shared: shared, ops: vanishing) == .failed(.verifyFailed(status: nil)))
        #expect(keychain.item(at: shared) == nil)
        #expect(keychain.addCount == 1)
    }

    @Test func mintDuplicateWhoseRereadFailsFailsAndNeverMintsAgain() {
        let (_, otherData) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeAdd { location in
            keychain.set(otherData, at: location)
            keychain.failRead(at: location, status: -25308)
        }
        #expect(IdentityKeychain.loadOrCreate(shared: shared, ops: keychain.ops)
                == .failed(.readFailed(location: shared, status: -25308)))
        #expect(keychain.item(at: shared) == otherData)
        #expect(keychain.addCount == 1)
    }

    @Test func leftoverCleanupReadErrorStillLoadsAndDeletesNothing() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain([shared: data, legacy: data])
        keychain.failRead(at: legacy, status: -25308)
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
        #expect(keychain.item(at: legacy) == data)
        #expect(keychain.item(at: shared) == data)
    }

    @Test func migrationVerifyReadErrorCarriesStatusAndKeepsLegacy() {
        let (_, data) = makeSeed()
        let keychain = InMemoryKeychain([legacy: data])
        let unreadable = ops(keychain.ops) { result in
            if result == .added { keychain.failRead(at: shared, status: -25308) }
        }
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: unreadable)
                == .failed(.verifyFailed(status: -25308)))
        #expect(keychain.item(at: legacy) == data)
        #expect(keychain.addCount == 1)
    }
}
