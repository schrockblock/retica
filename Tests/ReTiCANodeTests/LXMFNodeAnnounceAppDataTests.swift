import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// MARK: - Helpers

@MainActor
private func makeAnnounceStore(
    identity: Identity,
    displayName: String? = nil,
    stampCost: Int? = nil
) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var node = LXMFNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    node.displayName = displayName
    node.deliveryStampCost = stampCost
    let store = TestStore(initialState: node) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(
            open: { _, _ in AsyncStream { _ in } },
            send: { _ in },
            close: { })
    }
    store.exhaustivity = .off
    return store
}

// MARK: - registerDelivery always emits app-data blob

/// `registerDelivery` with no display name set must still emit an announce whose `appData` is a
/// non-nil, non-empty, parseable blob — matching reference `get_announce_app_data`
/// (LXMF 1.1.0, LXMRouter.py:1034-1050) which calls `msgpack.packb(peer_data)` unconditionally.
///
/// Anti-vacuity: the assertion directly checks `appData` bytes in the emitted announce action,
/// not merely that state changed. An `appData: nil` announce would fail the non-nil check.
@MainActor @Test func registerDeliveryAlwaysEmitsAppDataBlob() async {
    let identity = Identity()
    let store = makeAnnounceStore(identity: identity)

    let capturedAppData = LockIsolated<Data?>(nil)
    await store.send(.registerDelivery)
    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action {
            capturedAppData.setValue(appData)
            return true
        }
        return false
    }

    let blob = capturedAppData.value
    #expect(blob != nil)
    if let blob {
        #expect(!blob.isEmpty)
        let parsed = LXMFAnnounceData.parse(blob)
        #expect(parsed != nil)
        if let parsed {
            #expect(parsed.displayName == nil)
            #expect(parsed.stampCost == nil)
            #expect(parsed.supportsCompression == true)
        }
    }
}

/// `registerDelivery` with a display name pre-set must emit an announce whose `appData` parses
/// back to that exact name.
///
/// Anti-vacuity: the assertion is on the `appData` bytes from the announce *effect*, not on
/// `state.displayName`. An announce emitting `appData: nil` or empty `Data()` would fail
/// `LXMFAnnounceData.parse(_:)` returning nil, and the `parsed.displayName` check would be skipped
/// — but the preceding `#expect(parsed != nil)` would catch it.
@MainActor @Test func registerDeliveryWithDisplayNameEmitsNameInAppData() async {
    let identity = Identity()
    let store = makeAnnounceStore(identity: identity, displayName: "Alice")

    let capturedAppData = LockIsolated<Data?>(nil)
    await store.send(.registerDelivery)
    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action {
            capturedAppData.setValue(appData)
            return true
        }
        return false
    }

    let blob = capturedAppData.value
    #expect(blob != nil)
    if let blob {
        let parsed = LXMFAnnounceData.parse(blob)
        #expect(parsed != nil)
        if let parsed {
            #expect(parsed.displayName == "Alice")
        }
    }
}

/// `registerDelivery` with a stamp cost in range (1...254) must emit an announce whose `appData`
/// parses back to that cost.
@MainActor @Test func registerDeliveryWithStampCostEmitsCostInAppData() async {
    let identity = Identity()
    let store = makeAnnounceStore(identity: identity, stampCost: 5)

    let capturedAppData = LockIsolated<Data?>(nil)
    await store.send(.registerDelivery)
    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action {
            capturedAppData.setValue(appData)
            return true
        }
        return false
    }

    let blob = capturedAppData.value
    #expect(blob != nil)
    if let blob {
        let parsed = LXMFAnnounceData.parse(blob)
        #expect(parsed != nil)
        if let parsed {
            #expect(parsed.stampCost == 5)
        }
    }
}

// MARK: - setDisplayName updates state and re-announces

/// `.setDisplayName` must update `state.displayName` AND emit a new `announce` effect carrying
/// the updated name in `appData`. A name change nobody hears is not a name change.
///
/// Anti-vacuity: the assertion is on the `appData` bytes of the re-announce action. Checking only
/// `state.displayName` would pass even if the announce carried `appData: nil` or stale bytes.
@MainActor @Test func setDisplayNameUpdatesStateAndReAnnounces() async {
    let identity = Identity()
    let store = makeAnnounceStore(identity: identity)

    // Register first so deliveryDestinationHash is set.
    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)

    let capturedAppData = LockIsolated<Data?>(nil)
    await store.send(.setDisplayName("Bob", stampCost: nil))
    #expect(store.state.displayName == "Bob")
    #expect(store.state.deliveryStampCost == nil)

    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action {
            capturedAppData.setValue(appData)
            return true
        }
        return false
    }

    let blob = capturedAppData.value
    #expect(blob != nil)
    if let blob {
        let parsed = LXMFAnnounceData.parse(blob)
        #expect(parsed != nil)
        if let parsed {
            #expect(parsed.displayName == "Bob")
        }
    }
}

/// `.setDisplayName` must update BOTH `state.displayName` and `state.deliveryStampCost` when a
/// cost is supplied, and the re-announce `appData` must carry both fields.
@MainActor @Test func setDisplayNameWithStampCostUpdatesStateAndReAnnounces() async {
    let identity = Identity()
    let store = makeAnnounceStore(identity: identity)

    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)

    let capturedAppData = LockIsolated<Data?>(nil)
    await store.send(.setDisplayName("Carol", stampCost: 10))
    #expect(store.state.displayName == "Carol")
    #expect(store.state.deliveryStampCost == 10)

    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action {
            capturedAppData.setValue(appData)
            return true
        }
        return false
    }

    let blob = capturedAppData.value
    #expect(blob != nil)
    if let blob {
        let parsed = LXMFAnnounceData.parse(blob)
        #expect(parsed != nil)
        if let parsed {
            #expect(parsed.displayName == "Carol")
            #expect(parsed.stampCost == 10)
        }
    }
}

/// `.setDisplayName` before `registerDelivery` must update state but must NOT emit an announce
/// (there is no registered delivery destination to announce on).
///
/// Anti-vacuity: exhaustivity is flipped to `.on` before the send so any stray `.announce` action
/// in the effect queue fails teardown. The state mutation is declared inside the `send` trailing
/// closure to satisfy `.on` exhaustivity — it is the observable outcome we expect, not a
/// side-effect we're trying to hide.
@MainActor @Test func setDisplayNameBeforeRegisterDeliveryDoesNotReAnnounce() async {
    let identity = Identity()
    let store = makeAnnounceStore(identity: identity)

    // Do NOT call registerDelivery — deliveryDestinationHash must remain nil.
    store.exhaustivity = .on
    await store.send(.setDisplayName("Dave", stampCost: nil)) {
        $0.displayName = "Dave"
    }
    // Teardown under .on: any stray announce action would fail here because it was
    // not consumed. The trailing closure above accounts for the state mutation; any
    // emitted effect would remain in the queue and fail teardown.
    #expect(store.state.displayName == "Dave")
}

/// `.setDisplayName` with nil clears the name. The re-announce `appData` blob is still emitted
/// (always-pack parity) but `displayName` parses as nil.
@MainActor @Test func setDisplayNameNilClearsNameButStillEmitsBlob() async {
    let identity = Identity()
    // Start with a name pre-set so clearing is observable.
    let store = makeAnnounceStore(identity: identity, displayName: "Eve")

    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)

    let capturedAppData = LockIsolated<Data?>(nil)
    await store.send(.setDisplayName(nil, stampCost: nil))
    #expect(store.state.displayName == nil)

    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action {
            capturedAppData.setValue(appData)
            return true
        }
        return false
    }

    let blob = capturedAppData.value
    #expect(blob != nil)
    if let blob {
        #expect(!blob.isEmpty)
        let parsed = LXMFAnnounceData.parse(blob)
        #expect(parsed != nil)
        if let parsed {
            #expect(parsed.displayName == nil)
        }
    }
}

// MARK: - Learning peers from inbound delivery announces

/// Helper: make a store with a pre-seeded `LearnedDestination` whose `appData` is controlled by
/// the caller. Seeding into `endpoint.transport.learned` before the store is built mirrors the way
/// the transport layer populates `learned` before firing `pathLearned`.
@MainActor
private func makeLearnPeerStore(
    peerHash: Data,
    peerAppData: Data?,
    date: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    let identity = Identity()
    let peerIdentity = Identity()
    var tcp = TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false)
    tcp.transport.learned[peerHash] = LearnedDestination(
        identity: peerIdentity, appData: peerAppData, ratchet: nil,
        interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil, announceEmitted: 0)
    let store = TestStore(initialState: LXMFNode.State(identity: identity, endpoint: tcp)) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(date)
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(
            open: { _, _ in AsyncStream { _ in } },
            send: { _ in },
            close: { })
    }
    store.exhaustivity = .off
    return store
}

/// A delivery announce with a display name causes `learnedPeers` to be populated with that name.
///
/// Anti-vacuity: the assertion is on `state.learnedPeers[peerHash]?.displayName`. A reducer that
/// does not write `learnedPeers` at all leaves the optional nil, and the `#expect(peer != nil)`
/// guard then fails, not silently passes.
@MainActor @Test func pathLearnedWithDisplayNameStoresPeerDisplayName() async {
    let peerHash = Data(repeating: 0xAB, count: 16)
    let appData = LXMFAnnounceData.pack(displayName: "Alice", stampCost: nil)
    let store = makeLearnPeerStore(peerHash: peerHash, peerAppData: appData)

    await store.send(.endpoint(.delegate(.pathLearned(destinationHash: peerHash, hops: 1))))

    let peer = store.state.learnedPeers[peerHash]
    #expect(peer != nil)
    if let peer {
        #expect(peer.displayName == "Alice")
    }
}

/// A delivery announce with a stamp cost causes `learnedPeers` to be populated with that cost.
///
/// Anti-vacuity: `peer.stampCost == 7` would fail if the reducer stored nil or stored a different
/// value; `#expect(peer != nil)` fails if nothing was stored.
@MainActor @Test func pathLearnedWithStampCostStoresPeerStampCost() async {
    let peerHash = Data(repeating: 0xBC, count: 16)
    let appData = LXMFAnnounceData.pack(displayName: nil, stampCost: 7)
    let store = makeLearnPeerStore(peerHash: peerHash, peerAppData: appData)

    await store.send(.endpoint(.delegate(.pathLearned(destinationHash: peerHash, hops: 1))))

    let peer = store.state.learnedPeers[peerHash]
    #expect(peer != nil)
    if let peer {
        #expect(peer.stampCost == 7)
    }
}

/// A delivery announce with both a display name and stamp cost stores both fields together.
///
/// Anti-vacuity: both fields are independently asserted so a half-populated struct fails at
/// the field that was not written; `#expect(peer != nil)` fails if nothing was stored.
@MainActor @Test func pathLearnedWithNameAndCostStoresBothFields() async {
    let peerHash = Data(repeating: 0xCD, count: 16)
    let appData = LXMFAnnounceData.pack(displayName: "Bob", stampCost: 12)
    let store = makeLearnPeerStore(peerHash: peerHash, peerAppData: appData)

    await store.send(.endpoint(.delegate(.pathLearned(destinationHash: peerHash, hops: 1))))

    let peer = store.state.learnedPeers[peerHash]
    #expect(peer != nil)
    if let peer {
        #expect(peer.displayName == "Bob")
        #expect(peer.stampCost == 12)
    }
}

/// A propagation-node announce (7-element array, first element `.bool(false)`) must NOT be stored
/// in `learnedPeers` as a delivery peer: `PNAnnounce.parse` succeeds, which the PN-exclusion guard
/// detects, so the entry is never written.
///
/// Anti-vacuity: if the PN filter were removed, the PN announce's `items[1]` (the timebase uint)
/// would be misread as a `stampCost` and the entry would be written — then `#expect(peer == nil)`
/// would fail. The assertion directly tests the filter's effect.
@MainActor @Test func pathLearnedWithPNAnnounceDoesNotStoreLearnedPeer() async {
    let pnHash = Data(repeating: 0xDE, count: 16)
    let pnData = PNAnnounce(timebase: 1_700_000_000, nodeState: true,
                            perTransferLimit: 256, perSyncLimit: 10240,
                            targetStampCost: 5, stampCostFlexibility: 1, peeringCost: 3).packed
    let store = makeLearnPeerStore(peerHash: pnHash, peerAppData: pnData)

    await store.send(.endpoint(.delegate(.pathLearned(destinationHash: pnHash, hops: 1))))

    #expect(store.state.learnedPeers[pnHash] == nil)
}

/// A `pathLearned` event with no app-data (nil) must not create a `learnedPeers` entry.
///
/// Anti-vacuity: if the nil-app-data guard were missing, a nil-appData delivery would store a
/// default-initialized entry and `#expect(peer == nil)` would fail.
@MainActor @Test func pathLearnedWithNoAppDataDoesNotStoreLearnedPeer() async {
    let peerHash = Data(repeating: 0xEF, count: 16)
    let store = makeLearnPeerStore(peerHash: peerHash, peerAppData: nil)

    await store.send(.endpoint(.delegate(.pathLearned(destinationHash: peerHash, hops: 1))))

    #expect(store.state.learnedPeers[peerHash] == nil)
}
