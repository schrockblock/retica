import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// Identity recall (RNS `Identity.recall` / `recall_app_data` over `Identity.known_destinations`,
// RNS/Identity.py:101-175): every valid announce for a remote destination is remembered, and the
// identity can be recalled by destination hash or identity hash for longer than the path lives.

private func recallAnnounce(identity: Identity, appName: String = "app", aspects: [String] = ["svc"],
                            hops: UInt8 = 1, emitted: UInt64, appData: Data? = nil,
                            randomPrefix: Data = Data(repeating: 0xA5, count: 5)) -> (raw: Data, destHash: Data) {
    let nameHash = Destination.nameHash(appName: appName, aspects: aspects)
    let destHash = Destination.hash(identityHash: identity.hash, appName: appName, aspects: aspects)
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: randomPrefix)
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: appData)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: hops,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (try! packet.packed(), destHash)
}

@Suite struct IdentityRecallTests {

@Test @MainActor func recallReturnsTheAnnouncedIdentityByDestinationAndIdentityHash() async {
    let remote = Identity()
    let ifID = InterfaceID("i1")
    let (raw, destHash) = recallAnnounce(identity: remote, emitted: 1_000, appData: Data("meta".utf8))
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off

    #expect(store.state.recall(destinationHash: destHash) == nil)
    await store.send(.interfaceConnected(ifID, .default))
    await store.send(.received(ifID, raw))

    let byDestination = store.state.recall(destinationHash: destHash)
    #expect(byDestination?.publicKey == remote.publicKey)
    #expect(byDestination?.privateKey == nil)                         // public-only, like RNS
    #expect(store.state.recall(identityHash: remote.hash)?.publicKey == remote.publicKey)
    #expect(store.state.recallAppData(destinationHash: destHash) == Data("meta".utf8))
    #expect(store.state.knownDestinations[destHash]?.identity.publicKey == remote.publicKey)
}

@Test func recallOfAnUnknownHashIsNil() {
    let state = Transport.State()
    #expect(state.recall(destinationHash: Data(repeating: 0x11, count: 16)) == nil)
    #expect(state.recall(identityHash: Data(repeating: 0x11, count: 16)) == nil)
    #expect(state.recallAppData(destinationHash: Data(repeating: 0x11, count: 16)) == nil)
}

/// RNS falls back to the registered local destinations (Identity.py:151-156): a local destination's
/// identity is recallable, returned public-only.
@Test func recallFindsALocalDestinationPublicOnly() {
    let mine = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: mine)!
    var state = Transport.State()
    state.localDestinations[dest.hash] = dest

    let recalled = state.recall(destinationHash: dest.hash)
    #expect(recalled?.publicKey == mine.publicKey)
    #expect(recalled?.privateKey == nil)
    #expect(state.recall(identityHash: mine.hash)?.publicKey == mine.publicKey)
}

/// A host that persists `learned` (and restores it with `.rehydrateLearnedDestinations`) can recall
/// from it too, even with no announce heard this session.
@Test func recallFallsBackToALearnedPath() {
    let remote = Identity()
    let destHash = Destination.hash(identityHash: remote.hash, appName: "app", aspects: ["svc"])
    var state = Transport.State()
    state.learned[destHash] = LearnedDestination(identity: remote, appData: Data("x".utf8), ratchet: nil,
                                                 interfaceID: InterfaceID("i"), hops: 1, nextHop: destHash,
                                                 announceEmitted: 1)
    #expect(state.recall(destinationHash: destHash)?.publicKey == remote.publicKey)
    #expect(state.recall(identityHash: remote.hash)?.publicKey == remote.publicKey)
    #expect(state.recallAppData(destinationHash: destHash) == Data("x".utf8))
}

/// The known-destination entry outlives the path: after the 7-day path expiry the identity is still
/// recallable, and it is culled only once pathless past `knownDestinationExpiry`
/// (RNS DESTINATION_TIMEOUT * 1.25, Identity.py:328).
@Test @MainActor func knownDestinationOutlivesThePathAndIsCulledLater() async {
    let remote = Identity()
    let ifID = InterfaceID("i1")
    let (raw, destHash) = recallAnnounce(identity: remote, emitted: 1_000)
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000))
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = DateGenerator { clock.value }
    }
    store.exhaustivity = .off

    await store.send(.interfaceConnected(ifID, .default))
    await store.send(.received(ifID, raw))
    #expect(store.state.learned[destHash] != nil)

    clock.setValue(Date(timeIntervalSince1970: 1_000 + Transport.pathExpiry + 1))
    await store.send(.maintenanceTick)
    #expect(store.state.learned[destHash] == nil)                       // the path expired …
    #expect(store.state.recall(destinationHash: destHash)?.publicKey == remote.publicKey)  // … recall did not

    clock.setValue(Date(timeIntervalSince1970: 1_000 + Transport.knownDestinationExpiry + 1))
    await store.send(.maintenanceTick)
    #expect(store.state.knownDestinations[destHash] == nil)
    #expect(store.state.recall(destinationHash: destHash) == nil)
}

/// A known destination that still has a path is never culled, however old its last announce.
@Test @MainActor func knownDestinationWithAPathIsNotCulled() async {
    let remote = Identity()
    let destHash = Destination.hash(identityHash: remote.hash, appName: "app", aspects: ["svc"])
    let now = Date(timeIntervalSince1970: 1_000 + Transport.knownDestinationExpiry + 1)
    var initial = Transport.State()
    initial.knownDestinations[destHash] = KnownDestination(identity: remote, appData: nil,
                                                           lastHeard: Date(timeIntervalSince1970: 1_000))
    initial.learned[destHash] = LearnedDestination(identity: remote, appData: nil, ratchet: nil,
                                                   interfaceID: InterfaceID("i"), hops: 1, nextHop: destHash,
                                                   announceEmitted: 1, learnedAt: now)
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.transportDate = DateGenerator { now }
    }
    store.exhaustivity = .off
    await store.send(.maintenanceTick)
    #expect(store.state.knownDestinations[destHash] != nil)
}

/// A later announce refreshes the remembered app data and last-heard time (RNS `remember` overwrites).
@Test @MainActor func aLaterAnnounceRefreshesTheKnownEntry() async {
    let remote = Identity()
    let ifID = InterfaceID("i1")
    let first = recallAnnounce(identity: remote, emitted: 1_000, appData: Data("old".utf8),
                               randomPrefix: Data(repeating: 0x01, count: 5))
    let second = recallAnnounce(identity: remote, emitted: 2_000, appData: Data("new".utf8),
                                randomPrefix: Data(repeating: 0x02, count: 5))
    let clock = LockIsolated(Date(timeIntervalSince1970: 1_000))
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = DateGenerator { clock.value }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(ifID, .default))
    await store.send(.received(ifID, first.raw))
    clock.setValue(Date(timeIntervalSince1970: 2_000))
    await store.send(.received(ifID, second.raw))

    #expect(store.state.recallAppData(destinationHash: first.destHash) == Data("new".utf8))
    #expect(store.state.knownDestinations[first.destHash]?.lastHeard == Date(timeIntervalSince1970: 2_000))
}

/// An announce for one of OUR destinations is not remembered (RNS: `local_destination == None`).
@Test @MainActor func anAnnounceForALocalDestinationIsNotRemembered() async {
    let mine = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: mine)!
    let (raw, destHash) = recallAnnounce(identity: mine, emitted: 1_000)
    var initial = Transport.State()
    initial.localDestinations[dest.hash] = dest
    let store = TestStore(initialState: initial) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i1"), .default))
    await store.send(.received(InterfaceID("i1"), raw))
    #expect(store.state.knownDestinations[destHash] == nil)
}

// MARK: - Persistence (RNS save/load_known_destinations, Identity.py:177-233)

/// The host persists `knownDestinations` and restores it at launch: recall then works with no
/// announce heard this session.
@Test @MainActor func rehydratedKnownDestinationIsRecallable() async {
    let remote = Identity()
    let destHash = Destination.hash(identityHash: remote.hash, appName: "app", aspects: ["svc"])
    let lastHeard = Date(timeIntervalSince1970: 1_000)
    let stored = KnownDestination(identity: Identity(publicKey: remote.publicKey)!, appData: Data("a".utf8),
                                  lastHeard: lastHeard)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = DateGenerator { Date(timeIntervalSince1970: 1_000 + 3 * 24 * 3600) }
    }
    store.exhaustivity = .off
    await store.send(.rehydrateKnownDestinations([destHash: stored]))

    #expect(store.state.recall(destinationHash: destHash)?.publicKey == remote.publicKey)
    #expect(store.state.recall(identityHash: remote.hash)?.publicKey == remote.publicKey)
    #expect(store.state.recallAppData(destinationHash: destHash) == Data("a".utf8))
}

/// Restore drops expired, future-dated and non-finite rows, and never overwrites a fresher live entry.
@Test @MainActor func rehydrateKnownDestinationsSweepsAndNeverOverwritesFresher() async {
    let now = Date(timeIntervalSince1970: 10_000_000)
    func entry(_ id: Identity, _ heard: Date, _ app: String) -> KnownDestination {
        KnownDestination(identity: id, appData: Data(app.utf8), lastHeard: heard)
    }
    let expired = Identity(), future = Identity(), nan = Identity(), live = Identity()
    let h = { (id: Identity) in Destination.hash(identityHash: id.hash, appName: "app", aspects: ["svc"]) }

    var initial = Transport.State()
    initial.knownDestinations[h(live)] = entry(live, now.addingTimeInterval(-10), "live")
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.transportDate = DateGenerator { now }
    }
    store.exhaustivity = .off
    await store.send(.rehydrateKnownDestinations([
        h(expired): entry(expired, now.addingTimeInterval(-Transport.knownDestinationExpiry - 1), "x"),
        h(future): entry(future, now.addingTimeInterval(1), "x"),
        h(nan): entry(nan, Date(timeIntervalSinceReferenceDate: .nan), "x"),
        h(live): entry(live, now.addingTimeInterval(-100), "stored"),
    ]))

    #expect(store.state.knownDestinations[h(expired)] == nil)
    #expect(store.state.knownDestinations[h(future)] == nil)
    #expect(store.state.knownDestinations[h(nan)] == nil)
    #expect(store.state.recallAppData(destinationHash: h(live)) == Data("live".utf8))
}

}
