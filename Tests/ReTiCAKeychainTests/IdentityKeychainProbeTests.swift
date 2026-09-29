import Foundation
import Testing
import ReTiCA
@testable import ReTiCAKeychain

private let shared = IdentityKeychain.Location(service: "reticulum.identity", accessGroup: "TEAMID.co.example.reticulum.identity")
private let legacy = IdentityKeychain.Location(service: "app.identity", accessGroup: "TEAMID.co.example.app")
private let sharedAnyGroup = IdentityKeychain.Location(service: shared.service, accessGroup: nil)
private let garbage = Data(repeating: 0xAB, count: 63)

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

/// Spec 2026-09-29 §4.3: when the group-less probe hits the SHARED service, re-read the shared
/// location — the other app may have written it between rule 1 and the probe.
@Suite("IdentityKeychain probe re-read")
struct IdentityKeychainProbeTests {

    /// The first-launch race: shared absent at rule 1, present by the time the probe runs.
    @Test func loadResolvesTheRaceWhenTheProbeHitsTheSharedService() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain()
        let reads = Collector<IdentityKeychain.Location>()
        keychain.onBeforeRead { location in
            reads.append(location)
            if location == sharedAnyGroup, keychain.item(at: shared) == nil {
                keychain.set(data, at: shared)
            }
        }
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
        #expect(keychain.addCount == 0)
        // rule 1 shared, rule 2 legacy, probe shared-any (the race), the confirming re-read of
        // shared, then removeLegacyCopies' scan of legacy (unconditional cleanup check) — nothing
        // else.
        #expect(reads.values == [shared, legacy, sharedAnyGroup, shared, legacy])
        #expect(reads.values.filter { $0 == shared }.count == 2)
    }

    @Test func loadOrCreateDoesNotMintWhenTheRaceIsResolved() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeRead { location in
            if location == sharedAnyGroup, keychain.item(at: shared) == nil {
                keychain.set(data, at: shared)
            }
        }
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
        #expect(keychain.addCount == 0)
    }

    /// The re-read also finishes an interrupted migration it now sees.
    @Test func loadRaceRereadRemovesAByteEqualLegacyLeftover() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeRead { location in
            if location == sharedAnyGroup, keychain.item(at: shared) == nil {
                keychain.set(data, at: shared)
                keychain.set(data, at: legacy)
            }
        }
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
        #expect(keychain.item(at: legacy) == nil)
    }

    @Test func loadRaceWithACorruptSharedItemFails() {
        let keychain = InMemoryKeychain()
        keychain.onBeforeRead { location in
            if location == sharedAnyGroup, keychain.item(at: shared) == nil {
                keychain.set(garbage, at: shared)
            }
        }
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.corrupt(location: shared)))
        #expect(keychain.addCount == 0)
    }

    @Test func loadRaceWithTwoSharedItemsFails() {
        let (_, a) = makeSeed()
        let (_, b) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeRead { location in
            if location == sharedAnyGroup, keychain.item(at: shared) == nil {
                keychain.set(a, at: shared)
                keychain.set(b, at: shared, account: "second")
            }
        }
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: shared, count: 2)))
        #expect(keychain.addCount == 0)
    }

    /// A same-service item in a group we don't name is still a stray: the re-read finds nothing.
    @Test func loadStillFailsClosedOnASharedServiceItemInAnotherGroup() {
        let (_, data) = makeSeed()
        let stray = IdentityKeychain.Location(service: shared.service, accessGroup: "TEAMID.co.example.wrong")
        let keychain = InMemoryKeychain([stray: data])
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.unexpectedItem(service: shared.service)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: stray) == data)
    }

    /// A read error on the re-read is a failure, never absent.
    @Test func loadRaceRereadErrorFails() {
        let (_, data) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeRead { location in
            if location == sharedAnyGroup, keychain.item(at: shared) == nil {
                keychain.set(data, at: shared)
                keychain.failRead(at: shared, status: -25308)
            }
        }
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.readFailed(location: shared, status: -25308)))
        #expect(keychain.addCount == 0)
    }

    /// A hit on a LEGACY service never triggers the shared re-read.
    @Test func loadLegacyServiceHitDoesNotRereadShared() {
        let (_, data) = makeSeed()
        let stray = IdentityKeychain.Location(service: legacy.service, accessGroup: "TEAMID.co.example.wrong")
        let keychain = InMemoryKeychain([stray: data])
        let reads = Collector<IdentityKeychain.Location>()
        keychain.onBeforeRead { reads.append($0) }
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.unexpectedItem(service: legacy.service)))
        #expect(reads.values.filter { $0 == shared }.count == 1)
    }

    @Test func importAnswersIdentityPresentWhenTheProbeHitsTheSharedService() {
        let (_, data) = makeSeed()
        let (_, candidate) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeRead { location in
            if location == sharedAnyGroup, keychain.item(at: shared) == nil {
                keychain.set(data, at: shared)
            }
        }
        #expect(IdentityKeychain.importIdentity(privateKey: candidate, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .identityPresent(service: shared.service))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: shared) == data)
    }
}
